# Vendored dependencies

These are ordinary source files, included for offline builds. There are no git submodules or package-manager downloads at build/test time.

| Dependency | Upstream release | Delivered subset | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | `v5.1.0` | ERC20, SafeERC20, Math, ReentrancyGuard and transitive Solidity imports | `lib/openzeppelin-contracts/LICENSE` (MIT) |
| forge-std | `v1.9.7` | Upstream `src/`, including Test and Vm | `lib/forge-std/LICENSE-MIT` and `LICENSE-APACHE` |

Fetched from the tagged source archives at `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0` and `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`. Dependency logic is unchanged. Ten Solidity files differ from the tagged archives solely by `forge fmt` formatting (including tuple spacing); the other 37 files are byte-identical. All 47 files were compared with the tagged archives during this revision, and the ten formatted files exactly equal the output of `forge fmt --raw -` under this repository's settings (Foundry 1.8.3). `docs/dependency-sha256.txt` records hashes of the files actually delivered, after formatting. Verify locally with `sha256sum -c docs/dependency-sha256.txt`.

The `env*`, `setEnv`, FFI and filesystem cheatcode declarations in vendored forge-std are upstream test interfaces, not calls made by project tests. Neither application nor local test code uses them. `SafeERC20`/`Address` may contain unused helper definitions; the compiled application runtimes are checked for forbidden opcodes by `DeploymentTest`.

## Archive verification record

Verified release archives and their SHA-256 digests:

- `openzeppelin-contracts`: `8a3b08cfc756437ba3343901565b18182adb42ec1e621960240a19da5d738686`. Formatting-only files: `contracts/token/ERC20/utils/SafeERC20.sol`, `contracts/utils/Address.sol`, `contracts/utils/math/Math.sol`.
- `forge-std`: `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94`. Formatting-only files: `src/StdAssertions.sol`, `src/StdJson.sol`, `src/StdToml.sol`, `src/Vm.sol`, `src/console.sol`, `src/interfaces/IERC7540.sol`, `src/interfaces/IMulticall3.sol`.

The original checksum record described the archive bytes before formatting. The revised record describes the delivered bytes; no vendored source file was changed for this repair. Archive fetching is a provenance check only, never a build or test dependency.
