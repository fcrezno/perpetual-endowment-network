# Shutter PEN deployment runbook

A condensed operator checklist for the two-phase deployment described in the
[README](../README.md#deployment). The README stays the reference for what each
script does; this page is the order of operations, what to check at each step,
and the pitfalls hit during a real mainnet deployment.

**How this runbook was tested**

| Run | What it covers | Result |
| --- | --- | --- |
| Ethereum mainnet, 5–10 Aug 2026 | Every step below, with the canonical `.env.example` values | Live deployment; addresses and tx hashes in [Recorded mainnet run](#recorded-mainnet-run) |
| Local mainnet fork (`anvil --fork-url … --chain-id 31337`), 18 Nov 2026, repository at `af2d08c` | Phase 1 (Steps 2–4) and the Phase 2 preflight refusal (Step 8) | Preview addresses == deployed addresses; preflight refused a foreign Space with nothing broadcast |

The `snapshot.box` steps (5–6) cannot run on a fork, so they are covered by the
mainnet run only.

---

## 0. Before you start

- [ ] Foundry installed (`forge`, `cast`); tested with 1.7.1.
- [ ] `git submodule update --init --recursive`, then `forge build`.
- [ ] A **dedicated, otherwise idle** deployer account. Every Phase 1 address
      is derived from its nonce (see Step 4).
- [ ] ETH for gas. The mainnet Phase 1 (16 txs) cost 0.00092 ETH at
      ~0.09–0.13 gwei and Phase 2 (3 txs) 0.00002 ETH. The **preview** (not the
      broadcast script) reverts with `InsufficientDeployerBalance` if the
      deployer cannot cover the estimate (about 9.5M gas plus a 1.2× buffer), so
      always run the preview first; at higher gas prices budget accordingly.
- [ ] `cp .env.example .env`, then fill in **only** `RPC_URL`, `PRIVATE_KEY`
      (or `DEPLOYER` with `forge script --account`), and optionally
      `DEPLOYMENT_SALT`. Leave every Core and Governance value as it is for a
      Shutter PEN deployment.
- [ ] Optional: `ETHERSCAN_API_KEY` for `--verify`.

## Phase 1 — scripted

```sh
set -a; source .env; set +a
forge script script/PreviewPENSystem.s.sol:PreviewPENSystem --rpc-url "$RPC_URL"
```

Check the printed deployer, the starting nonce (must equal
`cast nonce <deployer>`), and the predicted Safe address. Then, **with no other
transaction from the deployer in between**:

```sh
forge script script/DeployPENSystem.s.sol:DeployPENSystem --rpc-url "$RPC_URL" --broadcast
# optional: --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Expected: the six logged addresses equal the preview, the script ends with
`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, and `deployments/<chainId>.json`
contains `"phase2Pending": true` with `space` and `execStrategy` set to zero.
In the fork rehearsal all six preview addresses matched the deployed ones.

## Phase 2 — snapshot.box, then the finalize script

**Step 5, the wizard.** Follow the README table. Three fields caused trouble or
are easy to get wrong:

1. **Decimals = `0`**, in the `OZ Votes` strategy **and** in the `OZ Votes`
   entry inside the proposal-validation strategy. Both default to `18`; left
   there, every seat displays as `0.000000000000000001`.
2. **Every ownership / controller field = the Safe** from
   `deployments/<chainId>.json`. The wizard's transactions do not have to come
   from the deployer: in the mainnet run they were signed by a different wallet,
   which was harmless because every ownership field pointed at the Safe. A
   field left on the connected wallet would make that wallet the owner.
3. **Executions = `Timelock`** for Shutter PEN (`TIMELOCK_ENABLED=true`), quorum
   `10`, delay `1 day`, veto guardian blank.

**Step 6, the two addresses.** The wizard sends two transactions to the SX
`ProxyFactory`: the exec-strategy proxy first, then the Space proxy. Both emit
the same non-indexed `ProxyDeployed(implementation, proxy)` event, so it is easy
to swap them. Tell them apart by `implementation`, using
`lib/sx-evm/deployments/ethereum.json`: `SpaceImplementation` →
`PHASE2_SPACE_ADDRESS`; `TimelockExecutionStrategyImplementation` →
`PHASE2_EXEC_STRATEGY_ADDRESS`. Check that `owner()` on both returns the Safe.

**Step 7, preview (recommended).**

```sh
forge script script/PreviewSpaceBinding.s.sol --rpc-url "$RPC_URL"
```

**Step 8, finalize.**

```sh
forge script script/BootstrapPEN.s.sol:BootstrapPEN --rpc-url "$RPC_URL" --broadcast
```

The governance-wiring preflight runs inside the simulation, before anything is
sent. Rehearsed on the fork with the *mainnet* PEN Space (owned by a different
Safe): the script stopped with
`UnexpectedSpaceOwner(<other Safe>, <this Safe>)`, the deployer nonce did not
change, and the artifact kept `phase2Pending`. A mis-pasted or swapped address
therefore costs nothing.

Expected on success: three transactions (`setSpace`, Safe `enableModule`, Safe
`swapOwner`), then `deployments/<chainId>.json` rewritten with the Space and
exec strategy and without `phase2Pending`.

## Verify

Run the state verifier and the log-based checks (README Step 9):

```sh
DEPLOYMENT_FILE=deployments/<chainId>.json FROM_BLOCK=<Phase 1 first block> \
  ./script/verify-pen.sh .env
```

These scripts are added by
[shutter-network/perpetual-endowment-network#6](https://github.com/shutter-network/perpetual-endowment-network/pull/6);
until that is merged they are not on `main`, and Step 9 fails with "file not
found" (confirmed in the fork rehearsal). On the mainnet deployment they report
72/72 state checks and 11/11 history checks passing.

The Snapshot X implementations behind the Space and the exec strategy are
already verified on Etherscan (the timelock implementation
`0xf2A1C2f2098161af98b2Cc7E382AB7F3ba86Ebc4` since 28 Sep 2026), so after
Phase 1 `--verify` the whole ownership chain is readable.

## Publish

Follow the README "Publishing the Deployment" section, and include the two
`snapshot.box` transaction hashes in the artifacts PR.

## Pitfalls seen in practice

- **Nonce drift.** Any transaction from the deployer between preview and
  broadcast changes every predicted address, including the Safe.
- **Decimals left at 18** in the wizard (above).
- **Space and exec-strategy addresses swapped** in Step 6 (above); the Step 8
  preflight catches it.
- **Custom authenticators or custom Space metadata.** An earlier deployment
  (July 2026, before the two-phase flow) used a custom `PENTxAuthenticator` and
  hand-built Space metadata, and Snapshot never indexed the Space. The current
  flow (stock `EthTxAuthenticator`, Space created by `snapshot.box`) is the fix;
  do not reintroduce either.
- **Timelock events.** The deployed `TimelockExecutionStrategy` implementation
  does not emit `SpaceEnabled` for its initial spaces; they appear only in
  `TimelockExecutionStrategySetUp`. Matters only if you read the exec
  strategy's history from logs.

## Recorded mainnet run

Chain id 1. Canonical `.env.example` values; deployer-specific values only
differed (`RPC_URL`, `PRIVATE_KEY`; `DEPLOYMENT_SALT` left at zero).

| Contract | Address |
| --- | --- |
| Safe | `0xB7f69C3cd9E3dFB4aE0Ed9ee65eb2Ed42EdeECE3` |
| SeatToken | `0xe2F401A0fb40dA191b9fa8C44Fa09D31cE17374c` |
| PrincipalManager | `0x4517651c7071fecDA97Eb656a9d3A50B92b84517` |
| BondingTranche | `0x652a9A770f9Cfe26e409Aa63E84B8a4e21abe1e5` |
| Space | `0xC85cf8400ABB7056088279c122912E7e19634885` |
| ExecStrategy (Timelock) | `0x4D52DFCde316FEC3364749C077600d71B7093746` |

| Step | When (UTC) | Blocks | Transactions |
| --- | --- | --- | --- |
| Phase 1 broadcast | 5 Aug 2026 | 25,686,663 – 25,686,672 | 16 (first: `0x0a65a0acfe7d256d8210291dda3e413aa4c7f698ae3bb2d260084d27d64d4cb4`) |
| snapshot.box exec strategy | 10 Aug 2026 | 25,722,126 | `0x9c882361f408de12cd350a5eab916a31e09e2468c6eb96bffa7dc1320d73c721` |
| snapshot.box Space | 10 Aug 2026 | 25,722,134 | `0xa536dabc819ee89bb6febf274aa48d4209e3b507d4da5f9ff49a2a1cde9a9672` |
| `setSpace` | 10 Aug 2026 | 25,722,156 | `0x1943394f8453a3ddc4d7a1932ab81892d684e9a8cc33a04ed6cf42462fb6a12d` |
| Safe `enableModule` | 10 Aug 2026 | 25,722,158 | `0xd4255899b5bfbf0e86bc52e927ba9bd706d76db317a82377d9a8d7487705614d` |
| Safe `swapOwner` | 10 Aug 2026 | 25,722,158 | `0x9d25174534e8d1f285bf5e8f4f12d85a92f1c767d37ec367dd3febff21d3a596` |

Full receipts are in
[shutter-network/shutter-pen-deployment-artifacts](https://github.com/shutter-network/shutter-pen-deployment-artifacts)
(pull request #1).
