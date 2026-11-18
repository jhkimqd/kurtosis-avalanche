// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Records authenticated ICM deliveries for the nightly integration tests.
contract MessageReceiver {
    address public immutable messenger;
    mapping(bytes32 => bool) public receivedMessages;

    event MessageReceived(bytes32 indexed envelopeHash);

    constructor(address messenger_) {
        require(messenger_ != address(0), "messenger");
        messenger = messenger_;
    }

    function receiveTeleporterMessage(bytes32 sourceBlockchainID, address originSenderAddress, bytes calldata message) external {
        require(msg.sender == messenger, "only messenger");
        bytes32 envelopeHash = keccak256(abi.encode(sourceBlockchainID, originSenderAddress, message));
        receivedMessages[envelopeHash] = true;
        emit MessageReceived(envelopeHash);
    }
}
