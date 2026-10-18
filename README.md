# Timelocked Vesting Contract

[![CI](https://github.com/Nuelverse/Vesting-Contract/actions/workflows/test.yml/badge.svg)](https://github.com/Nuelverse/Vesting-Contract/actions/workflows/test.yml)

A Solidity contract that locks ERC20 tokens for beneficiaries and releases them linearly over time, with an optional cliff. Built with Foundry for learning purpose.

> **Status:** learning-grade implementation, not audited. 39 tests (including 4 fuzz tests) pass, with 100% line, branch and function coverage of the contract (see [Testing](#testing)). Deployed and verified on Sepolia (see [Deployments](#deployments)).

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
- Tokens sent to the contract directly (not through `setVestingSchedule`) can never be recovered, since there is no sweep function.
- Not audited.

## Running it

Requirements: [Foundry](https://book.getfoundry.sh/).

```bash
git clone https://github.com/Nuelverse/Vesting-Contract.git
cd Vesting-Contract
forge install
forge build
forge test
```

Remappings are set in `foundry.toml` for `@openzeppelin/contracts/` and `forge-std/`.

## Testing

```bash
forge test                                            # all tests
forge test --mt testFuzz -vv                          # only the fuzz tests
forge coverage --no-match-coverage "script|test"      # coverage of src/ only
```

39 tests, all in `test/VestingTest.t.sol`, grouped by function. Time-based behaviour is tested with `vm.warp`. The tests deploy through the real deploy script (`DeployVesting`), so the deployment path is tested too. A small `MockERC20` (in `test/mocks/`) plays the token.

**Who is who in the tests:** the account that runs the deploy script becomes the owner. Inside tests that is forge's `DEFAULT_SENDER`, which the tests call `Alice`. `Peter` is the beneficiary and `Stranger` is a non-owner.

| Area                 | What is covered                                                                                                                                                                                                                                                                                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Vesting curve        | zero right after creation, one second before the cliff, exactly at the cliff, halfway, exactly at the end, long after the end                                                                                                                                                                                                                                                       |
| `setVestingSchedule` | tokens pulled from the owner, schedule stored, event emitted, and reverts for non-owner, duplicate schedule, zero address, zero allocation, zero duration, cliff longer than duration, and missing approval                                                                                                                                                                         |
| `claimVesting`       | pays half at the halfway point, reverts during the cliff, a second claim in a row reverts, a later claim pays only the newly vested part, the claim event carries the right beneficiary and amount, reverts with no schedule                                                                                                                                                        |
| `revokeVesting`      | unvested part returns to the owner, beneficiary can still claim what was earned, vesting stays frozen after the revoke, whole allocation returned during the cliff, owner + beneficiary balances equal the deposit (also after an earlier claim), the revoke event carries the right beneficiary and refund, and reverts for non-owner, double revoke, fully vested and no schedule |
| Constructor          | reverts on a zero token address                                                                                                                                                                                                                                                                                                                                                     |

**Fuzz tests** (256 runs each by default):

- For any moment between creation and 2,000 days later, vested never exceeds the allocation.
- For any two moments in order, vested never decreases.
- For any allocation (1 to 1e30), duration (1 second to 8 years) and cliff (0 up to the duration), claiming at the end pays the beneficiary exactly the allocation and leaves 0 in the contract. At the end the contract returns the full allocation without dividing, so this checks the end-of-schedule accounting (nothing missing, nothing stuck), not rounding in the middle of a schedule.
- For any schedule and any revoke moment (including inside the cliff), after the owner revokes and the beneficiary claims what has vested, the owner's and beneficiary's balances add up to exactly what was deposited and the contract holds 0. Because the refund is `total - vested` from the same vested number, rounding can shift a fraction of a token between the two sides but can never create or destroy tokens.

**Coverage of `src/VestingContract.sol`:** 100% of lines, statements, branches and functions.

## Deploying

The deploy script (`script/DeployVesting.s.sol`) asks `HelperConfig` which token to use for the current chain, then deploys `VestingContract` with it. **The account that signs the deployment becomes the owner.**

| Chain                 | Token used                                          |
| --------------------- | --------------------------------------------------- |
| Anvil / local (31337) | a `MockERC20` the script deploys                    |
| Sepolia (11155111)    | a `MockERC20` the script deploys                    |
| Any other chain       | the script reverts, so it cannot deploy by accident |

**_On Sepolia the script deploys its own mock token (MockERC20) with an unrestricted mint, for demo purposes only._**

**Locally with anvil:**

```bash
anvil                                    # terminal 1
forge script script/DeployVesting.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <one of the keys anvil prints>
```

Anvil's keys are public test keys with no real value. Never use them anywhere else.

**On a testnet:** import the deployer key into an encrypted keystore once, so the key never appears in a file or in your shell history. Use a throwaway wallet with test ETH only.

```bash
cast wallet import sepolia-deployer --interactive   # asks for the key and a password, stores it encrypted
forge script script/DeployVesting.s.sol:DeployVesting --rpc-url $SEPOLIA_RPC_URL --account sepolia-deployer \
  --broadcast --gas-estimate-multiplier 900 --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

`SEPOLIA_RPC_URL` and `ETHERSCAN_API_KEY` come from a `.env` file that is ignored by git.

**After deploying:** the owner mints some mock tokens to themselves, approves the vesting contract for the allocation, and then calls `setVestingSchedule`.

## Deployments

Deployed on 2026-10-18 to **Sepolia** (chain id 11155111), with source code verified on Etherscan.

| Contract                                      | Address                                                                                                                         |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `VestingContract`                             | [`0xe4a43a0F08D5CC7eF08509CA9De0961B35F770Dc`](https://sepolia.etherscan.io/address/0xe4a43a0F08D5CC7eF08509CA9De0961B35F770Dc) |
| `MockERC20` (demo token, unrestricted `mint`) | [`0x7b506918DCb537bE0A6E464B3A6841077fe3dAfF`](https://sepolia.etherscan.io/address/0x7b506918DCb537bE0A6E464B3A6841077fe3dAfF) |

The token is a mock for demonstration only: anyone can mint it.
