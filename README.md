# HAMSTER

`src/HamsterToken.sol` implements HAMSTER (symbol `HAMSTER`), an immutable ERC-20 with 18 decimals. Its constructor mints **1,000,000,000 HAMSTER**, exactly **1000000000000000000000000000** base units, once to the immediate deployer (`msg.sender`). In the IdentityMD launch, that deployer is the launch factory.

Official project references supplied by the requester:

- Twitter: [@hamsterhourgame](https://twitter.com/hamsterhourgame)
- Website: https://hamster-hour-bet-on-the-wheel.sites.imd.fun/

## Behavior and assumptions

The token uses the unmodified OpenZeppelin Contracts v5.0.2 ERC-20 implementation. Every successful transfer credits the exact requested amount. Standard `Transfer` and `Approval` events are emitted; zero-value transfers to a nonzero address are valid. Invalid recipients, insufficient balances, and insufficient allowances revert with ERC-6093 custom errors. Finite allowances decrease when spent; an allowance of `uint256.max` follows OpenZeppelin's unlimited-allowance convention. Spending an allowance does not emit an additional `Approval` event in this version.

There is no token owner, privileged role, post-deployment minting, burning, transfer tax, pause, blocklist, upgrade mechanism, or external callback. The constructor makes no external calls. The constant `INITIAL_SUPPLY` is `1_000_000_000 * 10 ** 18`. There are no configurable token parameters or initialization calls.

The brief's “vault” means the 80% treasury allocation at the requester's specified recipient, following the supplied launch economics. No lock duration, vesting, deposits, share accounting, or game mechanics were requested. This project therefore deploys only the token; custody and use of the vault allocation belong to the recipient. The website and Twitter are project references documented here, not on-chain oracles or application integrations.

## Launch allocations and responsibilities

The constructor deliberately leaves **100%** of the supply with the factory. The factory performs distribution after creation; the token does not distribute during construction or hardcode platform addresses.

| Destination | Share of total supply | HAMSTER amount | Responsible party |
| --- | ---: | ---: | --- |
| Pool | 10% | 100,000,000 | Factory seeds through the launch's PoolManager |
| Vault / treasury | 80% | 800,000,000 | Factory sends remainder to `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` |
| Swarm | 10% | 100,000,000 | Factory sends to the launch's MerkleDistributor before pool seeding |

The platform determines the distributor and contributor allocations. There is no Swarm wallet or distributor contract to deploy in this repository. The supplied fees-and-payouts recipient is also `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`. The ERC-20 itself charges no fees and runs no payout mechanism; the platform handles its launch fees and pool operations.

The separate manifest step must use these supplied values:

| Parameter | Value |
| --- | --- |
| Launch kind | `custom_token` |
| Chain | Ethereum, chain ID `1` |
| Token Solidity identifier | `HamsterToken` |
| Source | `src/HamsterToken.sol` |
| Constructor arguments | `[]` |
| Token name / symbol | `HAMSTER` / `HAMSTER` |
| Decimals | `18` |
| Total supply, base units | `1000000000000000000000000000` |
| Application contracts | None |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | `12500` (1.25%, platform pool fee) |
| Tick spacing | `60` |
| Initial price provenance | `79228162514264337593543950336` |
| `economics.poolBps` | `1000` |
| `economics.initialMarketCapWei` | `1000000000000000000000` (1,000 IMD) |
| `economics.remainderTo` | `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` |

The deployer derives the actual opening pool price from the opening market cap, supply and token address. The initial-price provenance field is not an instruction to initialize the actual pool at a one-to-one price. Pool liquidity rounding and final forwarding are handled by the platform's launch implementation.

No `launch.json` is included: the platform's separate manifest step produces it after acceptance. Deployment uses this contract's compiled creation bytecode without arguments. The launch service handles attestation and broadcasting through its factory. A direct deployment outside that process only mints to the caller and does not create or fund a pool.

## After launch

There are no owner setters or additional token initialization steps. The launch operator verifies deployed bytecode, metadata, total supply, factory distribution and actual pool behavior, then publishes the verified token address. The treasury recipient secures and manages its 80% allocation; the Swarm distributor processes claims under platform rules. The token cannot enforce how treasury funds are used or recover assets sent to the wrong address.

Holders choose their own approvals and can revoke them with `approve(spender, 0)`. Integrations should approve only the amount they need. As with standard ERC-20 approvals, replacing a nonzero allowance can race with a spender using the existing allowance; first revoke and confirm before granting a replacement. Ordinary ETH transfers to this token revert, and there is no asset-recovery function.

## Build and checks

The project is rooted here with `src/`, `test/`, `foundry.toml` and explicit remappings. Solidity **0.8.26**, Cancun EVM, optimizer with **200 runs**, and `bytecode_hash = "none"` are pinned in `foundry.toml`. Use a Foundry installation with that compiler available. No RPC, account, secrets, environment configuration, FFI, filesystem cheatcodes or dependency downloads are needed by the tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x16937b27b914c6a2d9da3b12a3059dbd28fa8244de8471f246564329a6432dd2 forge test
forge fmt --check
```

OpenZeppelin's ERC-20 source and its required imports, plus forge-std v1.9.7 for testing, are vendored as ordinary files under `lib/`, including their licenses. `DEPENDENCIES.json` records release URLs and SHA-256 hashes for the original archives and each included file. There are no submodules or package installation steps. Formatting excludes vendored files to preserve upstream content.

Tests cover metadata, the constructor mint event, CREATE2 factory deployment, exact 10/80/10 distribution, full Swarm claim transfers, both directions of pool-address transfers, standard transfer/approval events, self transfers, zero and maximum values, allowance replacement/revocation, delegated transfers, invalid addresses, balance/allowance failures with rollback, unsupported administrative calls, rejection of ETH and unknown calls, recipient callback absence, runtime size, and forbidden opcodes. Six fuzz tests exercise successful transfers and authorization failures with 512 inputs each. Two stateful invariants run 128 sequences of depth 64, checking constant supply, conservation of balances and an independent balance/allowance model across four holders.

The local factory and pool addresses are **test doubles**. The pool transfer test does not claim to execute a real Uniswap swap. The supplied protected tests rely on platform-only launch artifacts and configuration and are not standalone tests in this repository; the platform performs that integration check using the actual launch implementation. This deliverable includes no production pool, factory or distributor replacement.

## Security review scope

The supplied security reference was used to review the ERC-20's scope: explicit balance/allowance authorization, fixed supply, zero-address validation, checked failure behavior, exact transfer amounts, and no external calls, signatures, pricing, randomness or upgrade hooks. There are no admin powers to hand over. Stateful and negative tests check conservation and unauthorized spending. The factory receives the supply because the token launch expressly requires it, not because it has an ongoing ownership role.

Foundry unit, fuzz and invariant checks are local verification. Slither and Mythril are not part of these checks. The platform's independent adversarial review and deployment verification remain release responsibilities; local tests do not constitute an independent audit.
