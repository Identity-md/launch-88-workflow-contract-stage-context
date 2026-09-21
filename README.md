# Handle contracts

Handle is a fixed-supply HNDL token and a permissionless annual name registry for Sepolia (chain 11155111). This contribution delivers contracts, tests and ABI exports. The separate manifest contributor produces `launch.json`; independent reviewers inspect source and the manifest before services publish, attest, admit and deploy. Deployment and the later React/Vite website are separate stage responsibilities. No transactions or keys are needed to build this project.

## Build and verification

Requires Foundry and Solidity 0.8.26 installed in the verifier toolchain. All Solidity library sources needed by the tests are vendored as ordinary files under `lib/forge-std` (upstream v1.9.7, MIT/Apache-2.0). There are no submodules or package-install steps. Production contracts have no library dependencies. FFI and filesystem cheatcode permissions are not enabled. Compiler metadata is disabled, including `bytecode_hash = "none"`.

```sh
forge build --offline
forge test --offline
forge fmt --check
forge inspect src/Handle.sol:Handle abi --json > docs/abi/Handle.json
forge inspect src/NameRegistry.sol:NameRegistry abi --json > docs/abi/NameRegistry.json
```

Tests cover ERC-20 transfers/allowances, supply, invalid inputs, authorization, exact expiry, registration and renewal payment rollback, snapshot timing and batching, duplicate claims, transfer eligibility, pool conservation, rounding, carryover, malicious-token callbacks and failed payouts. Fuzz tests check transfer and pool conservation. These checks are not an independent security audit.

## Deployment parameters

| Contract | Constructor | Configuration |
| --- | --- | --- |
| `src/Handle.sol:Handle` | none, nonpayable | Handle / HNDL, 18 decimals, exactly 10^27 minor units minted to deploying factory |
| `src/NameRegistry.sol:NameRegistry` | `address token_`, nonpayable | `$token`, the deployed Handle address; no other arguments |

Deploy in that order through ProjectFactory. Registry construction checks that the token has code and never moves supply. Neither contract has an owner, privileged beneficiary, mint function after construction, upgrade path, pause administrator or rescue function. No constructor assumes the factory is an exercisable owner. No application calls anything except its immutable token. There is no native ETH entry point. The deployment timestamp establishes the registry's first annual distribution deadline.

The separate manifest should identify `Handle` as the launch token and `NameRegistry` as the application using `$token`. Admission policy and signed artifact linkage belong to services. If a pool is specified by that stage, the supplied guidance is native ETH (zero address), fee 3000, tickSpacing 60, initialPrice `79228162514264337593543950336`, no hook. This is configuration, not a valuation. No wallet address is hard-coded. Services resolve final factory and deployed addresses and publish the runtime configuration and ABIs for the later website.

## Lease rules and assumptions

- Names are exactly 3–32 ASCII letters `a` through `z`. Digits, punctuation, spaces, uppercase and Unicode are rejected. `nameId` validates and returns keccak256 of the bytes.
- `register(name)` takes exactly **100 HNDL** (`FEE = 100e18`) using `transferFrom` and leases for **365 days** from the transaction timestamp. The numerical fee was unspecified in the workflow; 100 HNDL is the immutable implementation choice. “No fee” in the workflow is interpreted as no additional protocol/admin fee, since the workflow explicitly requires a fixed HNDL registration fee into the pool.
- The caller approves at least FEE first. Excess allowance is not a payment. Insufficient allowance or balance reverts the entire operation. Fee-on-transfer behavior is rejected by exact balance checks.
- A name is active strictly before `expiresAt`. At the exact expiry timestamp anyone can register it again, including the former holder. There is no grace period, reservation, auction or refund for unused lease time.
- Only the current holder of a live name can `renew(name)`, paying the same FEE to append one year to its existing expiry. Repeated prepaid renewal is allowed. Expired leases must use `register`.
- Only the current holder can `transferName(name, to)`. The recipient must be nonzero and different from the caller. Expiry is preserved. There are no operator approvals or tokenized name NFTs.
- Registration is first-come-first-served in transaction order. Public registrations can be front-run. Address-based equal shares do not imply one share per human: multiple funded addresses can each register names. No Sybil resistance is promised.

## Annual fee distribution

Equality requires a fixed denominator and budget; dividing a live balance by the live holder count on each claim would favor early claimants. This implementation uses permissionless annual snapshots:

