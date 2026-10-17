// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {VestingContract} from "../src/VestingContract.sol";

contract DeployVesting is Script {
    function run() public returns (VestingContract, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address tokenAddress) = helperConfig.netConfig();
        vm.startBroadcast();
        VestingContract vestingContract = new VestingContract(tokenAddress);
        vm.stopBroadcast();
        return (vestingContract, helperConfig);
    }
}
