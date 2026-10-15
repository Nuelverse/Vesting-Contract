// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VestingContract} from "../src/VestingContract.sol";

contract VestingTest is Test {
    MockERC20 mockERC20;
    address Alice; // the contract owner
    address Peter; // the beneficiary
    address Stranger; // to test "non-owner can't revoke"
    VestingContract vestingContract;
    uint256 constant ALLOCATION = 1200e18; // 1200 mockERC20
    uint256 constant CLIFF = 90 days; // 3 months
    uint256 constant DURATION = 360 days; // 12 months

    function setUp() public {
        Alice = makeAddr("ALICE");
        Peter = makeAddr("PETER");
        Stranger = makeAddr("STRANGER");

        vm.startPrank(Alice);
        mockERC20 = new MockERC20();
        mockERC20.mint(Alice, ALLOCATION);
        vestingContract = new VestingContract(address(mockERC20));
        mockERC20.approve(address(vestingContract), ALLOCATION);
        vm.stopPrank();
    }

    function _setSchedule() private returns (uint256) {
        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, CLIFF, ALLOCATION, DURATION);
        (uint256 start,,,,,) = vestingContract.beneficiarySchedule(Peter);
        return start;
    }

    // ----- calculateVestedAmount ------- //

    function test_Vested_RightAfterCreation_IsZero() external {
        _setSchedule();
        assertEq(vestingContract.calculateVestedAmount(Peter), 0);
    }

    function test_Vested_OneSecondBeforeCliff_IsZero() external {
        uint256 start = _setSchedule();
        vm.warp((start + CLIFF) - 1);
        assertEq(vestingContract.calculateVestedAmount(Peter), 0);
    }

    function test_Vested_ExactlyAtCliff_IsQuarter() external {
        uint256 start = _setSchedule();
        vm.warp(start + CLIFF);
        assertEq(vestingContract.calculateVestedAmount(Peter), 300e18);
    }

    function test_Vested_Halfway_IsHalf() external {
        uint256 halfWay = 180 days;
        _setSchedule();
        vm.warp(block.timestamp + halfWay);
        assertEq(vestingContract.calculateVestedAmount(Peter), 600e18);
    }

    function test_Vested_ExactlyAtEnd_IsFullAllocation() external {
        uint256 exactlyAtEnd = 360 days;
        _setSchedule();
        vm.warp(block.timestamp + exactlyAtEnd);
        assertEq(vestingContract.calculateVestedAmount(Peter), 1200e18);
    }

    function test_Vested_LongAfterEnd_StaysCappedAtAllocation() external {
        uint256 LongAfterEnd = 1000 days;
        _setSchedule();
        vm.warp(block.timestamp + LongAfterEnd);
        assertEq(vestingContract.calculateVestedAmount(Peter), 1200e18);
    }
}
