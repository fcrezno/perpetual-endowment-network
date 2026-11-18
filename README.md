# PEN Contracts

PEN is a minimal on-chain core for a seat-based membership treasury: members buy non-transferable seats at a tranche-based price, the treasury deploys principal into an ERC-4626 vault, and yield is paid out to recipients selected off-chain via Snapshot ranked-choice voting and ratified on-chain via Snapshot X / EVM (YES/NO).

## Table of Contents

- [Concept](#concept)
- [Architecture](#architecture)
- [Setup & Deployment](#setup--deployment)
  - [Prerequisites](#prerequisites)
  - [Local setup](#local-setup)
  - [Environment configuration](#environment-configuration)
  - [Deployment](#deployment)
  - [Publishing the Deployment](#publishing-the-deployment)
- [Usage Flows](#usage-flows)
  - [Purchase](#purchase)
  - [Refund](#refund)
  - [Reclaim](#reclaim)
  - [Yield Funding](#yield-funding)
- [Operations](#operations)
- [Limitations](#limitations)

## Concept

PEN splits governance into two layers:

- **Off-chain (Snapshot, ranked-choice):** members propose candidate slates (recipients + amounts, plus "none of the above") and select a single *winning slate* via ranked-choice voting.
- **On-chain (Snapshot X / EVM, YES/NO):** a member submits a proposal encoding the winning slate as executable transactions via the Space's whitelisted authenticator (stock `EthTxAuthenticator` at deploy; the DAO may enable additional stock authenticators such as `EthSigAuthenticator` later via a governance-owned `Space.updateSettings` call); seat holders vote using the stock `OZVotesVotingStrategy` (backed by `SeatToken.getPastVotes`); after the optional timelock, the proposal executes through `AvatarExecutionStrategy` → Safe.

For PEN treasury batch payouts, the canonical execution call is `PrincipalManager.executeFunding(recipients, amounts)` — a single batched primitive that is materially cheaper under Snapshot X execution than `withdraw + N transfers`.

Further reading: [`docs/flows.md`](docs/flows.md), [`docs/pen-operator-guide.md`](docs/pen-operator-guide.md).

## Architecture

| Contract | Role |
| --- | --- |
| `SeatToken` | Non-transferable `ERC20Votes` seat token, `decimals = 0`. Governance participation is refreshed via `refreshActivity` (see below). |
| `BondingTranche` | Seat sale (tranche-based pricing), fixed-price refund, inactivity reclaim. |
| `PrincipalManager` | Principal treasury controller: refund liquidity, principal accounting, ERC-4626 vault integration. |

**Roles**

| Contract | Role | Holder / Purpose |
| --- | --- | --- |
| `SeatToken` | `DEFAULT_ADMIN_ROLE` | **Unheld** — renounced at deploy. No party can reroute the roles below. |
| `SeatToken` | `MINTER_ROLE` | `BondingTranche` (mint on purchase) — frozen at deploy |
| `SeatToken` | `BURNER_ROLE` | `BondingTranche` (burn on refund/reclaim) — frozen at deploy |
| `BondingTranche` | `DEFAULT_ADMIN_ROLE` | Governance Safe |
| `BondingTranche` | `RECLAIMER_ROLE` | Authorized reclaimer |
| `PrincipalManager` | `DEFAULT_ADMIN_ROLE` | Governance Safe |
| `PrincipalManager` | `BONDING_ROLE` | `BondingTranche` (record purchases, trigger refunds) |

**Seat activity**

Seat activity is refreshed via the permissionless `SeatToken.refreshActivity(voter, proposalId)` (and the proposer-side companion `refreshActivityForProposal(author, proposalId)`). Each call verifies the vote or proposal against the Space's on-chain `voteRegistry` / `proposals` mapping — no role, no trusted contract, no admin surface. Any vote through any whitelisted authenticator (`EthTx`, `EthSig`, or a future one) is refreshable. See `docs/flows.md` §Activity refresh flow for who typically calls these and the batching primitives.

**Treasury accounting**

- Purchase proceeds land in `PrincipalManager`; excess over the configured liquid reserve is auto-deposited into `principalVault` (ERC-4626).
- `accountedPrincipal` tracks the protocol's principal obligation (created by seat sales, reduced by refunds).
- `availableYield = max(totalManagedAssets − accountedPrincipal, 0)`.

## PEN → PEN migration

PEN's core parameters — payment asset, refund price, tranche schedule, supply cap, inactivity period — are immutable in the deployed contracts. When governance needs to change any of them, the path is to **deploy a new PEN and migrate the treasury into it**.

Two admin primitives on `PrincipalManager` support this, both gated by the Safe's `DEFAULT_ADMIN_ROLE`:

- `pause()` / `unpause()` — freezes user-state-changing flows (`purchase`, `refund`, `reclaim`) on the old deployment without disturbing admin operations.
- `withdraw(token, to, amount)` — moves any ERC-20 balance out of `PrincipalManager` to a chosen receiver. Callable any time; does not adjust `accountedPrincipal`.

A migration ceremony typically looks like: deploy the new PEN → pause the old `PrincipalManager` → drain its principal vault to liquid → `withdraw` the treasury to the Safe → (if migrating to a different asset, swap externally) → seed the new `PrincipalManager` → governance on the new PEN reissues seats to original holders.

The most common reason to migrate is **payment-asset migration** (e.g. USDC → USDT), but the same procedure applies to any change that requires fresh contracts. See `docs/pen-migration.md` for the step-by-step runbook and risks.

## Setup & Deployment

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Git
- For deployment: an RPC endpoint for the target chain and a funded deployer account

### Local setup

1. Clone the repository and enter the directory.
2. Initialize submodules:
   ```sh
   git submodule update --init --recursive
   ```
3. Build:
   ```sh
   forge build
   ```

### Environment configuration

Copy the example file and fill in values:

```sh
cp .env.example .env
```

All deployment variables and their meanings are documented inline in [`.env.example`](.env.example) — refer to that file as the source of truth.

The variables above the **Core config** divider (`RPC_URL`, `DEPLOYMENT_SALT`, `PRIVATE_KEY` / `DEPLOYER`) are deployer-specific and must always be filled in.

The **Core config** and **Governance config** sections are pre-populated with the canonical values for deploying **Shutter PEN**. Leave these unchanged if you are deploying PEN for Shutter. Only modify them if you are deploying a different PEN instance.

### Deployment

Deployment is split into two phases because the Snapshot X `Space` is created via the [`snapshot.box`](https://snapshot.box/#/create/snapshot-x) UI, whose form does not expose the `ProxyFactory` `saltNonce` needed to pre-derive the Space address from the deployer sequence.

- **Phase 1 (scripted)** — deploy the Safe (owner = deployer EOA, threshold = 1, no module), `SeatToken`, `PrincipalManager`, and `BondingTranche`, and hand admin/reclaimer roles to the new Safe. The Space and its execution strategy are **not** created here.
- **Phase 2 (UI + scripted finalize)** — operator creates the Space via `snapshot.box` (the wizard deploys a fresh `AvatarExecutionStrategy` or `TimelockExecutionStrategy` as part of the Space-creation tx). A small finalize script then binds the Space to `SeatToken`, enables the UI-deployed exec strategy as a Safe module, and swaps it in as the Safe's sole owner.

For a condensed operator checklist, with the recorded mainnet run and the pitfalls hit during it, see [`docs/deployment-runbook.md`](docs/deployment-runbook.md).

The scripts involved:

- [`script/PreviewPENSystem.s.sol`](script/PreviewPENSystem.s.sol) — Phase 1 dry-run. Predicts the full address plan from the deployer, its current nonce, and `DEPLOYMENT_SALT` without broadcasting.
- [`script/DeployPENSystem.s.sol`](script/DeployPENSystem.s.sol) — Phase 1 broadcast. Writes `deployments/<chainId>.json` marked `phase2Pending: true`.
- [`script/PreviewSpaceBinding.s.sol`](script/PreviewSpaceBinding.s.sol) — Phase 2 pre-flight. Reads the candidate Space (via `PHASE2_SPACE_ADDRESS`) and prints owner, authenticators, voting strategies, proposal validation strategy, and voting-window params for human eyeballing.
- [`script/BootstrapPEN.s.sol`](script/BootstrapPEN.s.sol) — Phase 2 broadcast. First runs an on-chain **governance-wiring preflight** that cross-checks the operator-supplied Space + exec strategy against the `.env` governance config (authenticator, voting strategy over the deployed `SeatToken`, proposal-validation strategy + threshold, voting-window params, exec-strategy quorum / timelock delay / veto guardian) and the structural link (the exec strategy has this Space enabled and is owned by / targets the Safe). A mismatch reverts during simulation, so **nothing is broadcast** and the irreversible `swapOwner` never fires against a mis-pasted or mis-configured address. On success it runs `SeatToken.setSpace`, submits a Safe transaction to `enableModule(execStrategy)`, then a second Safe transaction to `swapOwner(SENTINEL, deployer, execStrategy)`. Rewrites the artifact with the resolved `space` and `execStrategy` addresses and drops the `phase2Pending` flag.

#### Step 1 — Load the environment

After completing [Environment configuration](#environment-configuration), load the file into your shell:

```sh
set -a; source .env; set +a
```

#### Step 2 — Preview Phase 1

Run the preview against the **exact deployer address** you intend to broadcast from:

```sh
forge script script/PreviewPENSystem.s.sol:PreviewPENSystem --rpc-url "$RPC_URL"
```

The preview prints the deployer, starting nonce, and every predicted Phase 1 address (Safe singleton, Safe proxy factory, Safe, `SeatToken`, `PrincipalManager`, `BondingTranche`).

#### Step 3 — Verify the predicted addresses

Confirm:

- the deployer address matches the account you will broadcast from,
- the starting nonce matches the deployer's current on-chain nonce,
- the predicted Safe address is what you expect (it is bound to `DEPLOYMENT_SALT`).

#### Step 4 — Broadcast Phase 1

```sh
forge script script/DeployPENSystem.s.sol:DeployPENSystem \
  --rpc-url "$RPC_URL" \
  --broadcast
```

On success the script logs every deployed address and writes `deployments/<chainId>.json` with `phase2Pending: true`. Broadcast artifacts are additionally emitted under `broadcast/DeployPENSystem.s.sol/<chainId>/`.

Append `--verify --etherscan-api-key "$ETHERSCAN_API_KEY"` to have Foundry submit source verification for every Phase 1 contract (or run `forge verify-contract` per address afterwards).

**Operational caveat — nonce binding.** Address prediction is bound to the deployer's nonce. **Any other transaction from the deployer between preview and broadcast invalidates every predicted address**, including the Safe address. Use a dedicated, otherwise-idle account for deployment, and broadcast immediately after previewing.

#### Step 5 — Create the Space via `snapshot.box`

Open [`https://snapshot.box/#/create/snapshot-x`](https://snapshot.box/#/create/snapshot-x), connect the deployer EOA (or the Safe), and walk through the eight-step wizard. Values below are the canonical **Shutter PEN** defaults from `.env.example`; substitute Phase 1 addresses from `deployments/<chainId>.json` where indicated.

| Step | Field | Value |
| --- | --- | --- |
| **Profile** | Space name | `Shutter PEN` (or your chosen display name) |
| | Avatar / cover | Upload image in the UI ([shutter-logo](logo/shutter-pen-logo-blue-1024.png)) |
| | Description | A perpetual endowment network (PEN) funding projects aligned with The Ethereum Cypherpunk Manifesto |
| | External URL / socials | Website URL: shutterpen.eth.limo |
| | Voting power symbol | `SEAT` |
| **Network** | Space network | `Ethereum` (mainnet), matching your RPC |
| **Strategies** | Voting strategy | `OZ Votes` — token = `deployments/<chainId>.json → seatToken` |
| | Decimals | **`0`** — the dialog defaults to `18`, but `SeatToken` has `decimals = 0`. Left at `18`, every seat balance displays as `0.000000000000000001`. |
| **Proposal validation** | Strategy | `Proposition power` — threshold = `1`, allowed voting strategies = the `OZ Votes` entry from the previous step |
| | Decimals | **`0`** in this strategy's `OZ Votes` entry as well (same default of `18`) |
| **Executions** | Strategy type | `Safe module (Zodiac)` if `TIMELOCK_ENABLED=false`, else `Timelock` |
| | Controller address | `deployments/<chainId>.json → safe` (makes the freshly-deployed exec strategy Safe-owned from the get-go) |
| | Quorum | `10` (`AVATAR_QUORUM`) |
| | Safe address *(Avatar only)* | `deployments/<chainId>.json → safe` |
| | Veto guardian address *(Timelock only)* | Leave blank (defaults to `0x0000…0000`) |
| | Timelock delay *(Timelock only)* | `1 day` (`TIMELOCK_DELAY = 86400`) |
| **Auths** | Authenticator | `EthTx` only (stock `EthTxAuthenticator`) |
| **Voting** | Voting delay | `1 day` (enter as a duration in the UI; stored on-chain as **7200 blocks** — `VOTING_DELAY = 7200`) |
| | Min voting duration | `3 days` (stored as **21600 blocks** — `MIN_VOTING_DURATION = 21600`) |
| | Max voting duration | `3 days` (stored as **21600 blocks** — `MAX_VOTING_DURATION = 21600`) |
| **Controller** | Controller | `deployments/<chainId>.json → safe` |

Reference addresses (mainnet, from `.env.example`; verify against `lib/sx-evm/deployments/ethereum.json` before use — the sx-evm address books are named by network, e.g. `sepolia.json`, not by chain id):

- `OZ Votes` strategy — `0x2c8631584474E750CEdF2Fb6A904f2e84777Aefe`
- `Proposition power` validation — `0x6D9d6D08EF6b26348Bd18F1FC8D953696b7cf311`
- `EthTx` authenticator — `0xBA06E6cCb877C332181A6867c05c8b746A21Aed1`

`snapshot.box` pins the Profile / strategy metadata JSONs to IPFS on submit — no manual pin step is needed for a fresh deploy.

> **Reading Phase 1 addresses out of the artifact.** Every field in the table above that says "`deployments/<chainId>.json → X`" lives in the JSON that Phase 1 wrote. Get them all with:
>
> ```sh
> jq '{safe, seatToken}' deployments/<chainId>.json
> ```

#### Step 6 — Retrieve the Space and exec-strategy addresses

The wizard submits **two consecutive transactions** from your wallet (same signer, consecutive nonces, usually the same block):

1. **Exec-strategy deploy** — `ProxyFactory.deployProxy(execImpl, initData, saltNonce)` where `execImpl` is the SX `AvatarExecutionStrategy` (or `TimelockExecutionStrategy` when `TIMELOCK_ENABLED=true`). The Space address is pre-computed and included in the exec strategy's `spaces` init list.
2. **Space deploy** — `ProxyFactory.deployProxy(spaceImpl, spaceInit, spaceSaltNonce)`.

Both target the SX `ProxyFactory` (`$SX_PROXY_FACTORY`) and each emits `ProxyDeployed(address implementation, address proxy)`. **Neither field is indexed**, so both live in the log `data` (event-selector topic `0x3d2489efb661e8b1c3679865db649ca1de61d76a71184a1234de2e55786a6aad`).

Grab both tx hashes from your wallet history (the two most recent from the sender that talk to `$SX_PROXY_FACTORY`), then run the extractor on each:

```sh
for TX in <exec-strategy-tx> <space-tx>; do
  echo "--- $TX ---"
  cast receipt "$TX" --rpc-url "$RPC_URL" --json \
    | jq -r --arg pf "$(echo "$SX_PROXY_FACTORY" | tr 'A-Z' 'a-z')" '
        .logs[]
        | select((.address | ascii_downcase) == $pf)
        | select(.topics[0] == "0x3d2489efb661e8b1c3679865db649ca1de61d76a71184a1234de2e55786a6aad")
        | {implementation: ("0x" + .data[26:66]), proxy: ("0x" + .data[90:130])}'
done
```

Match `implementation` against the canonical SX implementations in `lib/sx-evm/deployments/<network>.json` (`ethereum.json` on mainnet) to know which tx produced which proxy. These implementation addresses are not in `.env.example`:

- `implementation` == `SpaceImplementation` → `proxy` is your **`PHASE2_SPACE_ADDRESS`**.
- `implementation` == `AvatarExecutionStrategyImplementation` (or `TimelockExecutionStrategyImplementation` when `TIMELOCK_ENABLED=true`) → `proxy` is your **`PHASE2_EXEC_STRATEGY_ADDRESS`**.

If you only have one of the two tx hashes, the other is the sender's tx at nonce ±1 — the explorer's "Transactions" tab for the sender shows both back-to-back.

**Quick sanity check** — call `owner()` on each proxy:

```sh
cast call <proxy> "owner()(address)" --rpc-url "$RPC_URL"
```

Both should return the Safe (`deployments/<chainId>.json → safe`). The Space additionally exposes `votingDelay()`; the exec strategy exposes `quorum()` (Avatar) or `timelockDelay()` (Timelock).

Alternatively, the Space address is also visible in the URL `snapshot.box` navigates to after submit — `#/eth:0x<space>` on mainnet, `#/sep:0x<space>` on Sepolia — but the exec-strategy address only surfaces from the on-chain receipt.

Export both for the next steps:

```sh
export PHASE2_SPACE_ADDRESS=0x<space>
export PHASE2_EXEC_STRATEGY_ADDRESS=0x<exec-strategy>
```

#### Step 7 — Preview the candidate Space

Optional but recommended sanity check before the finalize broadcast (uses `PHASE2_SPACE_ADDRESS` from Step 6):

```sh
forge script script/PreviewSpaceBinding.s.sol --rpc-url "$RPC_URL"
```

Eyeball `owner()`, authenticator whitelist, `votingStrategies()`, `proposalValidationStrategy`, and the voting-window fields. `BootstrapPEN` re-checks the `owner()` match on-chain, but this is the last chance for a human to catch a paste error before spending gas.

#### Step 8 — Broadcast Phase 2 (finalize)

With `PHASE2_SPACE_ADDRESS` and `PHASE2_EXEC_STRATEGY_ADDRESS` exported from Step 6:

```sh
forge script script/BootstrapPEN.s.sol:BootstrapPEN \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Before broadcasting anything, the script runs a **governance-wiring preflight** (`_assertGovernanceConfig`) that cross-checks the Space and exec strategy against the `.env` governance config and asserts the exec strategy is linked to this Space and controls the Safe. Because `forge script` simulates the whole run before sending any transaction, any mismatch reverts here and **no transaction is broadcast** — the irreversible owner swap in step 3 below cannot fire against a wrong address. This is the on-chain backstop for the same values `PreviewSpaceBinding` (Step 7) prints for human review.

On success it broadcasts, in order, from the same deployer EOA that ran Phase 1:

1. `SeatToken.setSpace(space)` — reverts if `space` is not a contract or its `owner()` doesn't match the Safe address baked into `SeatToken` at Phase 1; on success flips `spaceLocked = true` and clears the `bootstrap` slot to `address(0)` permanently.
2. Safe transaction `Safe.execTransaction(enableModule(execStrategy), …)`. The deployer, still the Safe's sole owner and threshold=1, signs via the `v=1` "msg.sender == approver" shortcut — no separate `approveHash` call needed.
3. Safe transaction `Safe.execTransaction(swapOwner(SENTINEL, deployer, execStrategy), …)`. After this the deployer is off the Safe entirely; the exec strategy is both the sole owner (making ECDSA-signed Safe txs impossible, since the exec strategy is a contract) and the sole enabled module (so all Safe operations route through governance).

On success the artifact at `deployments/<chainId>.json` is rewritten with the resolved `space` and `execStrategy` addresses and no `phase2Pending` flag. The system is now fully live.

#### Step 9 — (Optional) State verifier

Run [`script/VerifyPENSystem.s.sol`](script/VerifyPENSystem.s.sol) against the RPC to cross-check the contract addresses in the deployment manifest against the Shutter PEN config values in `.env` and live on-chain state:

```sh
DEPLOYMENT_FILE=deployments/<chainId>.json \
  forge script script/VerifyPENSystem.s.sol:VerifyPENSystem --rpc-url "$RPC_URL"
```

`DEPLOYMENT_FILE` is optional and defaults to `deployments/<connected-chain-id>.json`. The verifier consumes the addresses directly, so it does not need the original deployer, deployment salt, or historical deployer nonce. It checks bytecode presence, role holders, core-contract wiring and parameters, permanent SeatToken-to-Space binding, exec-strategy ownership and space enablement, Safe singleton / owner / module settings, Space authenticators / voting strategies / proposal validation strategy, voting-window parameters, and treasury solvency. It intentionally does not require optional version-specific functions such as `BondingTranche.multiPurchase`, allowing older deployments to be verified against the same setup plan.

For membership-completeness checks that also need historical logs (no stray role holders, no event-visible post-deployment Space additions, seat-holder census), use the [`script/verify-pen.sh`](script/verify-pen.sh) wrapper:

```sh
DEPLOYMENT_FILE=deployments/<chainId>.json FROM_BLOCK=<deploymentBlock> \
  ./script/verify-pen.sh .env
```

### Publishing the Deployment

After successfully deploying Shutter PEN, you can propose the deployment to the community by creating a PR in [shutter-pen-deployment-artifacts](https://github.com/shutter-network/shutter-pen-deployment-artifacts).

#### What gets published

The published bundle is three things — each one has a distinct role for downstream verifiers.

| Path | Written by | What it proves |
| --- | --- | --- |
| `deployments/<chainId>.json` | Phase 1 (`_writeDeploymentArtifact`) writes the initial file with `space`/`execStrategy` = `0x0…0` + `phase2Pending: true`. Phase 2 (`_writeFinalizedArtifact`) overwrites it with the real Space + exec-strategy addresses and drops the flag. | The canonical address manifest. This is what tests, `VerifyPENSystem`, and `verify-pen.sh` compare against. |
| `broadcast/DeployPENSystem.s.sol/<chainId>/run-*.json` | `forge script --broadcast` on Phase 1 | Foundry-format receipts for every Phase 1 tx (Safe singleton + factory + proxy, `SeatToken`, `PrincipalManager`, `BondingTranche`, role grants + renouncements). Enables Etherscan-style contract verification for each address. |
| `broadcast/BootstrapPEN.s.sol/<chainId>/run-*.json` | `forge script --broadcast` on Phase 2 | Receipts for the three finalize txs: `SeatToken.setSpace`, `Safe.execTransaction(enableModule)`, `Safe.execTransaction(swapOwner)`. |

**Not included** — the two txs that `snapshot.box` submits (the exec-strategy deploy and the Space deploy). Those are the wizard's, not ours. Downstream reviewers can pull them off the explorer using the `execStrategy` / `space` addresses in the manifest.

**Final JSON shape** (this is the schema every consumer relies on — no `phase2Pending` after Phase 2):

```json
{
  "safeSingleton":    "0x…",
  "safeProxyFactory": "0x…",
  "safe":             "0x…",
  "seatToken":        "0x…",
  "principalManager": "0x…",
  "bondingTranche":   "0x…",
  "space":            "0x…",
  "execStrategy":     "0x…"
}
```

#### Publish

Fork the artifacts repository, then run the following commands (outside of this repository):

```sh
git clone git@github.com:<<YOUR_FORK_OF_SHUTTER_PEN_DEPLOYMENT_ARTIFACTS>>.git
cd shutter-pen-deployment-artifacts
mkdir -p deployments broadcast/DeployPENSystem.s.sol broadcast/BootstrapPEN.s.sol
cp -a <<PATH_TO_PEN_REPOSITORY>>/deployments/. deployments/
cp -a <<PATH_TO_PEN_REPOSITORY>>/broadcast/DeployPENSystem.s.sol/. broadcast/DeployPENSystem.s.sol/
cp -a <<PATH_TO_PEN_REPOSITORY>>/broadcast/BootstrapPEN.s.sol/. broadcast/BootstrapPEN.s.sol/
git add deployments broadcast
git commit -m "Shutter PEN deployment by <<YOUR_NAME>>"
git push -u origin main
```

`cp -a` copies every chain subfolder (named by chain id) that Foundry produced, so you do not need to know or look up the chain id yourself.

Open a PR against `main` of the `shutter-pen-deployment-artifacts` repo. Include:

- The chain id you deployed to.
- The two `snapshot.box` tx hashes (exec-strategy deploy + Space deploy), for provenance.
- Any config diff from `.env.example` (only the deployer-specific `RPC_URL` / `DEPLOYMENT_SALT` / `PRIVATE_KEY` should differ if you're deploying Shutter PEN as-is).

## Usage Flows

### Purchase

1. User `approve`s the payment asset to `BondingTranche` for `assetAmount`.
2. User calls `BondingTranche.purchase(recipient, seats, maxCost)`.
3. `BondingTranche` computes the tranche-based price from current seat supply and pulls the asset directly into `PrincipalManager`.
4. `BondingTranche` calls `PrincipalManager.recordPurchase(totalCost)`, which increases `accountedPrincipal` and auto-deposits any excess over the liquid reserve into `principalVault`.
5. `BondingTranche` mints seats to `recipient` via `SeatToken`.

If no vault is configured, proceeds remain liquid in `PrincipalManager`.

### Refund

1. Holder calls `BondingTranche.refund(seats, receiver)`.
2. Refund amount is fixed: `seats * refundPrice`.
3. `BondingTranche` burns the holder's seats.
4. `PrincipalManager.payRefund(receiver, refundAmount)` pays from liquid funds first, then withdraws any shortfall from `principalVault`.
5. `accountedPrincipal` decreases by `refundAmount`.

Refunds reduce total supply, so the tranche cursor moves backward.

### Reclaim

1. An authorized reclaimer verifies inactivity via `SeatToken.isInactive(holder)`.
2. `BondingTranche.reclaim(holder)` burns all seats held by that account.
3. No refund is paid.

Reclaims also reduce total supply, moving pricing backward.

### Yield Funding

1. Off-chain (Snapshot, ranked-choice): community selects a winning slate (recipients + amounts).
2. On-chain (Snapshot X / EVM): a member creates a proposal encoding `PrincipalManager.executeFunding(recipients, amounts)` via the Space's whitelisted authenticator (stock `EthTxAuthenticator` by default).
3. Seat holders vote YES/NO. Simple majority (For > Against) with quorum met makes the proposal executable.
4. After the optional timelock, the proposal executes via `AvatarExecutionStrategy` → Safe: `PrincipalManager` pays from liquid assets first, withdrawing the shortfall from `principalVault` as needed.
5. `accountedPrincipal` is unchanged — funding pays from yield, not from the principal obligation.

## Operations

For day-to-day governance — vault rotation, funding payouts, tranche extensions, and refund solvency remediation — see the [PEN Operator Guide](docs/pen-operator-guide.md).

## Limitations

- The ERC-4626 integration is generic; tests use demo vaults, while production is expected to point at Octant v2-compatible vaults.
