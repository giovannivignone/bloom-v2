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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BloomErrors} from "@bloom-v2/helpers/BloomErrors.sol";
import {BloomTestSetup} from "../BloomTestSetup.t.sol";
import {IBloomPool} from "@bloom-v2/interfaces/IBloomPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BloomPool} from "@bloom-v2/BloomPool.sol";

contract LendUnitTests is BloomTestSetup {
    function setUp() public override {
        super.setUp();
    }

    function testLendOrder(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        stable.mint(alice, amount);
        
        uint256 preAliceBalance = stable.balanceOf(alice);
        
        vm.startPrank(alice);
        stable.approve(address(bloomPool), amount);
        bloomPool.lendOrder(amount);
        vm.stopPrank();

        // Alice Balance Decreases
        assertEq(stable.balanceOf(alice), preAliceBalance - amount);
        // Bloom Pool Balance Increases
        assertEq(stable.balanceOf(address(bloomPool)), amount);

        // Order state increases
        assertEq(bloomPool.amountOpen(alice), amount);
        assertEq(bloomPool.openDepth(), amount);

        // Last Minted Id does not change
        assertEq(bloomPool.lastMintedId(), type(uint256).max);
    }
}
