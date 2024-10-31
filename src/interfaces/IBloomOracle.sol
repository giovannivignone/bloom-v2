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

interface IBloomOracle {
    /*///////////////////////////////////////////////////////////////
                              Functions
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Get the price of a token in terms of USD.
     * @param token The address of the token.
     * @return The price of the token in USD scaled by 1e18.
     */
    function getPriceUsd(address token) external view returns (uint256);

    /**
     * @notice Returns the adapter for a token.
     * @param token Address of the token to get the adapter for.
     */
    function getAdapter(address token) external view returns (address);
}
