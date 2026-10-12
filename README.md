# Timelocked Vesting Contract

A Solidity contract that locks ERC20 tokens for beneficiaries and releases them linearly over time, with an optional cliff. Built with Foundry for learning purpose.

> **Status:** learning-grade implementation, not audited. Contract is written; the test suite is in progress (see [Testing](#testing)).

## What it does

- The **owner** creates a vesting schedule for a beneficiary and deposits the tokens in the same transaction.
- Tokens unlock **linearly** from the moment the schedule is created, after an optional **cliff**.
- The **beneficiary** can claim whatever has vested so far, whenever they like.
- The owner can **revoke** a schedule and take back only the **unvested** part. What the beneficiary has already earned stays theirs.

## How it works

Three terms:

| Term          | Meaning                                                             |
| ------------- | ------------------------------------------------------------------- |
| **Vested**    | Total unlocked so far. Only ever grows (until a revoke freezes it). |
| **Claimed**   | Already withdrawn by the beneficiary.                               |
| **Claimable** | `vested - claimed`                                                  |

Vested at time `t`, with `elapsed = t - start`:

| When                                              | Vested                                      |
| ------------------------------------------------- | ------------------------------------------- |
| Before the cliff ends (`t < start + cliff`)       | `0`                                         |
| Between the cliff end and the end of the schedule | `totalAllocation * elapsed / totalDuration` |
| At or after the end (`elapsed >= totalDuration`)  | `totalAllocation`                           |

### Example: Peter

Alice vests **1,200 tokens** for Peter over **12 months**, with a **3-month cliff**.

| Date                   | Vested | Already claimed | Claimable            |
| ---------------------- | ------ | --------------- | -------------------- |
| Month 1 (in the cliff) | 0      | 0               | 0                    |
| Month 3 (cliff ends)   | 300    | 0               | 300, Peter claims it |
| Month 6                | 600    | 300             | 300                  |
| Month 12 and later     | 1,200  | 600             | 600                  |

**Revoke at month 6:** vesting freezes at 600. Alice receives the 600 that never vested. Peter has claimed 300 and can still claim the other 300 he earned. 600 + 600 = 1,200: nothing is lost or created.

## Functions

| Function                                                                    | Who can call  | What it does                                                                             |
| --------------------------------------------------------------------------- | ------------- | ---------------------------------------------------------------------------------------- |
| `setVestingSchedule(beneficiary, cliffDuration, allocation, totalDuration)` | Owner         | Creates the schedule (starting now) and pulls `allocation` tokens from the owner.        |
| `claimVesting()`                                                            | Beneficiary   | Sends the caller everything vested and not yet claimed.                                  |
| `revokeVesting(beneficiary)`                                                | Owner         | Freezes vesting and returns the unvested tokens to the owner.                            |
| `calculateVestedAmount(beneficiary)`                                        | Anyone (view) | Returns the vested amount (claimed included) at the current time, or at the revoke time. |

The owner must `approve` the contract for the allocation on the token before calling `setVestingSchedule`.

## Design decisions

**One schedule per beneficiary address (`mapping(address => VestingSchedule)`).**
_Why:_ it keeps lookups and access control simple: `msg.sender` identifies the schedule.
_Tradeoff:_ a beneficiary cannot have two schedules, and a finished schedule cannot be replaced. A production version would key schedules by an ID.

**Vesting starts at `block.timestamp` of creation; the start time is not an argument.**
_Why:_ it removes a whole class of mistakes, such as a start date in the past that vests tokens instantly.
_Tradeoff:_ the owner cannot schedule a future start.

**A schedule "exists" when `totalDuration != 0`.**
_Why:_ a mapping has no "missing" state, and creation rejects a zero duration, so a real schedule can never have it. It is also the divisor, so a division by zero is impossible.

**Revoke freezes vesting at `revokedTime` and never touches vested tokens.**
_Why:_ the beneficiary keeps what was earned, and the owner only recovers `totalAllocation - vested`. After a revoke the contract still holds exactly what the beneficiary can claim.

**Revoking during the cliff returns the whole allocation.**
_Why:_ nothing has vested yet, so nothing was earned. This is the standard meaning of a cliff.
_Tradeoff:_ see [trust model](#trust-model).

**`claimVesting` reverts with `NothingToClaim` when the claimable amount is zero.**
_Why:_ an explicit failure is clearer than a silent success that moves nothing, and it avoids pointless zero-value transfers and misleading events.

**Standard patterns:** custom errors instead of revert strings, OpenZeppelin `SafeERC20` for all transfers, checks-effects-interactions order, events for every state change, NatSpec on all external functions.

## Security considerations

Who can call what:

| Action                    | Allowed                                                                                  |
| ------------------------- | ---------------------------------------------------------------------------------------- |
| Create a schedule, revoke | Owner only                                                                               |
| Claim                     | Only the beneficiary, for their own schedule. Nobody can claim on someone else's behalf. |
| Read vested amount        | Anyone                                                                                   |

Boundaries considered:

- **Zero values:** zero address, zero allocation and zero duration are rejected on creation.
- **Cliff longer than duration:** rejected.
- **Exactly at the cliff:** vested jumps to the linear value for that moment (comparison is strictly `<`).
- **Exactly at the end:** returns the full allocation, not one less.
- **Start in the future / before the cliff:** returns 0 without any subtraction that could underflow.
- **Claim twice in a row:** the second claim only pays what vested since the first (`amountClaimed` is updated before the transfer goes out).
- **Revoke twice / revoke when fully vested:** both revert.

## Known limitations

### Trust model

The owner can revoke at any time, including one second before the cliff ends, and the beneficiary has no recourse on-chain. Tokens that have already vested can never be taken back. A production design would add a non-revocable option or an off-chain agreement.

### Other limitations

- Assumes a **standard ERC20**. Fee-on-transfer and rebasing tokens would make the contract owe more than it holds.
- **One schedule per beneficiary**, and a revoked or finished schedule can't be reset.
- **Single owner**, set at deployment, with no ownership transfer or two-step handover.
- Beneficiary address cannot be changed (a lost key means locked tokens).
- Not audited.

## Running it

Requirements: [Foundry](https://book.getfoundry.sh/).

```bash
git clone <this repo>
cd Vesting-Contract
git submodule update --init --recursive   # forge-std and OpenZeppelin
forge build
forge test
forge coverage
```

Remappings are set in `foundry.toml` for `@openzeppelin/contracts/` and `forge-std/`.

## Testing

The test suite is being written. The plan:

- **Happy path:** create, claim at the cliff, halfway and at the end.
- **Time boundaries (`vm.warp`):** before the cliff, exactly at the cliff, exactly at the end, long after the end.
- **Revert cases:** non-owner revoke, duplicate schedule, zero values, nothing to claim, no schedule, double revoke.
- **Accounting:** after a revoke, owner balance + beneficiary balance equals the original deposit.
- **Fuzz:** for any timestamp, `claimed <= vested <= totalAllocation`, and the contract never pays out more than the deposit.
