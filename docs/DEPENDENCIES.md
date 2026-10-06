# Vendored dependencies

These are ordinary source files, included for offline builds. There are no git submodules or package-manager downloads at build/test time.

| Dependency | Upstream release | Delivered subset | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | `v5.1.0` | ERC20, SafeERC20, Math, ReentrancyGuard and transitive Solidity imports | `lib/openzeppelin-contracts/LICENSE` (MIT) |
| forge-std | `v1.9.7` | Upstream `src/`, including Test and Vm | `lib/forge-std/LICENSE-MIT` and `LICENSE-APACHE` |

Fetched from the tagged source archives at `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0` and `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`. No dependency code is modified. `docs/dependency-sha256.txt` records per-file hashes of all delivered dependency files. Verify locally with `sha256sum -c docs/dependency-sha256.txt`.

The `env*`, `setEnv`, FFI and filesystem cheatcode declarations in vendored forge-std are upstream test interfaces, not calls made by project tests. Neither application nor local test code uses them. `SafeERC20`/`Address` may contain unused helper definitions; the compiled application runtimes are checked for forbidden opcodes by `DeploymentTest`.
