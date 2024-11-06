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

import {BorrowModule} from "../BorrowModule.sol";

/**
 * @title CCIPSenderModule
 * @notice A borrow module that allows for cross-chain borrowing using CCIP.
 * @dev This module still needs to be implemented for a specific protocol. Its only functionality is to send borrowed assets and messages to destination borrow modules.
 */
abstract contract CCIPSenderModule is BorrowModule {
    function _purchaseRwa(address borrower, uint256 totalCollateral, uint256 rwaPriceUsd)
        internal
        virtual
        override
        returns (uint256)
    {}

    function _repayRwa(uint256 amount) internal virtual override returns (uint256) {}
}
