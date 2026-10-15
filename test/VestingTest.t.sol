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

    // ----- claimVesting ------- //

    function test_Claim_Halfway_PaysHalf() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Peter);
        vestingContract.claimVesting();
        assertEq(mockERC20.balanceOf(Peter), 600e18);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 600e18);
    }

    function test_RevertWhen_ClaimingDuringCliff() external {
        uint256 start = _setSchedule();
        vm.warp(start + 30 days);
        vm.expectRevert(VestingContract.NothingToClaim.selector);
        vm.prank(Peter);
        vestingContract.claimVesting();
    }

    function test_Claim_TwiceInARow_SecondRevertsWithNothingToClaim() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Peter);
        vestingContract.claimVesting();
        vm.expectRevert(VestingContract.NothingToClaim.selector);
        vm.prank(Peter);
        vestingContract.claimVesting();
    }

    function test_Claim_AfterEarlierClaim_PaysOnlyNewlyVested() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Peter);
        vestingContract.claimVesting();
        vm.warp(start + 270 days);
        vm.prank(Peter);
        vestingContract.claimVesting();
        assertEq(mockERC20.balanceOf(Peter), 900e18);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 300e18);
    }

    // ----- revokeVesting ------- //

    function test_Revoke_MidSchedule_ReturnsUnvestedToOwner() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        assertEq(mockERC20.balanceOf(Alice), 600e18);
    }

    function test_Revoke_BeneficiaryCanStillClaimVestedAmount() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);
        vm.prank(Peter);
        vestingContract.claimVesting();

        assertEq(mockERC20.balanceOf(Alice), 600e18);
        assertEq(mockERC20.balanceOf(Peter), 600e18);
    }

    function test_Revoke_OwnerPlusBeneficiaryEqualsDeposit() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);
        vm.prank(Peter);
        vestingContract.claimVesting();

        assertEq(mockERC20.balanceOf(Alice) + mockERC20.balanceOf(Peter), 1200e18);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 0);
    }

    function test_Revoke_FreezesVestedAtRevokeTime() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        vm.warp(start + 300 days);
        assertEq(vestingContract.calculateVestedAmount(Peter), 600e18);
    }

    function test_Revoke_DuringCliff_ReturnsWholeAllocation() external {
        uint256 start = _setSchedule();
        vm.warp(start + 30 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        assertEq(mockERC20.balanceOf(Alice), 1200e18);
        assertEq(vestingContract.calculateVestedAmount(Peter), 0);
    }

    function test_RevertWhen_StrangerRevokes() external {
        uint256 start = _setSchedule();
        vm.warp(start + 30 days);

        vm.expectRevert(VestingContract.NotOwner.selector);
        vm.prank(Stranger);
        vestingContract.revokeVesting(Peter);
    }

    function test_RevertWhen_RevokingTwice() external {
        uint256 start = _setSchedule();
        vm.warp(start + 30 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        vm.expectRevert(VestingContract.ScheduleAlreadyRevoked.selector);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);
    }

    function test_RevertWhen_RevokingFullyVestedSchedule() external {
        uint256 start = _setSchedule();
        vm.warp(start + 360 days);

        vm.expectRevert(VestingContract.NothingToRevoke.selector);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);
    }
}
