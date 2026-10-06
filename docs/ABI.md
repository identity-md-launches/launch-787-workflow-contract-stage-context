# ABI and frontend integration

`docs/abi/LaunchToken.json`, `CompanyStaking.json` and `SniperVault.json` are plain compiler ABI arrays including functions, errors, constructors and events. `ILaunchRegistry.json` and `ITradingVenue.json` document the required external integration ports. Generate from `out/` using `python3 tools/export_abi.py`; `--check` fails if a file is absent or differs from the compiler output. ABIs do not contain network addresses.

## COMPANY

Standard ERC-20 functions: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, `transferFrom`; standard `Transfer` and `Approval` events. Transfers are exact and uncharged. Sending tokens to the dead address does not call an ERC-20 burn function or reduce supply.

## Vault calls

| Caller | Function | Behavior |
| --- | --- | --- |
| OWNER | `depositIMD(uint256)` | Pull IMD after approval; rejects zero/transfer fees |
| OWNER | `depositETH()` | Payable deposit; rejects zero |
| OWNER | `withdraw(address,uint256)` | Transfer specified asset to immutable owner; zero address means ETH |
| OWNER | `withdrawAll()` | Transfer ETH, IMD, and all known bought-token balances to owner |
| OWNER | `pause()`, `unpause()` | Change new-buy permission only |
| OWNER | `setKeeper(address)` | Replace keeper; zero disables it |
| OWNER | `setMaxSpendBps(uint256)` | 1–10000, default 100 |
| OWNER | `setSlippageBps(uint256)` | 0–9999, default 1000 |
| OWNER | `setStakerShareBps(uint256)` | 0–5000, default 3000; applies at sale time |
| OWNER | `setLadder(uint32[5],uint16[5])` | Increasing multiples >1; positive fractions sum to 10000; future buys only |
| OWNER | `emergencySell(address)` | Liquidate remaining tracked position at bounded quoted price; distribute positive profit |
| KEEPER | `snipe(address)` | One constrained purchase of an authenticated launch |
| KEEPER or OWNER | `sell(address)` | Execute next eligible nonzero tranche |

`positionOf(token)` returns a tuple:

| Field | Meaning |
| --- | --- |
| `asset`, `poolId` | Funding currency and fixed launch pool identity |
| `originalAmount`, `remainingAmount` | Original purchase and still-recorded inventory, in token minor units |
| `entryCost`, `remainingCost` | Actual purchase cost and unretired cost basis, in asset minor units |
| `entryPrice` | `entryCost * 10^18 / originalAmount`; display ratio, not the settlement oracle |
| `proceeds` | Cumulative gross realized sale proceeds in original asset, after venue trading fees |
| `rewardsImd` | Cumulative IMD actually delivered to staking by this position |
| `nextLevel` | Next unexecuted ladder index 0–4, or 5 after final/emergency exit |
| `multiples`, `sellBps` | Snapshot of the five ladder levels and original-position fractions |

An unbought token has `originalAmount == 0`; a closed/withdrawn position has `remainingAmount == 0`. Owner withdrawal can close inventory without advancing `nextLevel`, so UI status must check inventory first. `snipedTokenCount()` and `snipedTokens(index)` enumerate historic buys. There is intentionally no user-supplied recipient or arbitrary swap calldata.

`Sniped` records token, original asset, amount, cost and entry-price ratio. `Sold` records original asset, index, sold amount, proceeds, allocated cost, nonnegative profit, IMD rewards and emergency flag (level 5 for emergency). `Deposited`, `Withdrawn`, `KeeperChanged`, `PauseChanged`, `MaxSpendChanged`, `SlippageChanged`, `StakerShareChanged` and `LadderChanged` support treasury/admin history.

Build P&L and win-rate metrics from confirmed events, including cost retired by withdrawals; do not count owner withdrawals as trading losses or deposits as profits. Keep ETH and IMD amounts separate until independently priced in a common currency. Current vault value and USD conversions need off-chain pricing; the contracts do not promise a USD valuation or a particular win-rate definition.

## Staking calls

| Function | Behavior |
| --- | --- |
| `stake(uint256)` | Pull COMPANY from caller after approval; credit stake-seconds from now |
| `unstake(uint256)` | Return caller's COMPANY immediately; preserve prior reward rights |
| `notifyReward(uint256)` | Pull caller's IMD into current UTC-day batch after approval |
| `claimAll()` | Transfer caller's share from up to seven completed unexpired days; returns IMD amount (possibly zero) |
| `claim(uint256 batchId)` | Claim a specific completed, unexpired, not-previously-claimed batch |
| `burnExpired(uint256 batchId)` | Anyone can exchange only that expired batch's remaining reward into dead-address COMPANY |
| `batchWindow(uint256)` | Return daily close and exclusive expiry timestamps |
| `stakeSeconds(address,uint256)` | Return user and aggregate stake-seconds for a completed day; zero for current/future/predeployment days |
| `claimable(address,uint256)` | Current IMD claim amount; zero outside eligibility or after claim |
| `batches(uint256)` | Return `funded`, `claimed`, `burned`; remaining equals funded minus claimed until burned |
| `claimed(uint256,address)` | Whether this account processed that batch; zero-value claims may mark it too |

Additional getters: `company`, `imd`, `balanceOf(account)`, `totalStaked`, `firstBatch`, `rewardLiability`, `totalRewardsFunded`, `totalRewardsPaid`, `totalImdBurned`, `totalCompanyBurned`, `DEAD`, and shared immutable integration getters. `totalImdBurned` is IMD spent buying COMPANY, not IMD sent to a burn address. The accounting identity is `totalRewardsFunded = totalRewardsPaid + totalImdBurned + rewardLiability`.

Index `Staked`, `Unstaked`, `RewardsFunded(batchId,funder,amount)`, `RewardClaimed(batchId,account,amount)` and `ExpiredBurned(batchId,imdSpent,companySentToDead)`. Identify batches by UTC day number, not event sequence number. Multiple funding events share one batch. There is no global unbounded on-chain batch enumeration: enumerate funded IDs from events, and filter by `batchWindow`/`batches`.

Countdowns should show that a current batch is still accumulating, then seven days from its daily close. Claims are unavailable at the expiry timestamp. A claim transaction submitted before expiry can still execute after it; use a margin in the UI. Matured claims require no price/router call; burns do.

## Errors and amounts

Use ABI custom errors to distinguish authorization, paused buys, duplicate buys, target-not-reached, invalid origin, stale/invalid quotes, transfer accounting failures and batch windows. Router/token errors may also bubble. A failed sale/burn is fully retryable; it does not advance the ladder or consume a batch. Token amounts are always raw minor units. Format each asset with its own verified decimals. Avoid JavaScript floating-point numbers for integer amounts, timestamps, prices and basis points.
