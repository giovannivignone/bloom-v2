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

import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";

import {BloomErrors as Errors} from "@bloom-v2/Helpers/BloomErrors.sol";
import {ICCIPModule} from "@bloom-v2/interfaces/ICCIPModule.sol";

/**
 * @title CCIPReceiverModule
 * @notice The contract that will be deployed on destination chains to receive assets and messages from the sender module.
 * @dev This module still needs to be implemented for a specific protocol. Its only functionality is to receive borrowed assets and messages from the sender module.
 */
abstract contract CCIPReceiverModule is ICCIPModule, CCIPReceiver {
    /*///////////////////////////////////////////////////////////////
                                Storage    
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the asset being used to purchase RWA.
    address internal immutable _asset;

    /// @notice The address of the RWA being purchased.
    address internal immutable _rwa;

    /// @notice The address of the corresponding CCIPSenderModule.
    address internal immutable _ccipSender;

    /// @notice The source chain ID for the corresponding CCIPSenderModule.
    uint64 internal immutable _srcChainId;

    /*///////////////////////////////////////////////////////////////
                                Constructor    
    //////////////////////////////////////////////////////////////*/

    constructor(address asset_, address rwa_, uint64 srcChainId_, address ccipRouter, address ccipSender_)
        CCIPReceiver(ccipRouter)
    {
        require(
            asset_ != address(0) && rwa_ != address(0) && ccipRouter != address(0) && ccipSender_ != address(0),
            Errors.ZeroAddress()
        );
        _srcChainId = srcChainId_;
        _ccipSender = ccipSender_;
        _asset = asset_;
        _rwa = rwa_;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Custom receive logic that is executed by the CCIP router contract
     * @param any2EvmMessage The Any2EVMMessage struct returned by CCIP Messages
     */
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        require(
            keccak256(any2EvmMessage.sender) == keccak256(abi.encode(_ccipSender))
                && any2EvmMessage.sourceChainSelector == _srcChainId,
            Errors.InvalidSender()
        );

        _routeMessage(any2EvmMessage);
    }

    /**
     * @notice Routes the incoming Chainlink CCIP message to the proper handler function
     * @param any2EvmMessage The Any2EVMMessage struct returned by CCIP Messages
     */
    function _routeMessage(Client.Any2EVMMessage memory any2EvmMessage) internal {
        CCIPMessageData memory messageData = abi.decode(any2EvmMessage.data, (CCIPMessageData));
        if (messageData.messageType == MessageType.BORROW) {
            _handleBorrow(messageData);
        } else {
            _handleRepay(messageData);
        }
    }

    /**
     * @notice Executes the purchase and of the RWA token with the borrowed funds.
     * @param messageData All message data sent within the CCIP message, formatted into the CCIPMessageData struct.
     */
    function _handleBorrow(CCIPMessageData memory messageData) internal {
        _purchaseRwa(messageData.borrower, messageData.assetAmount, messageData.rwaAmount);
    }

    /**
     * @notice Executes the repayment of the loan.
     * @param messageData All message data sent within the CCIP message, formatted into the CCIPMessageData struct.
     */
    function _handleRepay(CCIPMessageData memory messageData) internal {
        _repayRwa(messageData.borrower, messageData.rwaAmount, messageData.assetAmount);
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Interface    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Custom RWA purchase logic that integrators must implement within the child contract.
     * @param borrower Address of the borrower who is executing this purchase.
     * @param assetAmount The amount of assets being used to purchase the RWA token.
     * @param rwaAmount The amount of RWA the borrower is desiring to purchase.
     */
    function _purchaseRwa(address borrower, uint256 assetAmount, uint256 rwaAmount) internal virtual;

    /**
     * @notice Custom RWA repayment logic that integrators must implement within the child contract.
     * @param borrower Address of the borrower who is executing this purchase.
     * @param rwaAmount The amount of RWA the borrower is repaying.
     * @param assetAmount The amount of assets the borrower is expecting to be returned.
     */
    function _repayRwa(address borrower, uint256 rwaAmount, uint256 assetAmount) internal virtual;

    /*///////////////////////////////////////////////////////////////
                            View Functions    
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the asset being used to purchase RWA.
    function asset() external view returns (address) {
        return _asset;
    }

    /// @notice The address of the RWA being purchased.
    function rwa() external view returns (address) {
        return _rwa;
    }

    /// @notice The address of the corresponding CCIPSenderModule.
    function ccipSender() external view returns (address) {
        return _ccipSender;
    }

    /// @notice The source chain ID for the corresponding CCIPSenderModule.
    function srcChainId() external view returns (uint64) {
        return _srcChainId;
    }

    /*///////////////////////////////////////////////////////////////
                            General Functions    
    //////////////////////////////////////////////////////////////*/

    /// @notice Ability to receive Native currency payments
    receive() external payable {}
}
