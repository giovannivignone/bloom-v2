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

import {Script, console} from "forge-std/Script.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {BloomPool} from "../src/BloomPool.sol";
import {Tby} from "../src/token/Tby.sol";

contract MintTby is Script {
    address public owner = address(0);
    address[] public accounts;

    BloomPool public pool = BloomPool(0x43E779D0EA135a82beC2Bc22A9CD4E0b50e0C59C);
    MockERC20 public stable = MockERC20(0x0dfda9C55381949cafF24dbe0fB61f34be8c4832);
    MockERC20 public billToken = MockERC20(0x6E6132E8D7126c53458aD6CA047305F7D561A837);
    MockPriceFeed public priceFeed = MockPriceFeed(0xCf164aDC540daAfb7E80ACb51a91A98869d857d8);

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address deployer = vm.addr(deployerPrivateKey);

        // accounts.push(deployer);
        // // accounts.push(0xb175E47C3Ee349b0336aC85478D98eF4e3a78Eda);

        // if (owner == address(0)) {
        //     owner = deployer;
        // }

        priceFeed.setLatestRoundData(1, 105e8, block.timestamp, block.timestamp, 1);
        // uint256 usdcAmount = 100e6;
        // stable.mint(deployer, usdcAmount);
        // stable.approve(address(pool), usdcAmount);
        // pool.lendOrder(usdcAmount);

        // stable.mint(deployer, 100e6);
        // stable.approve(address(pool), 100e6);
        // (uint256 filledAmount, uint256 borrowAmount) = pool.fillOrders(accounts, 100e6);

        // uint256 totalUsdcNeeded = filledAmount + borrowAmount;

        // billToken.mint(deployer, 30_000e18);
        // billToken.approve(address(pool), 30_000e18);

        // (uint256 id, ) = pool.swapIn(accounts, totalUsdcNeeded);
        // console.log("id", id);
        // Tby(pool.tby()).safeTransferFrom(
        //     deployer,
        //     0xe909e991A27B22703f9090359E1a65FeBe75fe89,
        //     id,
        //     100e6,
        //     ""
        // );
    }
}
