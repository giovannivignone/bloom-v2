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

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib as FpMath} from "@solady/utils/FixedPointMathLib.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BloomErrors} from "@bloom-v2/helpers/BloomErrors.sol";
import {BloomTestSetup} from "../BloomTestSetup.t.sol";
import {IBloomPool} from "@bloom-v2/interfaces/IBloomPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BloomPool} from "@bloom-v2/BloomPool.sol";
import {MockBorrowModule} from "../mocks/MockBorrowModule.sol";
import {BloomOracle} from "@bloom-v2/oracle/BloomOracle.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ChainlinkOracle} from "@bloom-v2/oracle/chainlink/ChainlinkOracle.sol";
import {CrossAdapter} from "@bloom-v2/oracle/CrossAdapter.sol";

contract BorrowUnitTests is BloomTestSetup {
    using FpMath for uint256;

    MockBorrowModule internal mockBorrowModule;
    BloomOracle internal bloomOracle;

    MockPriceFeed internal usdcPriceFeed;

    function setUp() public override {
        super.setUp();

        // deploy Bloom Oracle
        bloomOracle = new BloomOracle(address(owner));
        address usd = address(0x0000000000000000000000000000000000000348);

        vm.startPrank(owner);
        usdcPriceFeed = new MockPriceFeed(8);
        usdcPriceFeed.setLatestRoundData(1, 1e8, 0, block.timestamp, 1);
        vm.stopPrank();

        ChainlinkOracle chainlinkOracle1 =
            new ChainlinkOracle(address(billToken), address(usd), address(priceFeed), 1 days);

        ChainlinkOracle chainlinkOracle2 =
            new ChainlinkOracle(address(stable), address(usd), address(usdcPriceFeed), 1 days);

        CrossAdapter crossAdapter = new CrossAdapter(
            address(billToken), address(usd), address(stable), address(chainlinkOracle1), address(chainlinkOracle2)
        );

        // Todo: Add a 2 step oracle
        vm.startPrank(owner);
        bloomOracle.setConfig(address(billToken), address(usd), address(chainlinkOracle1));
        bloomOracle.setConfig(address(stable), address(usd), address(chainlinkOracle2));
        bloomOracle.setConfig(address(billToken), address(stable), address(crossAdapter));
        // deploy mock borrow module
        mockBorrowModule =
            new MockBorrowModule(address(bloomPool), address(bloomOracle), address(billToken), 50e18, 0.995e18, owner);

        bloomPool.addBorrowModule(address(mockBorrowModule));
    }

    function testBorrowSingleBorrower() public {
        uint256 amount = 100e6;

        _createLendOrder(alice, amount);
        lenders.push(alice);

        uint256 borrowAmount = 2e6;
        stable.mint(borrower1, borrowAmount);

        vm.startPrank(owner);
        mockBorrowModule.whitelistBorrower(borrower1, true);
        vm.stopPrank();

        vm.startPrank(borrower1);
        stable.approve(address(mockBorrowModule), borrowAmount);
        bloomPool.borrow(lenders, address(mockBorrowModule), amount);

        uint256 lastMintedTby = mockBorrowModule.lastMintedId();

        assertEq(bloomPool.lastMintedId(), lastMintedTby);
        assertEq(billToken.balanceOf(address(mockBorrowModule)), 1.02e18);
        assertEq(stable.balanceOf(address(mockBorrowModule)), 0);

        // Assert that the state variables are updated correctly
        assertEq(mockBorrowModule.tbyCollateral(lastMintedTby).rwaAmount, 1.02e18);
        assertEq(mockBorrowModule.rwaPrice(lastMintedTby).startPrice, 100e18);
        assertEq(bloomPool.tbyMaturity(lastMintedTby).start, block.timestamp);
        assertEq(bloomPool.tbyMaturity(lastMintedTby).end, block.timestamp + 180 days);
    }
}
