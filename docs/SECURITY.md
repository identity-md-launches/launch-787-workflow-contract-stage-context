# Security and validation handoff

This is the implementer's review record, not an independent audit or admission decision. The later independent contributor must inspect accepted source and the concrete `launch.json`, including every constructor argument and linked protocol implementation. Service-managed policy/signature publication is separate from application correctness.

## Implemented protections and intentional powers

| Area | Implementation and evidence |
| --- | --- |
| Launch supply | Vendored OpenZeppelin ERC20; constructor-only mint of `10^27`; token tests include exact transfers, allowances and rejected admin selectors |
| Factory ownership | Explicit vault owner argument; no use of constructor `msg.sender` for application authority; factory deployment test preserves the full supply |
| Trading permissions | Keeper can only buy authenticated tokens or execute bounded ladder sales; all settings, withdrawals and emergency exits are owner-only |
| Custody | Owner may withdraw treasury assets except booked deferred reward ETH. Staking has no owner, rescue or upgrade path |
| Reentrancy | Shared OpenZeppelin ReentrancyGuard on every mutating application entry point that acts on funds/settings; native receive functions only authenticate receipts and may emit a deposit event |
| Purchases | Exact output ≤2% of supply, actual input ≤balance-based budget; actual balance changes independently checked; failed buys leave no marker or approval |
| Sales | Original-position tranches, snapshotted ladder, nonrepeatable advancement, actual output threshold, proportional cost basis, final remainder removal |
| Profit funding | Positive per-sale profit shared, maximum 50%; unavailable native conversion quotes reserve ETH without blocking exits. Anyone may retry; reserved ETH cannot fund buys/withdrawals. Attempted swaps/funding still revert atomically on failure |
| Approvals | Exact temporary venue/staking allowances, cleared on success; failure rolls back all changes |
| Rewards | UTC-day historical stake-seconds; claims independent of current stake; 7-day exclusive expiry boundary; bounded daily claim scan |
| Buyback isolation | Exact expired-batch liability only; measured newly purchased COMPANY sent to dead address; balance check preserves principal and donations |
| Arithmetic | Solidity checked arithmetic and OpenZeppelin full-precision mulDiv; integer truncation stays in the batch until buyback or explicit zero-output dust retirement; raw token units throughout |
| Failure liveness | Stake/unstake/claims need no market; owner withdrawals bypass pause; failed sales/burns remain retryable; individual token withdrawals avoid bulk-withdraw failure |
| Runtime | No proxy, arbitrary execution, delegatecall, callcode or selfdestruct in delivered application runtime; local bytecode walk checks PUSH immediates correctly |

The owner may set spending to 100%, slippage to 99.99%, profit share to zero, or stop the keeper. Those are material approved treasury powers, not mitigated by staking. Owner and keeper key security remain operational responsibilities. Ownership is immutable; losing the owner key cannot be repaired by a hidden recovery authority.

## Unresolved deployment findings and trust boundaries

1. **Live compatibility is not established.** Network configuration and actual canonical factory/router ABIs were absent. The supplied `ILaunchRegistry` and `ITradingVenue` ports are explicit requirements, not native ABI claims. Missing or incompatible live implementations require concrete adapter source and review; choosing a familiar-looking address is insufficient. Do not fund this system on the strength of the mocks.
2. **Registry authenticity is critical.** It must derive canonical origin and exact immutable pool identity from authenticated launch records. An arbitrary token registry or mutable owner-controlled pool mapping would break the intended origin restriction.
3. **Quote integrity is critical.** Positive values and a 15-minute freshness bound do not prove manipulation resistance. The venue must implement a reviewed oracle policy with actual observation timestamps and sized quotes. Spot quotes stamped with the current timestamp can be manipulated before this transaction; the output checks alone do not eliminate sandwiches/MEV. No secure live price mechanism for newly created pools has been established here. Freshly launched tokens may be untradeable until valid quotes exist.
4. **External implementations matter.** A malicious or upgraded venue can choose unfair prices within authorization caps. A malicious registry can authenticate an unsafe token. A rebasing, taxed, blocklisted, paused or upgradeable underlying token may revert or violate the intended plain-token assumptions. The application detects nonexact incoming funding/purchases and exact swap input/output deltas; this is not blanket support for exotic tokens. Review dependency administration/code identities in the final manifest.
5. **Liquidity can delay settlement; dust has an explicit closure policy.** Stale/reverting quotes and swap failures leave an expired batch retryable. A fresh zero-output route closes the batch with its IMD retained permanently as `totalImdDust`, outside reward liabilities and burn totals. No administrator can sweep it. The venue must distinguish sub-unit rounding from missing pricing; a false zero quote can cause premature retirement. ETH-paired burns use pre-swap reference quotes and one final 10% tolerance; this corrects the former 19% compounded tolerance, but remains dependent on reference-price integrity and permits bounded MEV loss.
6. **Unaccounted donations are deliberately not recoverable from staking.** Only `stake` and `notifyReward` create liabilities. Direct ERC-20 transfers and forced ETH can remain permanently. Owner withdrawals only exist in the treasury.
7. **L2 timing and operations affect user experience.** Timestamps determine batch boundaries, not L2 block numbers. Reorgs, censorship/downtime, late transactions and an inactive keeper can delay trades/claims. Seven-day expiry cannot be extended by the owner. The keeper/burn caller receives no on-chain gas reimbursement.
8. **Approved economic powers remain material.** The owner can zero the live profit share before a sale or withdraw unsold inventory without rewards. The keeper's cap is per buy, not per day: repeated different launches can consume most available treasury funds. Whole-day stake weighting permits large deposits after funding to dilute earlier stakers. These reproduced observations match the approved release; no minimum share, aggregate spending cap or funding-time snapshot was added.
9. **Deferred native shares carry timing and price risk.** Quote failure leaves an ETH-denominated reserve, with the eventual IMD quantity and eligible staking day determined on retry. Operators must retry; dust may remain indefinitely. New buys and owner withdrawals exclude the reserve, including after the position is closed. A valid quote followed by a swap execution or funding failure still reverts the sale; this targeted repair does not bypass executable slippage or transfer checks.
10. **Bulk withdrawals grow with historical token count.** `withdrawAll` can exceed block gas limits or fail on a broken token. `withdraw(asset, amount)` provides a bounded independent exit for each functioning asset.

