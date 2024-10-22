// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


import {IERC20} from "@openzeppelin-5.0.2/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin-5.0.2/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin-5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin-5.0.2/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin-5.0.2/contracts/access/Ownable.sol";

import {Signer} from "./base/Signer.sol";
import {StakeManager} from "./base/StakeManager.sol";
import {LiquidityManager} from "./base/LiquidityManager.sol";
import {ETH} from "./base/Helpers.sol";

import {SafeTransferLib} from "@solady-0.0.259/utils/SafeTransferLib.sol";


/// @notice Helper struct that represents a call to make.
struct CallStruct {
    address to;
    uint256 value;
    bytes data;
}

/// @notice Request acts as a reciept
/// @dev signed by the signer it allows to withdraw funds
/// @dev signed by the user it allows to claim funds from it's stake
struct Request {
    /// @dev Asset that user wants to withdraw.
    address asset;
    /// @dev The requested amount to withdraw.
    uint128 amount;
    /// @dev The amount of fee that will be paid to the operator.
    uint128 fee;
    /// @dev Chain id of the network, where the request will be claimed.
    uint256 claimChainId;
    /// @dev Chain id of the network, where the request will be withdrawn.
    uint256 withdrawChainId;
    /// @dev Address that will receive the funds.
    address recipient;
    /// @dev Calls that will be made before the funds are sent to the user.
    CallStruct[] preCalls;
    /// @dev Calls that will be made after the funds are sent to the user.
    CallStruct[] postCalls;
    /// @dev The time in which the request is valid until.
    uint48 validUntil;
    /// @dev The time in which this request is valid after.
    uint48 validAfter;
    /// @dev The nonce of the request.
    uint48 nonce;
}

struct RequestStatus {
    bool withdrawn;
    bool claimed;
}

enum RequestExecutionType {
    WITHDRAWN,
    CLAIMED
}



