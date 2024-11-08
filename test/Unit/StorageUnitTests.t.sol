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

import {BloomTestSetup} from "../BloomTestSetup.t.sol";
import {IBloomPool} from "@bloom-v2/interfaces/IBloomPool.sol";

contract StorageUnitTests is BloomTestSetup {
    function setUp() public override {
        super.setUp();
    }

    function testTby() public view {
        assertEq(bloomPool.tby(), address(tby));
    }

    function testAsset() public view {
        assertEq(bloomPool.asset(), address(stable));
    }

    function testAssetDecimals() public view {
        assertEq(bloomPool.assetDecimals(), stable.decimals());
    }

    function testMinOrderSize() public view {
        assertEq(bloomPool.minOrderSize(), 1e6);
    }

    function testLastMintedId() public view {
        assertEq(bloomPool.lastMintedId(), type(uint256).max);
    }
}
