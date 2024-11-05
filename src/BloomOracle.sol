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

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IBloomOracle} from "@bloom-v2/interfaces/IBloomOracle.sol";
import {IOracleAdapter} from "@bloom-v2/interfaces/IOracleAdapter.sol";

contract BloomOracle is IBloomOracle, Ownable2Step {
    /// @notice Mapping of tokens to their respective oracle adapters.
    mapping(address token => address adapter) private _adapters;

    constructor(address owner) Ownable(owner) {}

    /*///////////////////////////////////////////////////////////////
                            Admin Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers an adapter for a token.
     * @param token Address of the token to register the adapter for.
     * @param adapter Address of the adapter to register.
     */
    function registerAdapter(address token, address adapter) external onlyOwner {
        _adapters[token] = adapter;
    }

    /*///////////////////////////////////////////////////////////////
                            View Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBloomOracle
    function getPriceUsd(address token) external view override returns (uint256) {
        return IOracleAdapter(_adapters[token]).getRate(token);
    }

    /// @inheritdoc IBloomOracle
    function getAdapter(address token) external view returns (address) {
        return _adapters[token];
    }
}