/// @title MagicSpendPlusMinusHalf
/// @author Pimlico (https://github.com/pimlicolabs/singleton-paymaster/blob/main/src/MagicSpendPlusMinusHalf.sol)
/// @notice Contract that allows users to pull funds from if they provide a valid signed request.
/// @dev Inherits from Ownable.
/// @custom:security-contact security@pimlico.io
contract MagicSpendPlusMinusHalf is Ownable, Signer, StakeManager, LiquidityManager {
    /// @notice Thrown when the request was submitted past its validUntil.
    error RequestExpired();

    /// @notice Thrown when the request was submitted with an invalid chain id.
    error RequestInvalidChain();

    /// @notice Thrown when the request was submitted before its validAfter.
    error RequestNotYetValid();

    /// @notice The withdraw request was initiated with a invalid nonce.
    error SignatureInvalid();

    /// @notice The withdraw request was already withdrawn or claimed.
    error AlreadyUsed();

    /// @notice One of the precalls reverted.
    /// @param revertReason The revert bytes.
    error PreCallReverted(bytes revertReason);

    /// @notice One of the postcalls reverted.
    /// @param revertReason The revert bytes.
    error PostCallReverted(bytes revertReason);

    /// @notice Emitted when a withdraw request has been executed (either claimed or withdrawn).
    event RequestExecuted(
        RequestExecutionType event_,
        bytes32 indexed hash_
    );

    mapping(bytes32 hash_ => RequestStatus status) public statuses;

    constructor(
        address _owner,
        address _signer
    ) Ownable(_owner) Signer(_signer) {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     EXTERNAL FUNCTIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Fulfills a withdraw request only if it has a valid signature and passes validation.
     * The signature should be signed by one of the signers.
     */
    function withdraw(
        Request calldata request,
        bytes calldata signature
    ) external nonReentrant {
        if (request.withdrawChainId != block.chainid) {
            revert RequestInvalidChain();
        }

        if (block.timestamp > request.validUntil && request.validUntil != 0) {
            revert RequestExpired();
        }

        if (block.timestamp < request.validAfter && request.validAfter != 0) {
            revert RequestNotYetValid();
        }

        // check signature is authorized by the actual operator
        bytes32 hash_ = getHash(request);

        address signer = ECDSA.recover(
            hash_,
            signature
        );

        if (!_isSigner(signer)) {
            revert SignatureInvalid();
        }

        // check withdraw request params
        if (statuses[hash_].withdrawn) {
            revert AlreadyUsed();
        }

        // run pre calls
        for (uint256 i = 0; i < request.preCalls.length; i++) {
            address to = request.preCalls[i].to;
            uint256 value = request.preCalls[i].value;
            bytes memory data = request.preCalls[i].data;

            (bool success, bytes memory result) = to.call{value: value}(data);

            if (!success) {
                revert PreCallReverted(result);
            }
        }

        // fulfil withdraw request
        _removeLiquidity(request.asset, request.amount);

        if (request.asset == ETH) {
            SafeTransferLib.forceSafeTransferETH(request.recipient, request.amount);
        } else {
            SafeTransferLib.safeTransfer(request.asset, request.recipient, request.amount);
        }

        // run postcalls
        for (uint256 i = 0; i < request.postCalls.length; i++) {
            address to = request.postCalls[i].to;
            uint256 value = request.postCalls[i].value;
            bytes memory data = request.postCalls[i].data;

            (bool success, bytes memory result) = to.call{value: value}(data);

            if (!success) {
                revert PostCallReverted(result);
            }
        }

        statuses[hash_].withdrawn = true;

        emit RequestExecuted(RequestExecutionType.WITHDRAWN, hash_);
    }

    function claim(
        Request calldata request,
        bytes calldata signature
    ) public nonReentrant {
        bytes32 hash_ = getHash(request);

        address account = ECDSA.recover(
            hash_,
            signature
        );

        if (statuses[hash_].claimed) {
            revert AlreadyUsed();
        }

        _claimStake(
            account,
            request.asset,
            request.amount + request.fee
        );

        _addLiquidity(request.asset, request.amount);

        // Immediately transfer the fee to the owner, cheaper than storing it
        if (request.fee > 0) {
            if (request.asset == address(0)) {
                SafeTransferLib.forceSafeTransferETH(owner(), request.fee);
            } else {
                SafeTransferLib.safeTransfer(request.asset, owner(), request.fee);
            }
        }

        statuses[hash_].claimed = true;

        emit RequestExecuted(RequestExecutionType.CLAIMED, hash_);
    }

    function claimMany(
        Request[] calldata requests,
        bytes[] calldata signatures
    ) external {
        for (uint256 i = 0; i < requests.length; i++) {
            claim(requests[i], signatures[i]);
        }
    }

    /**
     * @notice Allows the caller to withdraw funds if a valid signature is passed.
     * @dev At time of call, recipient will be equal to msg.sender.
     * @param request The withdraw request to get the hash of.
     * @return The hashed withdraw request.
     */
    function getHash(Request calldata request) public view returns (bytes32) {
        bytes32 validityDigest = keccak256(abi.encode(request.validUntil, request.validAfter));
        bytes32 callsDigest = keccak256(abi.encode(request.preCalls, request.postCalls));

        bytes32 digest = keccak256(
            abi.encode(
                address(this),
                request.claimChainId,
                request.withdrawChainId,
                request.asset,
                request.amount,
                request.recipient,
                request.withdrawChainId,
                request.claimChainId,
                request.nonce,
                validityDigest,
                callsDigest
            )
        );

        return MessageHashUtils.toEthSignedMessageHash(digest);
    }

    function getStatus(
        bytes32[] memory hashes
    ) external view returns (RequestStatus[] memory) {
        RequestStatus[] memory _statuses = new RequestStatus[](hashes.length);

        for (uint256 i = 0; i < hashes.length; i++) {
            _statuses[i] = statuses[hashes[i]];
        }

        return _statuses;
    }
}
