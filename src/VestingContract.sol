// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VestingContract
 * @notice Holds ERC20 tokens for beneficiaries and releases them linearly over time, with an optional cliff.
 * @dev One schedule per beneficiary address. Vested = totalAllocation * elapsed / totalDuration, which is 0
 * before the cliff ends and capped at totalAllocation once the duration has passed.
 * Assumes a standard ERC20 (no fee-on-transfer or rebasing). Learning-grade code, not audited.
 */

contract VestingContract {
    using SafeERC20 for IERC20;

    /// @dev The ERC20 token being vested. Set once in the constructor.
    IERC20 public immutable i_token;

    /// @dev The only address allowed to create and revoke schedules. Set once in the constructor.
    address public immutable i_owner;

    /// @notice The vesting schedule of each beneficiary. An unset entry has its values defaulted to 0.
    mapping(address => VestingSchedule) public beneficiarySchedule;

    error NotOwner();
    error AddressZero();
    error NoSchedule();
    error ZeroAllocation();
    error NothingToClaim();
    /// @notice The total vesting duration must be greater than zero.
    error ZeroDuration();
    error CliffLongerThanDuration();
    error ScheduleAlreadyExists();
    error ScheduleAlreadyRevoked();
    error NothingToRevoke();

    /// @notice Emitted when the owner creates a schedule and deposits its tokens.
    /// @param beneficiary The address that will receive the vested tokens.
    /// @param allocation The total tokens deposited for this schedule.
    /// @param cliffDuration Seconds after the start during which nothing vests.
    /// @param totalDuration Seconds from the start until everything is vested.
    event VestingScheduled(
        address indexed beneficiary, uint256 allocation, uint256 cliffDuration, uint256 totalDuration
    );

    /// @notice Emitted when a beneficiary claims vested tokens.
    /// @param beneficiary The address that claimed.
    /// @param amount The tokens sent in this claim.
    event VestingClaimed(address indexed beneficiary, uint256 amount);

    /// @notice Emitted when the owner revokes a schedule and reclaims the unvested tokens.
    /// @param beneficiary The address whose schedule was revoked.
    /// @param amountRevoked The unvested tokens returned to the owner.
    event VestingRevoked(address indexed beneficiary, uint256 amountRevoked);

    /// @notice The terms and progress of one beneficiary's vesting.
    /// @param vestingStartTime Timestamp the schedule was created (vesting starts here).
    /// @param cliffDuration Seconds after the start during which nothing vests.
    /// @param totalAllocation Total tokens promised. Never changes after creation.
    /// @param totalDuration Seconds from the start until everything is vested. Zero means "no schedule".
    /// @param amountClaimed Tokens already paid out to the beneficiary.
    /// @param revokedTime Timestamp of revocation, or 0 if not revoked. Vesting is frozen at this time.
    struct VestingSchedule {
        uint256 vestingStartTime;
        uint256 cliffDuration;
        uint256 totalAllocation;
        uint256 totalDuration;
        uint256 amountClaimed;
        uint256 revokedTime;
    }

    /// @param tokenAddress The ERC20 token that will be vested. The deployer becomes the owner.
    constructor(address tokenAddress) {
        if (tokenAddress == address(0)) {
            revert AddressZero();
        }
        i_token = IERC20(tokenAddress);
        i_owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != i_owner) {
            revert NotOwner();
        }
        _;
    }

    /**
     * @notice Creates a vesting schedule for a beneficiary and pulls the tokens in from the owner.
     * @dev Vesting starts at block.timestamp. The owner must first approve this contract for `_allocation`
     * on the token. Reverts if the beneficiary already has a schedule (even a revoked one).
     * @param beneficiary The address receiving the vested tokens.
     * @param _cliffDuration Seconds after the start during which nothing vests. Must be <= `_totalDuration`.
     * @param _allocation The total number of tokens to vest. Must be greater than zero.
     * @param _totalDuration The total vesting duration in seconds. Must be greater than zero.
     */
    function setVestingSchedule(
        address beneficiary,
        uint256 _cliffDuration,
        uint256 _allocation,
        uint256 _totalDuration
    ) external onlyOwner {
        if (beneficiarySchedule[beneficiary].totalDuration > 0) {
            revert ScheduleAlreadyExists();
        }
        if (beneficiary == address(0)) {
            revert AddressZero();
        }
        if (_totalDuration == 0) {
            revert ZeroDuration();
        }
        if (_cliffDuration > _totalDuration) {
            revert CliffLongerThanDuration();
        }
        if (_allocation == 0) {
            revert ZeroAllocation();
        }

        beneficiarySchedule[beneficiary] =
            VestingSchedule(block.timestamp, _cliffDuration, _allocation, _totalDuration, 0, 0);

        i_token.safeTransferFrom(msg.sender, address(this), _allocation);
        emit VestingScheduled(beneficiary, _allocation, _cliffDuration, _totalDuration);
    }

    /**
     * @notice Sends the caller all tokens that have vested but not yet been claimed.
     * @dev Claimable = vested - amountClaimed. Still works after a revoke, up to the amount vested at the
     * revoke time. Reverts with NothingToClaim if the claimable amount is zero.
     */
    function claimVesting() external {
        uint256 claimable = calculateVestedAmount(msg.sender) - beneficiarySchedule[msg.sender].amountClaimed;
        if (claimable == 0) {
            revert NothingToClaim();
        }
        beneficiarySchedule[msg.sender].amountClaimed += claimable;
        i_token.safeTransfer(msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    /**
     * @notice Stops a beneficiary's vesting and returns the unvested tokens to the owner.
     * @dev Freezes vesting at the current timestamp. Tokens already vested stay claimable by the beneficiary.
     * During the cliff nothing has vested, so the whole allocation is returned.
     * Reverts if everything has already vested, because there is nothing to take back.
     * @param beneficiary The address whose schedule is revoked.
     */
    function revokeVesting(address beneficiary) external onlyOwner {
        VestingSchedule storage vSchedule = beneficiarySchedule[beneficiary];
        if (vSchedule.totalDuration == 0) {
            revert NoSchedule();
        }
        if (vSchedule.revokedTime > 0) {
            revert ScheduleAlreadyRevoked();
        }

        uint256 revokableAmount = vSchedule.totalAllocation - calculateVestedAmount(beneficiary);
        if (revokableAmount == 0) {
            revert NothingToRevoke();
        }
        vSchedule.revokedTime = block.timestamp;
        i_token.safeTransfer(i_owner, revokableAmount);
        emit VestingRevoked(beneficiary, revokableAmount);
    }

    /**
     * @notice Returns how many tokens have vested for a beneficiary so far, including already claimed ones.
     * @dev Measured at block.timestamp, or at revokedTime if the schedule was revoked.
     * Returns 0 before the cliff ends, totalAllocation after the duration, and a linear share in between.
     * Multiplies before dividing to avoid losing precision. Reverts with NoSchedule if none exists.
     * @param beneficiary The address to check.
     * @return The vested amount in token units.
     */
    function calculateVestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory vSchedule = beneficiarySchedule[beneficiary];
        if (vSchedule.totalDuration == 0) {
            revert NoSchedule();
        }
        uint256 t;
        if (vSchedule.revokedTime == 0) {
            t = block.timestamp;
        } else {
            t = vSchedule.revokedTime;
        }
        // check if time is before the cliff end
        if (t < (vSchedule.vestingStartTime + vSchedule.cliffDuration)) {
            return 0;
        }
        uint256 elapsed = t - vSchedule.vestingStartTime;

        if (elapsed >= vSchedule.totalDuration) {
            return vSchedule.totalAllocation;
        } else {
            return (vSchedule.totalAllocation * elapsed) / vSchedule.totalDuration;
        }
    }
}
