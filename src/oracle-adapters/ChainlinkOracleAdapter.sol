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
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";
import {BloomErrors as Errors} from "@bloom-v2/helpers/BloomErrors.sol";
import {IChainlinkOracleAdapter, IOracleAdapter} from "@bloom-v2/interfaces/IChainlinkOracleAdapter.sol";

contract ChainlinkOracleAdapter is IChainlinkOracleAdapter, Ownable2Step {
    /*///////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Mapping of token address to RWA price feed.
    mapping(address token => RwaPriceFeed priceFeed) private _priceFeeds;

    constructor(address owner) Ownable(owner) {}

    /*///////////////////////////////////////////////////////////////
                            View Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOracleAdapter
    function getRate(address token) public view override returns (uint256) {
        RwaPriceFeed memory priceFeed_ = _priceFeeds[token];
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed_.priceFeed).latestRoundData();

        // Validate the latest round data from the price feed.
        require(answer > 0, Errors.InvalidPriceFeed());
        require(updatedAt >= block.timestamp - priceFeed_.updateInterval, Errors.OutOfDate());

        uint256 scaler = 10 ** (18 - priceFeed_.decimals);
        return uint256(answer) * scaler;
    }

    /// @inheritdoc IChainlinkOracleAdapter
    function priceFeed(address token) external view override returns (RwaPriceFeed memory) {
        return _priceFeeds[token];
    }

    /*///////////////////////////////////////////////////////////////
                            Admin Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a price feed for an RWA token.
     * @param token The address of the token to register the price feed for.
     * @param priceFeed_ The address of the price feed.
     * @param updateInterval The interval in seconds at which the price feed should be updated.
     * @param decimals The number of decimals the price feed returns.
     */
    function registerPriceFeed(address token, address priceFeed_, uint64 updateInterval, uint8 decimals)
        external
        onlyOwner
    {
        _priceFeeds[token] = RwaPriceFeed(priceFeed_, updateInterval, decimals);
        uint256 price = getRate(token);
        require(price > 0, Errors.InvalidPriceFeed());

        emit RwaPriceFeedSet(priceFeed_);
    }
}
