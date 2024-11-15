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

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BloomErrors as Errors} from "../../helpers/BloomErrors.sol";

import {BorrowModule} from "../BorrowModule.sol";
import {ICCIPModule} from "../../interfaces/ICCIPModule.sol";

/**
 * @title CCIPSenderModule
 * @notice A borrow module that allows for cross-chain borrowing using CCIP.
 * @dev This module still needs to be implemented for a specific protocol. Its only functionality is to send borrowed assets and messages to destination borrow modules.
 */

abstract contract CCIPSenderModule is ICCIPModule, BorrowModule {
    using SafeERC20 for IERC20;

    /// @notice The destination chain ID for the corresponding CCIPReceiverModule.
    uint64 internal immutable _dstChainId;

    /// @notice The gas limit for the CCIP message.
    CCIPGasLimits internal _gasLimits;

    /// @notice The address of the CCIP router.
    IRouterClient internal immutable _ccipRouter;

    /// @notice The address of the corresponding CCIPReceiverModule.
    address internal immutable _ccipReceiver;

    constructor(
        address bloomPool,
        address bloomOracle,
        address rwa,
        uint256 initLeverage,
        uint256 initSpread,
        uint64 dstChainId,
        address ccipRouter,
        address ccipReceiver,
        address owner
    ) BorrowModule(bloomPool, bloomOracle, rwa, initLeverage, initSpread, owner) {
        require(dstChainId != 0, Errors.InvalidChainId());
        require(ccipReceiver != address(0) || ccipRouter != address(0), Errors.ZeroAddress());

        _dstChainId = dstChainId;
        _ccipRouter = IRouterClient(ccipRouter);
        _ccipReceiver = ccipReceiver;
    }

    function _purchaseRwa(address borrower, uint256 totalCollateral, uint256 rwaAmount)
        internal
        virtual
        override
        returns (uint256)
    {
        MessageType messageType = MessageType.BORROW;
        CCIPMessageData memory borrowMessage = CCIPMessageData({
            messageType: MessageType.BORROW,
            borrower: borrower,
            assetAmount: totalCollateral,
            rwaAmount: rwaAmount
        });

        bytes memory data = abi.encode(borrowMessage);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(_asset), amount: totalCollateral});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_ccipReceiver),
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: address(0), // address(0) is the native token setting
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: gasLimit(messageType), allowOutOfOrderExecution: false})
            )
        });

        _sendMessage(message);

        uint256 rwaPreBalance = _rwa.balanceOf(address(this));
        _afterBorrowMessage(rwaAmount);
        uint256 rwaPostBalance = _rwa.balanceOf(address(this));

        return rwaPostBalance - rwaPreBalance;
    }

    function _repayRwa(uint256 rwaAmount) internal virtual override returns (uint256) {
        _beforeRepayMessage(rwaAmount);

        MessageType messageType = MessageType.REPAY;
        uint256 assetAmount = _bloomOracle.getQuote(rwaAmount, address(_rwa), address(_asset));

        CCIPMessageData memory repayMessage = CCIPMessageData({
            messageType: MessageType.REPAY,
            borrower: address(0), // This is irrelevant for repayments
            assetAmount: assetAmount,
            rwaAmount: rwaAmount
        });

        bytes memory data = abi.encode(repayMessage);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_ccipReceiver),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No tokens to send
            feeToken: address(0), // address(0) is the native token setting
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: gasLimit(messageType), allowOutOfOrderExecution: false})
            )
        });

        _sendMessage(message);

        return assetAmount;
    }

    function _sendMessage(Client.EVM2AnyMessage memory message) internal virtual {
        uint256 fees = _ccipRouter.getFee(_dstChainId, message);
        _ccipRouter.ccipSend{value: fees}(_dstChainId, message);
    }

    function setGasLimits(uint128 borrowGasLimit_, uint128 repayGasLimit_) external onlyOwner {
        _gasLimits = CCIPGasLimits({borrowGasLimit: borrowGasLimit_, repayGasLimit: repayGasLimit_});
    }

    function gasLimit(MessageType messageType) public view returns (uint256) {
        if (messageType == MessageType.BORROW) {
            return uint256(_gasLimits.borrowGasLimit);
        } else {
            return uint256(_gasLimits.repayGasLimit);
        }
    }

    function _afterBorrowMessage(uint256 rwaAmount) internal virtual;

    function _beforeRepayMessage(uint256 rwaAmount) internal virtual;

    receive() external payable {}
}
