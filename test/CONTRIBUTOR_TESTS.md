# Added test coverage

These tests extend the accepted implementation without changing source, configuration,
dependencies, ABIs, or deployment artifacts. Run them with the existing `forge build`
and `forge test` commands. All dependencies were already vendored in the repository.

| Suite | Independent checks |
| --- | --- |
| `CompanyStakingInvariant.t.sol` | Three actors; stake/unstake, funding, elapsed time, claims, expiry burns, dust retirement, stale quotes, donations, and repeated immediate round trips. A calendar-day interval model checks stake-seconds and reward entitlements independently of contract checkpoints. Actual balances back every principal, reward obligation, and retained dust amount. |
| `SniperVaultInvariant.t.sol` | Owner, keeper, and outsider; both funding currencies, bounded new launches, changing spend/slippage/share/pause/keeper settings, sales, partial/full withdrawals, donations, and attempted repeat purchases. Deferred ETH reserves, fresh/stale/sub-unit conversion quotes, and successful/failed permissionless retries join the random sequences. Separate cash and token flow records check conservation, profit sharing, reserve backing, closed positions, keeper isolation, and cleared approvals. |
| `LaunchTokenInvariant.t.sol` | Four actors; transfers, approvals, and delegated transfers, including insufficient balance/allowance failures. Independent balances and allowances preserve the exact fixed supply. |
| `BoundaryAndAtomicity.t.sol` | One-unit positions, zero-rounded tranches, the supply-cap boundary, quote freshness on both quote methods, failed multi-batch claims, failed stake history, maximum invalid inputs, and six-decimal funding through purchase, sale, and claim. |

Each invariant runs **256 sequences of 64 calls**, with unexpected handler reverts
treated as failures. Targets are restricted to explicit handler selectors, so the
fuzzer cannot mutate mocks or ghost state independently. Deterministic handler tests
also exercise successful claims, burns, trades, and withdrawals. After every staking
sequence, all actors exit and all reward liabilities settle. After every vault
sequence, the owner pauses and withdraws available assets, leaving exactly the
reserved ETH; permissionless retries then fund staking and empty the vault.
Two additional arithmetic fuzz
properties run **1,000 cases each** using inline configuration.

The staking campaign uses the IMD-paired COMPANY route and funded 2:1 and 1:10 local
quotes. Fractional quotes exercise rounding and unswappable dust; stale quotes must
not retire liabilities. Its accounting separates IMD actually spent, COMPANY sent
to the dead address, and IMD retained as dust.
The vault campaign uses funded 1:1 entry quotes and varying integer sale prices to
give profit and cost-basis checks an exact oracle; existing tests and the added
boundary suite cover fractional prices and other decimals. Native two-hop buybacks,
callback attacks, taxed tokens, underdelivery, and failed conversions remain covered
by the accepted unit tests. Mocks establish local accounting behavior, not oracle
integrity or compatibility with a particular live adapter.

The revision preserves the existing campaigns and adds two deterministic handler
regressions. One carries reserves through failed retries, a purchase spending all
available ETH, pause, keeper removal, zero reward share, and full withdrawal before
settling the closed position. The other retires an expired nine-unit remainder
while preserving an unexpired batch and both token donations, then settles the
remaining liability. These tests ensure the added states are reachable.

Live fork validation of the concrete Robinhood registry, venue, pools, oracle
timestamps, token behavior, and native refunds remains owed once those integration
deployments are supplied. The default suite requires no RPC, network, environment
mutation, or external process execution.
