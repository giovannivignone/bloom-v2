// SPDX-License-Identifier: MIT
/*
██████╗░██╗░░░░░░█████╗░░█████╗░███╗░░░███╗
██╔══██╗██║░░░░░██╔══██╗██╔══██╗████╗░████║
██████╦╝██║░░░░░██║░░██║██║░░██║██╔████╔██║
██╔══██╗██║░░░░░██║░░██║██║░░██║██║╚██╔╝██║
██████╦╝███████╗╚█████╔╝╚█████╔╝██║░╚═╝░██║
╚═════╝░╚══════╝░╚════╝░░╚════╝░╚═╝░░░░░╚═╝
*/
pragma solidity 0.8.27;

import {IRouterClient} from "@chainlink-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink-ccip/applications/CCIPReceiver.sol";
import {BloomErrors as Errors} from "../../Helpers/BloomErrors.sol";
import {ICCIPModule} from "../../interfaces/ICCIPModule.sol";

/**
 * @title CCIPReceiverModule
 * @notice The contract that will be deployed on destination chains to receive assets and messages from the sender module.
 * @dev This module still needs to be implemented for a specific protocol. Its only functionality is to receive borrowed assets and messages from the sender module.
 */

abstract contract CCIPReceiverModule is ICCIPModule, CCIPReceiver {
    /// @notice The address of the corresponding CCIPSenderModule.
    address internal immutable _ccipSender;

    /// @notice The address of the asset being used to purchase RWA.
    address internal immutable _asset;

    /// @notice The address of the RWA being purchased.
    address internal immutable _rwa;

    /// @notice The source chain ID for the corresponding CCIPSenderModule.
    uint64 internal immutable _srcChainId;

    constructor(address asset, address rwa, uint64 srcChainId, address ccipRouter, address ccipSender)
        CCIPReceiver(ccipRouter)
    {
        require(
            asset != address(0) && rwa != address(0) && ccipRouter != address(0) && ccipSender != address(0),
            Errors.ZeroAddress()
        );
        _srcChainId = srcChainId;
        _ccipSender = ccipSender;
        _asset = asset;
        _rwa = rwa;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        require(
            keccak256(any2EvmMessage.sender) == keccak256(abi.encode(_ccipSender))
                && any2EvmMessage.sourceChainSelector == _srcChainId,
            Errors.InvalidSender()
        );

        _handleMessage(any2EvmMessage);
    }

    function _handleMessage(Client.Any2EVMMessage memory any2EvmMessage) internal {
        CCIPMessageData memory messageData = abi.decode(any2EvmMessage.data, (CCIPMessageData));
        if (messageData.messageType == MessageType.BORROW) {
            _afterReceiveBorrowMessage(messageData);
        } else {
            _afterReceiveRepayMessage(messageData);
        }
    }

    function _afterReceiveBorrowMessage(CCIPMessageData memory messageData) internal {
        _purchaseRwa(messageData.borrower, messageData.assetAmount, messageData.rwaAmount);
    }

    function _afterReceiveRepayMessage(CCIPMessageData memory messageData) internal {
        _repayRwa(messageData.borrower, messageData.rwaAmount, messageData.assetAmount);
    }

    function _purchaseRwa(address borrower, uint256 assetAmount, uint256 rwaAmount) internal virtual;

    function _repayRwa(address borrower, uint256 rwaAmount, uint256 assetAmount) internal virtual;

    receive() external payable {}
}