1. The first `startRound()` is allowed at deployment plus YEAR; later rounds are allowed at the previous start timestamp plus YEAR. Missed years are not replayed. Anyone can call it. It freezes `snapshotAt` and `snapshotPool = poolBalance`, supersedes old claim rights and starts a new round.
2. Anyone calls `processSnapshot(count)` with 1–200 until all historical name IDs have been examined. Registrations, renewals, transfers, claims and another round start revert during this process. Names active at the frozen timestamp contribute their holder address, deduplicated across all their names. Processing order and wall-clock time do not change membership.
3. Completion fixes `share = floor(snapshotPool / holderCount)`; zero holders means zero share and no payable claims. Name operations resume. New fees collected after the snapshot are saved for a later round and do not change this share.
4. `claim(heldName)` pays one share to the caller if they were a snapshot holder, have not claimed this round, and currently own the supplied active name. Holding multiple names yields only one share. The proof name need not be the same name held at snapshot time. Eligibility stays with the snapshot address, never with a transferred name. A new recipient waits until a future snapshot unless independently eligible already. A holder who loses all live names can regain a live name and claim if their snapshot entitlement still exists.
5. Claim effects precede token calls; every mutating entry point has a reentrancy guard. Failed or inexact payout reverts both accounting and claimed status, allowing retry. Sum of successful payouts cannot exceed the frozen budget. Rounding dust and unclaimed funds stay in `poolBalance` for the next round. Successful claims subtract only their fixed share.

A round remains claimable until the next snapshot starts, even if its scheduled anniversary has passed. There is no guaranteed minimum claim window if snapshot processing itself takes a year. Initial registrations made exactly at deployment expire at the first boundary unless renewed. Holders should renew ahead of time. Direct token donations do not increase the accounted fee pool and cannot be rescued; send fees only via registration/renewal.

## Operations and availability

There is no automatic annual transaction. Users, the later frontend or a permissionless keeper must start rounds and complete batches. Processing each call is bounded, but total work grows with all unique names ever registered, including expired names. An attacker can pay to grow this history. Snapshot processing temporarily freezes name operations, has no cancellation or timeout, and requires gas-funded callers to complete it; no single caller is required or trusted. This is an explicit availability tradeoff for exact distinct-holder snapshots without an unbounded single transaction. A stalled snapshot does not extend leases. Monitor `snapshotting`, `snapshotCursor`, `nameCount`, and `nextRoundAt`; expose permissionless progress in the later UI. Independent review must assess this tradeoff and Sybil economics before release.

Only the actual Handle token is supported for deployment. Constructor code presence cannot prove ERC-20 honesty; a malicious token can lie about balances or permanently refuse payments. Adversarial tests demonstrate rollback and callback protection, not compatibility with arbitrary tokens. Seconds-level timestamp variation may affect boundary transactions; no randomness is used.

## ABI and frontend integration

Canonical JSON ABI arrays are exported at `docs/abi/Handle.json` and `docs/abi/NameRegistry.json`. A later frontend should consume the service-produced `dist/imd-deployment.json` including addresses, chain and ABIs, rather than assuming this document contains deployment addresses.

| User action | Calls/read model |
| --- | --- |
| Search | `nameId(name)`, then `names(id)`; active iff `expiresAt > latest block timestamp` |
| Register / renew | HNDL `allowance` / `approve`, then `register` or `renew`; read `FEE` |
| Transfer | `transferName(name, recipient)` |
| My names | Index `Registered` and `NameTransferred`; reconcile `names(id)` and expiry; `nameIds(index)` and `nameCount()` allow paginated ID enumeration |
| Distribution progress | `nextRoundAt`, `snapshotting`, `snapshotCursor`, `holderCount`; `startRound`, `processSnapshot` |
| Claim | `round`, `eligibleRound(address)`, `claimedRound(address)`, `share`; then `claim` with a currently live held name |

`Registered` includes the original validated string, holder and expiry. `Renewed`, `NameTransferred`, `RoundStarted`, `SnapshotProgress`, `RoundReady` and `Claimed` expose lifecycle changes. Passive expiry happens with time and emits no transaction event. Token balance and allowance changes emit ERC-20 events. Custom ABI errors explain invalid names, availability, authorization, snapshot state, eligibility and token payment failures.
