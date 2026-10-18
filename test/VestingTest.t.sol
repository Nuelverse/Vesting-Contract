// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeployVesting} from "../script/DeployVesting.s.sol";
import {VestingContract} from "../src/VestingContract.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VestingTest is Test {
    MockERC20 mockERC20;
    address Alice; // the Default sender
    address Peter; // the beneficiary
    address Stranger; // to test "non-owner can't revoke"
    VestingContract vestingContract;
    uint256 constant ALLOCATION = 1200e18; // 1200 mockERC20
    uint256 constant CLIFF = 90 days; // 3 months
    uint256 constant DURATION = 360 days; // 12 months

    event VestingScheduled(
        address indexed beneficiary, uint256 allocation, uint256 cliffDuration, uint256 totalDuration
    );
    event VestingClaimed(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 amountRevoked);

    function setUp() public {
        Alice = DEFAULT_SENDER;
        Peter = makeAddr("PETER");
        Stranger = makeAddr("STRANGER");
        DeployVesting deployVesting = new DeployVesting();
        (VestingContract vestContract, HelperConfig helperConfig) = deployVesting.run();
        vm.startPrank(Alice);
        mockERC20 = MockERC20(helperConfig.netConfig());
        mockERC20.mint(Alice, ALLOCATION);
        vestingContract = vestContract;
        mockERC20.approve(address(vestingContract), ALLOCATION);
        vm.stopPrank();
    }

    function _setSchedule() private returns (uint256) {
        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, CLIFF, ALLOCATION, DURATION);
        (uint256 start,,,,,) = vestingContract.beneficiarySchedule(Peter);
        return start;
    }

    //------ Constructor-----//
    function test_RevertWhen_TokenIsZeroAddress() external {
        vm.expectRevert(VestingContract.AddressZero.selector);
        new VestingContract(address(0));
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
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        assertEq(vestingContract.calculateVestedAmount(Peter), 600e18);
    }

    function test_Vested_ExactlyAtEnd_IsFullAllocation() external {
        uint256 start = _setSchedule();
        vm.warp(start + 360 days);
        assertEq(vestingContract.calculateVestedAmount(Peter), 1200e18);
    }

    function test_Vested_LongAfterEnd_StaysCappedAtAllocation() external {
        uint256 start = _setSchedule();
        vm.warp(start + 1000 days);
        assertEq(vestingContract.calculateVestedAmount(Peter), 1200e18);
    }

    function test_RevertWhen_VestedQueriedForUnknownBeneficiary() external {
        vm.expectRevert(VestingContract.NoSchedule.selector);
        vestingContract.calculateVestedAmount(Stranger);
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

    function test_RevertWhen_ClaimingWithoutSchedule() external {
        vm.expectRevert(VestingContract.NoSchedule.selector);
        vm.prank(Stranger);
        vestingContract.claimVesting();
    }

    // ----- revokeVesting ------- //

    function test_Revoke_MidSchedule_ReturnsUnvestedToOwner() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        assertEq(mockERC20.balanceOf(Alice), 600e18);
    }

    function test_RevertWhen_RevokingWithoutSchedule() external {
        vm.expectRevert(VestingContract.NoSchedule.selector);
        vm.prank(Alice);
        vestingContract.revokeVesting(Stranger);
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

    function test_Revoke_AfterEarlierClaim_BalancesStillAddUp() external {
        uint256 start = _setSchedule();
        vm.warp(start + 90 days);
        vm.prank(Peter);
        vestingContract.claimVesting();
        vm.warp(start + 180 days);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        assertEq(mockERC20.balanceOf(Alice), 600e18);
        vm.prank(Peter);
        vestingContract.claimVesting();

        assertEq(mockERC20.balanceOf(Alice) + mockERC20.balanceOf(Peter), 1200e18);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 0);
    }

    // ----- setVestingSchedule ------- //

    function test_SetSchedule_PullsTokensFromOwner() external {
        _setSchedule();
        assertEq(mockERC20.balanceOf(Alice), 0);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 1200e18);
    }

    function test_RevertWhen_StrangerSetsSchedule() external {
        vm.expectRevert(VestingContract.NotOwner.selector);
        vm.prank(Stranger);
        vestingContract.setVestingSchedule(Peter, CLIFF, ALLOCATION, DURATION);
    }

    function test_RevertWhen_ScheduleAlreadyExists() external {
        _setSchedule();
        vm.expectRevert(VestingContract.ScheduleAlreadyExists.selector);
        _setSchedule();
    }

    function test_RevertWhen_BeneficiaryIsZeroAddress() external {
        vm.expectRevert(VestingContract.AddressZero.selector);
        vm.prank(Alice);
        vestingContract.setVestingSchedule(address(0), CLIFF, ALLOCATION, DURATION);
    }

    function test_RevertWhen_AllocationIsZero() external {
        vm.expectRevert(VestingContract.ZeroAllocation.selector);
        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, CLIFF, 0, DURATION);
    }

    function test_RevertWhen_DurationIsZero() external {
        vm.expectRevert(VestingContract.ZeroDuration.selector);
        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, CLIFF, ALLOCATION, 0);
    }

    function test_RevertWhen_CliffLongerThanDuration() external {
        vm.expectRevert(VestingContract.CliffLongerThanDuration.selector);
        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, 1000 days, ALLOCATION, DURATION);
    }

    function test_SetSchedule_StoresTheSchedule() external {
        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, CLIFF, ALLOCATION, DURATION);
        (
            uint256 start,
            uint256 cliff,
            uint256 allocation,
            uint256 duration,
            uint256 claimedAmount,
            uint256 timeRevoked
        ) = vestingContract.beneficiarySchedule(Peter);
        assertEq(start, block.timestamp);
        assertEq(cliff, CLIFF);
        assertEq(allocation, ALLOCATION);
        assertEq(duration, DURATION);
        assertEq(claimedAmount, 0);
        assertEq(timeRevoked, 0);
    }

    function test_SetSchedule_EmitsVestingScheduled() external {
        vm.expectEmit(true, false, false, true);
        emit VestingScheduled(Peter, ALLOCATION, CLIFF, DURATION);
        _setSchedule();
    }

    function test_Claim_EmitsVestingClaimed() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.expectEmit(true, false, false, true);
        emit VestingClaimed(Peter, 600e18);
        vm.prank(Peter);
        vestingContract.claimVesting();
    }

    function test_Revoke_EmitsVestingRevoked() external {
        uint256 start = _setSchedule();
        vm.warp(start + 180 days);
        vm.expectEmit(true, false, false, true);
        emit VestingRevoked(Peter, 600e18);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);
    }

    function test_RevertWhen_OwnerHasNotApproved() external {
        vm.startPrank(Alice);
        mockERC20 = new MockERC20();
        mockERC20.mint(Alice, ALLOCATION);
        vestingContract = new VestingContract(address(mockERC20));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(vestingContract), 0, ALLOCATION
            )
        );
        _setSchedule();
    }

    // ----- fuzz ------- //

    function testFuzz_Vested_NeverExceedsAllocation(uint256 secondsElapsed) external {
        uint256 sElapsed = bound(secondsElapsed, 0, 2000 days);
        uint256 start = _setSchedule();
        vm.warp(start + sElapsed);
        assertLe(vestingContract.calculateVestedAmount(Peter), ALLOCATION);
    }

    function testFuzz_Vested_NeverDecreasesOverTime(uint256 firstDay, uint256 extraDays) external {
        firstDay = bound(firstDay, 0, 1200 days);
        extraDays = bound(extraDays, 0, 50 days);
        uint256 start = _setSchedule();
        vm.warp(start + firstDay);
        uint256 vestedBefore = vestingContract.calculateVestedAmount(Peter);
        vm.warp(block.timestamp + extraDays);
        uint256 vestedAfter = vestingContract.calculateVestedAmount(Peter);

        assertGe(vestedAfter, vestedBefore);
    }

    function testFuzz_Claim_AtEnd_PaysFullAllocationAndEmptiesContract(
        uint256 allocation,
        uint256 duration,
        uint256 cliff
    ) external {
        duration = bound(duration, 1, 8 * 365 days); // 8 years
        cliff = bound(cliff, 0, duration);
        allocation = bound(allocation, 1, 1e30);

        vm.startPrank(Alice);
        mockERC20.mint(Alice, allocation);
        mockERC20.approve(address(vestingContract), allocation);
        vm.stopPrank();

        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, cliff, allocation, duration);
        (uint256 start,,,,,) = vestingContract.beneficiarySchedule(Peter);
        vm.warp(start + duration);
        vm.prank(Peter);
        vestingContract.claimVesting();

        assertEq(mockERC20.balanceOf(Peter), allocation);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 0);
    }

    function testFuzz_Revoke_Then_Claim_BalancesAddUpExactly(
        uint256 allocation,
        uint256 duration,
        uint256 cliff,
        uint256 revokeTime
    ) external {
        duration = bound(duration, 1, 8 * 365 days); // 8 years
        cliff = bound(cliff, 0, duration);
        revokeTime = bound(revokeTime, 0, (duration - 1));
        allocation = bound(allocation, 1, 1e30);

        vm.startPrank(Alice);
        mockERC20.mint(Alice, allocation);
        mockERC20.approve(address(vestingContract), allocation);
        vm.stopPrank();

        vm.prank(Alice);
        vestingContract.setVestingSchedule(Peter, cliff, allocation, duration);
        (uint256 start,,,,,) = vestingContract.beneficiarySchedule(Peter);
        vm.warp(start + revokeTime);
        vm.prank(Alice);
        vestingContract.revokeVesting(Peter);

        uint256 vested = vestingContract.calculateVestedAmount(Peter);
        if (vested > 0) {
            vm.prank(Peter);
            vestingContract.claimVesting();
        }
        assertEq(mockERC20.balanceOf(Alice) + mockERC20.balanceOf(Peter), ALLOCATION + allocation);
        assertEq(mockERC20.balanceOf(address(vestingContract)), 0);
    }
}
