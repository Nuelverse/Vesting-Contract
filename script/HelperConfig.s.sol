// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address tokenAddress;
    }
    error UnsupportedChain();

    NetworkConfig public netConfig;

    constructor() {
        if (block.chainid == 11155111) {
            netConfig = getSepoliaConfig();
        } else if (block.chainid == 31337) {
            netConfig = getOrCreateAnvilConfig();
        } else {
            revert UnsupportedChain();
        }
    }

    function _deployMockERC20() private returns (NetworkConfig memory) {
        vm.startBroadcast();
        MockERC20 mockERC20 = new MockERC20();
        vm.stopBroadcast();
        return NetworkConfig({tokenAddress: address(mockERC20)});
    }

    function getSepoliaConfig() private returns (NetworkConfig memory) {
        return _deployMockERC20();
    }

    function getOrCreateAnvilConfig() private returns (NetworkConfig memory) {
        if (netConfig.tokenAddress != address(0)) {
            return netConfig;
        }
        return _deployMockERC20();
    }
}
