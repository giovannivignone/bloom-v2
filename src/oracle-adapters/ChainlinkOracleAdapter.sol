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
import {IOracleAdapter} from "@bloom-v2/interfaces/IOracleAdapter.sol";

contract ChainlinkOracleAdapter is IOracleAdapter, Ownable2Step {
    struct RwaPriceFeed {
        address priceFeed;
        uint256 updateInterval;
        uint8 decimals;
    }

    mapping(address token => RwaPriceFeed priceFeed) private _priceFeeds;

    constructor(address owner) Ownable(owner) {}

    function getRate(address token) public view returns (uint256) {
        RwaPriceFeed memory priceFeed = _priceFeeds[token];
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed.priceFeed).latestRoundData();

        // Validate the latest round data from the price feed.
        require(answer > 0, Errors.InvalidPriceFeed());
        require(updatedAt >= block.timestamp - priceFeed.updateInterval, Errors.OutOfDate());

        uint256 scaler = 10 ** (18 - priceFeed.decimals);
        return uint256(answer) * scaler;
    }

    function registerPriceFeed(address token, address priceFeed, uint256 updateInterval, uint8 decimals)
        external
        onlyOwner
    {
        _priceFeeds[token] = RwaPriceFeed(priceFeed, updateInterval, decimals);
        uint256 price = getRate(token);
        require(price > 0, Errors.InvalidPriceFeed());
    }
}
