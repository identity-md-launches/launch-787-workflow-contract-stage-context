# Zero Person Billion Dollar Company (COMPANY)

Implemented contract contribution for the approved IdentityMD project launch: `LaunchToken`, `CompanyStaking`, and `SniperVault`. This repository contains source, vendored dependencies, deterministic Foundry tests, ABI exports, and integration documentation. The separate manifest contributor owns `launch.json`; independent review and services own admission, publication, deployment and the later IPFS frontend.

**Live integration remains unverified.** No Robinhood network configuration, IMD factory ABI, router ABI, pool identity, or oracle deployment was provided. The applications use immutable, explicit integration interfaces; no live address has been guessed. The required registry and trading adapter contracts must exist, conform to those interfaces, and undergo independent review before these applications can trade. `test/mocks/` only demonstrates local behavior. See [deployment and integration requirements](docs/DEPLOYMENT.md).

## Build and checks

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abi.py --check
```

`foundry.toml` pins Solidity **0.8.26**, optimizer runs **200**, EVM **Paris**, and `bytecode_hash = "none"`. No FFI, filesystem cheatcode permission or network is needed for tests. All dependencies are ordinary vendored source files; there are no submodules, installer hooks, external test RPCs, keys or environment-dependent tests. Foundry and the pinned compiler must already be installed by the verifier. To regenerate the ABIs after a source change, build and run `python3 tools/export_abi.py`.

## Token and treasury

`LaunchToken` is a standard ERC-20 named **Zero Person Billion Dollar Company**, symbol **COMPANY**, with 18 decimals and exactly **1,000,000,000 tokens** (`10^27` minor units), all minted to its deployer. It has no post-construction mint, ownership, pause, blocklist, fee or upgrade mechanism. Neither application constructor moves launch supply. The factory performs the policy distribution and liquidity creation; the applications do not distribute the launch supply or implement pool fees.

`SniperVault` is an **owner-custodied treasury**. The approved owner is `0x40699CF5C05b0DA76ab1f2C9308A5c0AaFA916Df`, supplied by policy as the explicit constructor argument, not inferred from the deploying factory. The owner can withdraw all vault ETH, IMD and purchased tokens, including while paused. Stakers have no redemption claim on vault assets. The owner can choose/revoke the keeper, change spend/slippage/profit-share settings, change the ladder for future positions, pause new buys, and liquidate recorded positions. Ownership itself is immutable.

The keeper starts disabled (`address(0)`). Only the registered keeper can `snipe(token)`; keeper or owner can `sell(token)`. The keeper cannot withdraw, set parameters, nominate a recipient, choose a route, execute arbitrary calldata, or reimburse its own gas. Trading necessarily sends the specified input to the fixed venue; output always returns to the vault, with only the calculated profit share sent to the fixed staking contract. The owner funds keeper gas separately.

Purchases require proven canonical-factory origin on the configured chain and an IMD or native ETH pair. Each token can be bought **once for the lifetime of the vault**, including after an exit or owner withdrawal. The position receives at most **2%** of the token's supply. Its maximum input is at most `maxSpendBps` of the funding-asset balance immediately before that purchase, default **100 bps (1%)**. Multiple different launches each use the then-current balance; this is not a daily or aggregate spending limit.

Buys use exact output to enforce the supply cap and measure actual input after native refunds. The default slippage allowance is **1000 bps (10%)**. The owner may set spend from 1–10000 bps and slippage from 0–9999 bps. Quotes must be positive, timestamped, not in the future, and no more than 15 minutes old. This freshness check cannot prove oracle integrity: the venue's price source is a critical deployment trust assumption. A new launch without a valid quote cannot yet be sniped.

Every position records purchase amount, actual cost, funding asset, exact pool identity, entry price and its ladder snapshot. The entry-price field is `cost * 1e18 / amount` in **minor-unit ratios** for display; accounting uses the original amounts and cost directly, without assuming token decimals. To display asset-per-whole-token price, multiply the unscaled ratio by `10^tokenDecimals / 10^assetDecimals`.

## Sales and profit

The default ladder sells 20% of the **original** amount at 5×, 10×, 25× and 50× entry price, then all remaining recorded tokens at 100×. Each successful `sell` executes one next nonzero tranche. If price jumps across levels, call repeatedly. A tranche cannot repeat and a failed transaction does not consume it. Whole-unit rounding can make early tranches zero; those are skipped. The last tranche clears rounding residue. A custom ladder has five strictly increasing integer multiples above 1 and five positive fractions totaling 10000 bps; it applies only to future purchases.

Both the executable quote and actual minimum output must meet the ladder threshold, after venue fees/price impact. The threshold conservatively rounds tranche cost upward before applying the multiple, so a tiny rounding buffer above an exact displayed multiple can be needed. `emergencySell` is owner-only, bypasses the ladder threshold, retains the quote/slippage checks, and liquidates the remaining recorded position. Pause blocks only new purchases.

For each sale, profit is `max(actual proceeds - allocated remaining cost basis, 0)`. The default staking share is **3000 bps (30%)** of that profit, adjustable by the owner from 0–5000 bps. IMD profits fund staking directly; the ETH share is converted through the fixed ETH/IMD pool first. Gas costs and earlier losses on other sales are not netted against an individual sale's profit. Input/output transfers, conversion, accounting and reward funding are atomic: any failure rolls the whole sale back. Approvals are exact per operation and reset to zero.

Owner withdrawals of recorded position tokens retire matching inventory and a proportional cost basis; they do not earn rewards. Withdrawing first retires recorded inventory even if the same token was also donated. Unsolicited tokens beyond the recorded position are not automatically sold. `withdraw(asset, amount)` can retrieve them. `withdrawAll()` walks all ever-sniped tokens as well as ETH and IMD; a very long list or a broken token can make it fail, so individual withdrawals remain available.

## Daily staking rewards

Anyone may stake or unstake COMPANY at any time, including during vault pauses, market outages, or after reward expiry. Staking has **no owner or administrator**, no pause, no upgrade, and no rescue function. The vault owner cannot access stakes or rewards.

Batch `d = floor(block.timestamp / 86400)` covers `[d * 86400, (d + 1) * 86400)` in UTC. `notifyReward(amount)` pulls IMD into the current day only; multiple sales combine into that batch. Funding is permissionless and transfers must be exact, so anyone can also donate through this function. This avoids a privileged reward injector and a circular initialization dependency between staking and the vault. Funding earlier closed batches is impossible.

For a completed day, each account earns:

```text
floor(batch IMD * account's COMPANY-seconds during that day / total COMPANY-seconds during that day)
```

The entire day's stake-seconds determine the split, irrespective of the time a sale funded that day. Same-timestamp stake-and-unstake adds no weight. An exit preserves historical earnings; a late entrant receives only its actual stake duration. History uses cumulative checkpoints and binary search. Stake/unstake never iterate over missed days, and `claimAll()` examines at most seven completed daily batches even after years of inactivity.

A batch becomes claimable when its day ends. Claims are valid for the next **seven complete days**, up to but excluding `day end + 7 days`. `claimAll()` pays all eligible unclaimed amounts to the caller. There is also `claim(batchId)`. At the exact expiry timestamp claims are closed and anyone may `burnExpired(batchId)`.

Expiry spends **only that batch's unclaimed IMD**, including integer rounding dust. The fixed venue buys COMPANY from its registered launch pool, using IMD directly for an IMD pair or IMD→ETH→COMPANY for an ETH pair. Newly purchased COMPANY is transferred to `0x000000000000000000000000000000000000dEaD`; ERC-20 `totalSupply` is unchanged. Staked COMPANY and other batches' IMD remain untouched. A batch with no eligible stake expires in full. A fully claimed batch closes without any swap.

Buybacks have a fixed 10% slippage allowance on **each** hop. Failed or stale quotes, missing liquidity, or output too small to represent one token minor unit leave the batch intact and retryable. No caller can redirect the money or clear an unpaid liability. There is no automatic scheduler or caller bounty; an operator or any user must submit the transaction. Direct transfers of IMD outside `notifyReward` are not accounted rewards, and unsolicited COMPANY is not a stake: such donations (and forced ETH) have no recovery mechanism in staking.

## Responsibilities and review

See [the ABI guide](docs/ABI.md), [deployment parameters and integration contract](docs/DEPLOYMENT.md), and [security review notes](docs/SECURITY.md). The frontend should use the exact deployed addresses and pool key supplied by services, index emitted events, and display reward expiry from contract timestamps. USD valuation and keeper scheduling are off-chain responsibilities; there is no on-chain USD oracle or browser wallet in this contribution.

The local suite covers successes, failures, access control, reentrancy, balance conservation, delayed claims, expiry, failed multi-hop settlement, constructor behavior and forbidden runtime opcodes. These checks are not an independent security audit or proof of compatibility with a live network. Independent review of these contracts and the concrete manifest, including privileged arguments and integration implementations, remains required before funds are entrusted to them.
