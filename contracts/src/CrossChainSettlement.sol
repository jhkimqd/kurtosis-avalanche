// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import './Institutional.sol';

interface IWarp {
    struct WarpMessage { bytes32 sourceChainID; address originSenderAddress; bytes payload; }
    function sendWarpMessage(bytes calldata data) external returns (bytes32);
    function getVerifiedWarpMessage(uint32 index) external view returns (WarpMessage memory, bool);
}

/// Destination has one irreversible decision. Source refunds only an authenticated abort.
/// A timeout permits an abort request; it does not release escrow locally.
contract CrossChainSettlement {
    enum State { Unknown, Escrowed, Committed, Aborted }
    struct Payment { address payer; address recipient; uint256 amount; uint256 deadline; State state; }
    IWarp constant WARP = IWarp(0x0200000000000000000000000000000000000005);
    Ledger public immutable cash;
    bytes32 public immutable remoteChain;
    address public immutable remoteContract;
    mapping(bytes32 => Payment) public payments;
    mapping(bytes32 => State) public decisions;
    mapping(address => uint256) public received;
    mapping(bytes32 => bytes32) public payloadHash;
    mapping(bytes32 => bool) public refundPending;
    constructor(Ledger cash_, bytes32 remoteChain_, address remoteContract_) {
        require(remoteContract_ != address(0), "remote"); cash = cash_; remoteChain = remoteChain_; remoteContract = remoteContract_;
    }
    function operationID(address payer, bytes32 businessID) public view returns (bytes32) { return keccak256(abi.encode(block.chainid,address(this),payer,businessID)); }
    function open(bytes32 id, address recipient, uint256 amount, uint256 deadline) external {
        id = operationID(msg.sender,id);
        require(payments[id].state == State.Unknown && amount > 0 && recipient != address(0) && deadline > block.timestamp, "payment");
        payments[id] = Payment(msg.sender, recipient, amount, deadline, State.Escrowed);
        cash.transferFrom(msg.sender, address(this), amount);
        WARP.sendWarpMessage(abi.encode(uint8(0), id, recipient, amount, deadline));
    }
    function requestAbort(bytes32 id) external {
        Payment memory p = payments[id]; require(p.state == State.Escrowed && block.timestamp > p.deadline, "pending");
        WARP.sendWarpMessage(abi.encode(uint8(1), id, p.recipient, p.amount, p.deadline));
    }
    function claimRefund(bytes32 id) external {
        Payment memory p = payments[id]; require(p.payer == msg.sender && refundPending[id], "refund");
        refundPending[id] = false; cash.transfer(p.payer,p.amount);
    }
    function receiveMessage(uint32 index) external {
        (IWarp.WarpMessage memory m, bool valid) = WARP.getVerifiedWarpMessage(index);
        require(valid && m.sourceChainID == remoteChain && m.originSenderAddress == remoteContract, "origin");
        (uint8 kind, bytes32 id, address recipient, uint256 amount, uint256 deadline) = abi.decode(m.payload, (uint8,bytes32,address,uint256,uint256));
        if (kind <= 1) {
            bytes32 binding = keccak256(abi.encode(recipient,amount,deadline));
            require(payloadHash[id] == bytes32(0) || payloadHash[id] == binding, "payload");
            payloadHash[id] = binding;
            State decision = decisions[id];
            if (decision == State.Unknown) {
                decision = kind == 0 && block.timestamp <= deadline ? State.Committed : State.Aborted;
                decisions[id] = decision;
                if (decision == State.Committed) received[recipient] += amount;
            }
            // Duplicate messages return the original terminal decision without double credit.
            WARP.sendWarpMessage(abi.encode(decision == State.Committed ? uint8(2) : uint8(3), id, recipient, amount, deadline));
        } else {
            require(kind == 2 || kind == 3, "kind");
            Payment storage p = payments[id];
            require(p.state != State.Unknown && p.recipient == recipient && p.amount == amount && p.deadline == deadline, "binding");
            State finalState = kind == 2 ? State.Committed : State.Aborted;
            if (p.state != State.Escrowed) { require(p.state == finalState, "conflict"); return; }
            p.state = finalState;
            // Committed payments remain locked as backing for the destination accounting credit.
            if (finalState == State.Aborted) refundPending[id] = true;
        }
    }
}