## Tests and measured artifacts

The delivered suite has **84 tests**, including six fuzz tests at **256 cases each**:

| Suite | Tests | Main evidence |
| --- | ---: | --- |
| `LaunchTokenTest` | 5 | Policy supply, metadata, transfers/allowances, invalid actions, no mint/admin selectors |
| `SniperVaultTest` | 26 | Both assets, purchase caps, duplicate/origin rejection, all five levels, losses, profit routing, auth matrix, paused exits, failing/under-delivering swaps, reentrancy |
| `CompanyStakingTest` | 23 | Time weighting, late entry, same-timestamp changes, seven-day claims, exact expiry boundary, zero-staker/dust burn, multi-hop failure, principal preservation, delayed exits, claim/token callbacks |
| `StakeHistoryModelTest` | 1 fuzz | Randomized multi-day deposits/withdrawals compared to a separate interval-summing model, rather than the implementation's binary-search checkpoints |
| `DeploymentTest` | 3 | Factory CREATE2 deployment order, supply preservation, explicit owner, nonpayable constructors, invalid parameters, runtime/opcode bounds |
| `WithdrawalSafetyTest` | 4 | Reentrant/rejecting owner receiver, transfer failure rollback, unexpected native sender and empty funding |
| `DeferredRewardsTest` | 11 | Stale/future/zero/reverting quote deferral, both exits, protected ETH reserves, later-day funding, multiple positions, retry rollback and reentrancy |
| `BurnRevisionTest` | 8 | Both dust routes, zero second hop, stale dust rejection, accounting isolation, single-hop tolerance and fuzzed end-to-end two-hop bound |
| `ApprovedEconomicsTest` | 3 | Reproductions of approved full-day reward sharing, owner discretion and per-purchase keeper budgets |

Successful local commands:

```sh
forge build
forge test --summary
forge fmt --check
python3 tools/export_abi.py --check
sha256sum -c docs/dependency-sha256.txt
```

The full 84-test suite also passed with an empty process environment, offline resolution,
four worker threads and a fixed fuzz seed (`env -i <installed-forge> test --offline -j 4 --fuzz-seed 1234 --summary`).
No custom environment values, network RPC or dependency download was available to that run.

Compiler: Solidity 0.8.26, Paris, optimizer 200, no metadata hash. Measured runtime sizes: LaunchToken **1,784 bytes**, CompanyStaking **9,499 bytes**, SniperVault **13,764 bytes**; all below 24,576 bytes. Test code is not a deployment artifact. Compiler ABI arrays are exported for all three contracts and both integration interfaces.

Foundry's default build lint emits heuristic warnings. Relevant dispositions: exact equality on token balance deltas is intentional rejection of unsupported transfer behavior; timestamp comparisons implement documented expiry/freshness; `_send`'s recipient is the immutable owner in its only application call site; keeper zero is intentional revocation; bounded loops cover five ladder entries or seven claim days, while the unbounded historical-token withdrawal loop has the individual fallback above; reentrancy/event/balance warnings occur around external calls guarded by the shared lock and covered by adversarial callbacks. `onlyOwner` is a pure immutable-address check before the lock on admin calls; it makes no external call. Solidity initializes declared numeric locals to zero. These observations do not substitute for independent review.

No Slither, Mythril, live fork, live oracle evaluation or independent audit was performed. The pinned protected tests use verifier-owned environment data; they were read as the acceptance floor, not modified or imported into environment-independent local tests. `DeploymentTest` separately exercises the same relevant runtime/supply properties without those external inputs. Local green tests carry no independent admission authority.
