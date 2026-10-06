# Deployment handoff

## Artifact and constructor order

The manifest contributor should describe the accepted source with kind `evm_project`, token artifact `src/LaunchToken.sol:LaunchToken`, and two applications in this dependency order:

1. `CompanyStaking` — artifact `src/CompanyStaking.sol:CompanyStaking`.
2. `SniperVault` — artifact `src/SniperVault.sol:SniperVault`.

`LaunchToken()` has no constructor arguments. All constructors are nonpayable and use only supported static argument types. No initialization call is required, no linked external library is deployed, and constructors preserve the factory's entire token balance. The registry is consulted only when trading/burning, so a COMPANY pool created later in the same factory launch can resolve at runtime.

### CompanyStaking constructor

| Index | Argument | Type | Value to supply |
| --- | --- | --- | --- |
| 0 | `company_` | address | `$token` |
| 1 | `imd_` | address | Canonical Robinhood IMD; **not supplied / unverified** |
| 2 | `registry_` | address | Reviewed `ILaunchRegistry` implementation; **not supplied / unverified** |
| 3 | `launchFactory_` | address | Canonical IMD launch factory proven by the registry; **not supplied / unverified** |
| 4 | `venue_` | address | Reviewed `ITradingVenue` implementation; **not supplied / unverified** |
| 5 | `imdEthPoolId_` | bytes32 | Identity of the canonical IMD/native ETH conversion pool; **not supplied / unverified** |
| 6 | `chainId_` | uint256 | Confirmed Robinhood target network chain ID from network policy; **not supplied / unverified** |

### SniperVault constructor

| Index | Argument | Type | Value to supply |
| --- | --- | --- | --- |
| 0 | `owner_` | address | `$owner`; approved wallet `0x40699CF5C05b0DA76ab1f2C9308A5c0AaFA916Df` |
| 1 | `staking_` | address | `$contract:CompanyStaking` |

The vault reads the already-deployed staking contract's immutable integration parameters in its constructor. It therefore cannot accidentally use a different IMD token, venue, registry, chain or conversion pool from its reward recipient. Both application identifiers are under 32 ASCII characters.

The constructor checks nonzero configuration and matching `block.chainid`, but cannot authenticate supplied protocol implementations. It deliberately makes no dependency calls to external network contracts during deployment: the policy deployment harness creates the project locally without those protocols. Services and independent review must validate code, identity and behavior of each immutable dependency. A wrong value cannot be patched by the owner after deployment.

## Required live integration

The sources in `src/interfaces/` define **application integration ports**, not a claim that a native IMD factory, Uniswap router or quoter exposes these selectors. No such ABI or network file was supplied. Do not substitute an unrelated deployed router/factory into these constructor arguments. If the network lacks compatible implementations, concrete adapter source is additional integration work that must be accepted and independently reviewed before deployment. The test mocks are explicitly unsuitable.

The registry must implement:

```solidity
getLaunch(address token) external view
    returns (address factory, address pairedAsset, bytes32 poolId);
```

It must derive origin from authenticated canonical-factory state, not token self-reporting, symbol/name, arbitrary user registration or an owner-written allowlist. It must identify the launch's actual pool and its IMD/native ETH pair. Unknown tokens must revert or report no matching factory/pool. The returned identity must fix currencies, fee, tick spacing and hooks as appropriate for the network. It must not redirect an accepted token's pool later. The application compares factory and pair on every new buy and COMPANY buyback; sales use the stored pool identity.

The venue must implement the exact [ITradingVenue ABI](abi/ITradingVenue.json) and validate the given pool identity against the requested input and output currencies. It must reject arbitrary route substitutions, send output only to the specified recipient, and use native ETH as `address(0)`. The application supplies itself as recipient on every swap. It must support:

- `quoteExactInput` and `quoteExactOutput` as **view** functions returning an amount and the actual price-observation timestamp. Quotes include the relevant fees and size-dependent price impact. Timestamping an instantaneous spot quote with the current block time does not satisfy the intended oracle assumption.
- A reviewed manipulation-resistant reference price (for example a sufficiently established TWAP or other independently authenticated price). The application rejects stale/future/zero quotes but cannot independently validate price methodology. Ordinary DEX quoters are not automatically compatible, especially quoters that simulate swaps by reverting or provide only instantaneous spot prices.
- `swapExactInput`: consume precisely the authorized input and satisfy the nonzero output minimum; send output synchronously. ERC-20 input is pulled with the exact temporary allowance. Native input is `msg.value`.
- `swapExactOutput`: deliver exactly the requested output, consume at most the maximum, and synchronously return unused native input to the caller. ERC-20 input is pulled only as spent. No later refund credit is acceptable.
- Canonical launch-token/IMD or launch-token/ETH swaps in both directions, canonical ETH/IMD conversion in both directions, and the exact COMPANY launch pool. COMPANY may be ETH-paired even when IMD is the reward asset.
- No owner/keeper-controlled arbitrary execution, route alteration, recipient change or residual allowance. Review any administrative or upgrade power in the external dependencies; the applications themselves have none for these links.

Do not describe locally mocked quotes as a live oracle, or assume newly launched illiquid tokens already have usable reference prices. This is an unresolved production integration choice, not a prerequisite to compiling and testing the contribution. A concrete incompatibility in selected source/constructors/authorization remains a review finding; policy publication and signed-artifact linkage belong to services.

## Manifest and liquidity responsibilities

The separate manifest author writes `launch.json`; this contribution does not create one. The manifest must resolve static constructor values, backward references and policy owner correctly, without hidden initialization or token transfers.

Factory-supplied MerkleDistributor and PoolInitializationGuard are not contributor applications. The factory handles supply distribution: 10% swarm (2% accepted-work wallets and 8% admitted paired seats), and the requester's 90% split between launch liquidity and its wallet per policy. The default liquidity allocation is 80% of supply. These source contracts implement none of that allocation or pool fee collection.

The approved manifest currency is native ETH unless policy selects the chain's canonical pair token. Canonical manifest guidance uses fee 3000, tick spacing 60, and initial price `79228162514264337593543950336`. Admission fields do not promise a 0.3% trading fee: the factory derives the opening price from pinned policy and reads effective trading fees from network LaunchFees (the provided launch guidance describes 1.25% by default, split 1% requester and 0.25% IMD). The frontend and adapters must use the exact actual pool identity and fees from the deployment handoff, not reconstruct a pool from assumed defaults.

## Operational handoff

After independent source/manifest review, services publish, attest, admit, deploy and verify the source. Record chain ID, deployment transaction, bytecode/build identity, all constructor values, dependency code identities, actual pool key, deployment block and ABI versions for the frontend. This contribution contains no broadcasting script, funded wallet, signature or transaction submission.

OWNER calls `depositIMD` after ERC-20 approval and/or payable `depositETH`, then registers its keeper with `setKeeper`. Zero revokes the keeper. These are ordinary operational functions; application deployment is already complete before deposits or keeper activation.

The later frontend/keeper service watches canonical launch events, calls `snipe`, evaluates `sell` every 30 seconds while running, and finds expired unburned batches from `RewardsFunded` events. It supplies transaction fees itself. Retry failed swaps only when quotes/liquidity recover; do not lower immutable integration security assumptions to hide failures. Users can always unstake without calling the market and can independently claim or burn eligible batches.

Reorgs, delayed L2 timestamps, sequencer downtime/censorship, unavailable pricing, an offline keeper and owner key loss remain operational risks. Time windows use `block.timestamp`, never L2 block counts. The chosen UTC-day accounting and half-open seven-day claim window must be reflected in frontend countdowns.
