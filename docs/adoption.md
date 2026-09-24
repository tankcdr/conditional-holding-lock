# Adopting the conditional lock DARs

This document takes a registry, an application, or a wallet from an empty project to a working
conditional lock against the released DARs, without waiting for Splice to merge the interface into
its tree.

**Read this first.** This is a `0.x` release of a strawman for a CIP that is still under review.
The interface issues are open, and every interface change changes the interface package ID. A
package ID is a content hash; there is no in-place amendment and no migration. Adopting these DARs
means expecting to re-pin. Section 7 says exactly what that costs and what it does not.

**Scope.** The attached DARs are for non-Amulet registries. Canton Coin support follows Splice's
own track, because Amulet changes land through Splice and the CIP process on the maintainers'
schedule. Nothing here targets Amulet.

The normative source is [CIP-TBD-Conditional-Holding-Lock](cip/CIP-TBD-Conditional-Holding-Lock.md).
Where this document cites the CIP it cites a numbered section (3.1 through 3.9) or, for the
unnumbered parts, a section title such as "Security Considerations".

Contents:

1. [What you are depending on](#1-what-you-are-depending-on)
2. [Get the DARs](#2-get-the-dars)
3. [Registry: implement the interfaces](#3-registry-implement-the-interfaces)
4. [Application: read and enact locks](#4-application-read-and-enact-locks)
5. [Wallet: display and drive locks](#5-wallet-display-and-drive-locks)
6. [Run it on a local ledger](#6-run-it-on-a-local-ledger)
7. [Compatibility, and what changes when Splice merges](#7-compatibility-and-what-changes-when-splice-merges)
8. [Reporting adoption](#8-reporting-adoption)

Release mechanics — what is tagged, what is attached, how the manifest is generated, and the
versioning rule — are **not** repeated here. They live in [CHANGELOG.md](../CHANGELOG.md) and
[docs/release-notes/v0.1.0.md](release-notes/v0.1.0.md), and nowhere else.

---

## 1. What you are depending on

Four first-party Daml packages are built from this repository. Three are attached to the release.

| Package | Take it if | Its own `data-dependencies` |
| --- | --- | --- |
| `splice-api-token-conditional-lock-v1` | always | `splice-api-token-metadata-v1`, `splice-api-token-holding-v2` |
| `conditional-lock-utils` | you are a registry, or you want to validate terms client-side | the interface, plus the same two |
| `conditional-lock-test-token` | you want a worked reference implementation to read | the above plus `holding-v1`, `transfer-events-v2`, `splice-test-token-v2`, `splice-token-standard-utils` |
| `conditional-lock-test` | never | the other three, the Splice DARs they need, plus `daml-script` |

Two warnings that matter more than the table:

- **`conditional-lock-test-token` is reference material over a *test* issuer.** It adapts Splice's
  published `Splice.Testing.Tokens.TestTokenV2` package. It is there to be read, and to make the
  quickstart in section 6 runnable end to end. It is not a production dependency, and a production
  registry replaces it with an adapter over its own token package.
- **`conditional-lock-test` must never appear in a consumer's `data-dependencies`.** It is the
  94-script proof suite, it depends on `daml-script`, and it compiles with
  `-Wno-template-interface-depends-on-daml-script`. It is deliberately not attached to the release,
  and it is recorded in the release manifest with `"attached": false` so its absence is a decision
  rather than an oversight.

The interface package ID, the one your contracts and your `data-dependencies` resolve against, is:

```
splice-api-token-conditional-lock-v1  cc541d14181e265667ea06c6e738e2415881ec49f849474da63319fcfb10d5ac
```

That value is checked on every build by `scripts/verify-reproducible.sh`. The IDs of the other
three packages are not transcribed here, because a transcribed hash goes stale silently; read them
from the release manifest instead, which is generated from the built DARs:

```bash
jq -r '.packages[] | "\(.package_id)  \(.file)"' conditional-lock-release.json
```

**A DAR's SHA-256 is download integrity; the package ID is package identity. Neither implies the
other.** The same compiled package can ship as two DAR files with different digests — zip entry
order, timestamps, and compiler interface files vary between builds. Pin, and reason about
compatibility, using package IDs. Section 7 gives the worked example. This is the same distinction
the [release notes](release-notes/v0.1.0.md) make, in the same words, and it is the single fact
that determines whether your integration survives a rebuild.

The DAR **filenames** carry the release version from `v0.2.0` on; `v0.1.0` predates that rule and
ships `*-1.0.0.dar`, which the commands below use. The reasons are in [CHANGELOG.md](../CHANGELOG.md)
under "Versioning rule".

---

## 2. Get the DARs

Daml `data-dependencies` are **file paths, not coordinates**. There is no registry to resolve a name
from, so you download the DARs and reference them locally. Splice gives its own consumers the same
advice: copy the token-standard DARs from the Splice repository and check them into your own repo.
That has a real cost — you carry binaries in git and re-commit on every re-pin — but it is what makes
your build reproducible, and the manifest below makes the re-pin mechanical.

```bash
mkdir -p dars

# 1. The three first-party DARs and the manifest, from the GitHub Release.
gh release download v0.1.0 --repo tankcdr/conditional-holding-lock \
  --pattern '*.dar' --dir dars/
gh release download v0.1.0 --repo tankcdr/conditional-holding-lock \
  --pattern 'conditional-lock-release.json' --dir .

# 2. The six Splice DARs the release was built against, from the pinned Splice release tag.
#    Splice tags on canton-network/splice are unprefixed; only that form resolves on raw.
for f in splice-api-token-metadata-v1-1.0.0.dar \
         splice-api-token-holding-v1-1.0.0.dar \
         splice-api-token-holding-v2-1.0.0.dar \
         splice-api-token-transfer-events-v2-1.0.0.dar \
         splice-test-token-v2-1.0.1.dar \
         splice-token-standard-utils-2.0.0.dar; do
  curl -fsSL "https://raw.githubusercontent.com/canton-network/splice/0.8.1/daml/dars/$f" \
    -o "dars/$f"
done
```

Fetch all six even though an application compiles against only `metadata-v1` and `holding-v2`: the
verification step below checks the whole pinned dependency set, and a registry reading the reference
adapter needs the rest. This repository automates exactly that fetch — see
[`scripts/fetch-dars.sh`](../scripts/fetch-dars.sh), whose second line states the principle
(`Fetch immutable, checksum-verified published DARs; never vendor Splice source`) and
[`scripts/fetch-dars.py`](../scripts/fetch-dars.py), which builds the URL, checks the SHA-256, and
then checks the package ID out of `META-INF/MANIFEST.MF`. [`SPLICE_PIN`](../SPLICE_PIN) is the
manifest it reads.

**Verify what you downloaded.** Every expected digest and package ID for both halves of the
dependency set is in `conditional-lock-release.json`. The first-party entries record the digest as
`dar_sha256` and the Splice entries as `sha256`, so a single expected-digest listing reads both:

```bash
jq -r '(.packages[] | select(.attached) | "\(.dar_sha256)  dars/\(.file)"),
       (.splice_dependencies[] | "\(.sha256)  dars/\(.file)")' \
  conditional-lock-release.json > expected.sha256
shasum -a 256 -c expected.sha256
```

The `select(.attached)` matters: the manifest also records `conditional-lock-test`, which is not a
release asset and which you will not have downloaded. Without the filter the check reports it as a
missing file and exits non-zero.

This check is for **downloaded release assets**. Do not run it against DARs you built yourself: the
package IDs reproduce, the file digests need not. The identity check that does hold for any build is
the package ID:

```bash
dpm inspect-dar --json dars/splice-api-token-conditional-lock-v1-1.0.0.dar \
  | jq -r .main_package_id
# -> cc541d14181e265667ea06c6e738e2415881ec49f849474da63319fcfb10d5ac
```

---

## 3. Registry: implement the interfaces

### 3.1 The project file

A registry implements the three interfaces of CIP sections 3.1, 3.2, and 3.3 over its own token
package. The closest real file in this repository is
[`packages/conditional-lock-test-token/daml.yaml`](../packages/conditional-lock-test-token/daml.yaml),
and the snippet below is that file with the sibling-build paths rewritten to the `dars/` directory
of section 2 and the test issuer commented as the line you replace:

```yaml
sdk-version: 3.5.2
name: my-registry
version: 1.0.0
source: daml
dependencies:
- daml-prim
- daml-stdlib
data-dependencies:
# Splice token standard, from Splice release 0.8.1
- dars/splice-api-token-metadata-v1-1.0.0.dar
- dars/splice-api-token-holding-v1-1.0.0.dar
- dars/splice-api-token-holding-v2-1.0.0.dar
- dars/splice-api-token-transfer-events-v2-1.0.0.dar
# Your own token package replaces the next line. The reference adapter uses Splice's TEST issuer:
- dars/splice-test-token-v2-1.0.1.dar
- dars/splice-token-standard-utils-2.0.0.dar
# Conditional lock, from release v0.1.0
- dars/splice-api-token-conditional-lock-v1-1.0.0.dar
- dars/conditional-lock-utils-1.0.0.dar
build-options:
- --explicit-serializable=yes
- --target=2.1
```

`sdk-version: 3.5.2`, `--target=2.1`, and `--explicit-serializable=yes` are not style. They are
inputs to the package identity your ledger checks, and they are identical in all four
`packages/*/daml.yaml` files in this repository and in the Splice-branch copy of the interface
package. If yours differ, you are compiling against a different package than the one you pinned.

### 3.2 What you do not have to write

`conditional-lock-utils` is the reference policy evaluator, in module `ConditionalLock.Policy`. It
depends only on `metadata-v1`, `holding-v2`, and the interface, so adopting it does not drag the
test issuer into your build. The entry points a registry inherits:

| Function | Signature (from `packages/conditional-lock-utils/daml/ConditionalLock/Policy.daml`) | Use |
| --- | --- | --- |
| `validateTerms` | `Limits -> Party -> LockTerms -> Update ()` (0.1.0: `Limits -> Party -> Time -> LockTerms -> Update ()`) | the CIP section 3.1 terms validation, in one call |
| `satisfied` | `[Party] -> Witness -> [Alternative] -> Update Bool` (0.1.0: `Time -> [Party] -> Witness -> [Alternative] -> Bool`) | guard evaluation, CIP section 3.5; from 0.2.0 given `actingParties` |
| `approve` | `Limits -> LockTerms -> [Approval] -> Text -> [Leg] -> [Party] -> Update [Approval]` | `ConditionalLock_Approve`, CIP section 3.3 (from 0.2.0) |
| `actingParties` | `Text -> [Leg] -> [Party] -> [Approval] -> [Party]` | actors plus recorded approvers for `ConditionalLock_Enact` (from 0.2.0) |
| `resolveOutcome` | `Limits -> LockTerms -> Outcome -> [Leg] -> Update [Leg]` | outcome enactment, CIP section 3.6 |
| `requireActors` | `Text -> [Party] -> [Party] -> Update ()` | the actor check every choice of CIP section 3 requires |
| `lockHolders` | `LockTerms -> [Party]` | the lock holders CIP section 3.4 requires on the backing holding |
| `namedParties` | `LockTerms -> [Party]` | the `max-named-parties` bound of CIP section 3.8 |

This is reference code, not a conformance oracle. A registry MAY evaluate guards differently and
still conform, provided the observable behaviour matches CIP sections 3.5 and 3.6. Depending on this
package is not a conformance claim.

The worked implementation to read alongside it is
[`packages/conditional-lock-test-token/daml/ConditionalLock/TestToken.daml`](../packages/conditional-lock-test-token/daml/ConditionalLock/TestToken.daml).

### 3.3 Limits: the one value you must not copy

CIP section 3.8 requires a registry to advertise `splice-api-token-conditional-lock-v1` in
`supportedApis` of `GET /registry/metadata/v1/instruments/{instrumentId}`, and to advertise eight
limit keys in the factory `meta`. `ConditionalLock.Policy` models them as a single `Limits` record:
`limitsMetadata` renders it into the factory `meta`, `limitsFromMetadata` reads it back, every
validator reads its bound from the same record, and `conformsToCip` checks the CIP's floors. The
advertised value and the enforced value therefore cannot drift apart.

`referenceLimits` is an example profile, not a default:

```
maxRules = 8, maxLegs = 8, maxAlternativesPerRule = 8, maxGuardsPerAlternative = 8,
maxPreimages = 8, maxNamedParties = 8, minDuration = seconds 1, maxDuration = days 365
```

**`minDuration = seconds 1` renders as `PT1S` and is a test issuer's value. Do not ship it.**
CIP section 3.8 says `min-duration` SHOULD reflect the registry's submission delay, and the CIP's
Security Considerations section ("Submission delay") explains why: the delay between preparation and
execution — up to 24 hours on Canton Coin under CIP-0107 — shrinks the enactment window. A registry
that advertises `PT1S` has advertised a guarantee it cannot honour, and its locks can expire inside
its own submission window. Set `minDuration` from your own measured delay before you set anything
else.

Note that `conformsToCip` checks the seven MUST floors and the coherence of `minDuration` with
`maxDuration`. It cannot check `minDuration` against your submission delay, because only you know it.

### 3.4 What the CIP requires of you

A self-assessment list, not a certification. `conditional-lock-utils` is reference code and no
artifact in this repository certifies conformance. Each item cites the CIP section that imposes it.

- [ ] **Validate terms before locking** and fail otherwise, per the requirements stated on
      `ConditionalLockFactory_Lock.terms` (CIP section 3.1). `validateTerms` does this.
- [ ] **Reject `Leg.meta` keys the registry is required to set** (CIP sections 3.1 and 3.7).
- [ ] **Keep named parties within your advertised `max-named-parties`** (CIP sections 3.1 and 3.8).
- [ ] **Return `Pending` with a `ConditionalLockInstruction`** when approvals are outstanding, naming
      `pendingApprovals` and reporting `availableActions` (CIP section 3.1).
- [ ] **Check every choice's `actors`** and ensure no other path moves locked funds (CIP section 3,
      and Security Considerations, "Authorization"). `requireActors` is the call.
- [ ] **Represent locked funds as holdings in `terms.authorizer` summing to `terms.amount`**, with
      `lock.holders` set to the terms' named parties or the admin alone, `expiresAt = Some
      terms.expiresAt`, `expiresAfter = None`, and a short human-readable `context`
      (CIP section 3.4). `lockHolders` computes the holders.
- [ ] **Retain enacted rule ids for the lifetime of the `lockId`**, so a fired rule cannot be
      reinstated (CIP sections 3.3 and 3.5).
- [ ] **Record rule approvals and count them at enactment** (from 0.2.0): `ConditionalLock_Approve` records the
      approving parties per `(ruleId, legs)`, and `ConditionalLock_Enact` counts `actors` together
      with the approvers recorded for its exact `(ruleId, legs)`. Keep approvals of unfired rules
      across continuations, drop a fired rule's, and clear them all on `Amend` (CIP section 3.3).
      `approve`, `actingParties`, `dropApprovals`, and `clearApprovals` do this.
- [ ] **Fail enactment at or after `terms.expiresAt`**, and never fire a rule after expiry
      (CIP section 3.3, and Security Considerations, "Expired locks").
- [ ] **Report every holdings change through the V2 transfer events** (CIP section 3.7).
- [ ] **Advertise `splice-api-token-conditional-lock-v1` in `supportedApis`** and publish all eight
      limit keys in the factory `meta` (CIP section 3.8).
- [ ] **Serve the lock-factory and choice-context endpoints** of CIP section 3.8; see section 5 below
      for the OpenAPI file.
- [ ] **Implement the nine `*ExtraObservers` functions**, each total and non-failing, budgeting one
      view per exercised choice (CIP section 3.9, following CIP-0112 "Guidelines & Interfaces for
      Performance Optimization"). In particular, `conditionalLock_enactExtraObservers` MUST NOT name
      parties beyond the accounts the outcome pays unless the instrument is public, because a
      `Guard_Preimage` enactment reveals the preimage to every informee.

---

## 4. Application: read and enact locks

An application that reads locks and exercises `ConditionalLock_Enact` needs **three**
`data-dependencies`, not one. Daml `data-dependencies` are listed explicitly per package and are not
transitive: the interface's own dependencies do not come along with it. The real file that proves
the minimum is [`packages/conditional-lock-utils/daml.yaml`](../packages/conditional-lock-utils/daml.yaml),
whose `data-dependencies` are exactly these three:

```yaml
data-dependencies:
- dars/splice-api-token-metadata-v1-1.0.0.dar
- dars/splice-api-token-holding-v2-1.0.0.dar
- dars/splice-api-token-conditional-lock-v1-1.0.0.dar
```

with the same `sdk-version: 3.5.2` and the same two `build-options`. Any instruction that says an
application needs "only the interface DAR" produces a build that does not compile.

An optional fourth line adds client-side validation:

```yaml
- dars/conditional-lock-utils-1.0.0.dar
```

`satisfied` answers "would this enactment succeed" against a rule's `anyOf` alternatives before
you submit, which turns a failed submission into a message in your UI. In 0.1.0 it is a pure
function of ledger time; from 0.2.0 it is an `Update` over ledger-time bounds, evaluated in a
dry-run submission and given `actingParties` (the actors plus the approvals recorded in the
lock's view). `limitsFromMetadata` reads a factory's advertised limits back into a
`Limits` record so you can check terms against the registry's bounds before offering them.

For a complete lifecycle to read — lock, approve, enact, assert — see
[`packages/conditional-lock-test/daml/TestWorkedExamples.daml`](../packages/conditional-lock-test/daml/TestWorkedExamples.daml),
whose six named scripts correspond to the six worked examples of CIP section 4. The shortest
complete one is `test_example_htlcLeg`. The smallest self-contained one is the quickstart in
section 6.

---

## 5. Wallet: display and drive locks

A wallet needs three things, and the smallest useful change is smaller than it looks.

**1. The interface DAR for codegen**, plus `metadata-v1` and `holding-v2` as in section 4, to parse
`ConditionalLockView`. TypeScript bindings:

```bash
dpm codegen-js -o daml.js -s @myorg \
  dars/splice-api-token-metadata-v1-1.0.0.dar \
  dars/splice-api-token-holding-v2-1.0.0.dar \
  dars/splice-api-token-conditional-lock-v1-1.0.0.dar
```

(`dpm codegen-js --help` lists `-o/--output-directory`, `-s/--npm-scope`, and `-V/--verbosity`;
there is no `dpm codegen` umbrella command, only `codegen-js` and `codegen-java`.) Java is what the
Splice tree configures for this package: its copy of the interface `daml.yaml` carries a `codegen:`
block with `package-prefix: org.lfdecentralizedtrust.splice.codegen.java` and
`decoderClass: org.lfdecentralizedtrust.splice.codegen.java.DecoderSpliceApiTokenConditionalLockV1`.
If you are aligning with Splice's own bindings, copy that block and use `dpm codegen-java`. A full
codegen example in either language ages badly and is not what blocks adoption; the invocation is.

**2. The OpenAPI file.** CIP section 3.8 requires registries to serve a lock-factory endpoint and
eight choice-context endpoints, and calls `conditional-lock-v1.yaml` part of the reference
implementation. It is in this repository, versioned alongside the interface package it describes:

[`packages/splice-api-token-conditional-lock-v1/openapi/conditional-lock-v1.yaml`](../packages/splice-api-token-conditional-lock-v1/openapi/conditional-lock-v1.yaml)

Nine paths from 0.2.0, eight before (no `approve`): `/registry/conditional-lock/v1/lock-factory`, then
`/registry/conditional-lock/v1/{lockInstructionId}/choice-contexts/{accept,reject,withdraw}` for the
three instruction choices and
`/registry/conditional-lock/v1/{lockContractId}/choice-contexts/{enact,approve,expire,cancel,amend}` for the
five lock choices. Without them a wallet cannot fetch the disclosed contracts a choice needs. The
lock choices are addressed by contract id rather than by `ConditionalLockView.lockId`.

**3. The metadata conventions**, so a lock renders as something other than "unknown". The reference
adapter emits `splice.lfdecentralizedtrust.org/tx-kind = "lock"` with a
`splice.lfdecentralizedtrust.org/reason` alongside it on every lifecycle result
(`resultMetadata` in `ConditionalLock.Policy`), and carries the wallet's
`splice.lfdecentralizedtrust.org/lock-context` text into the holding's lock context as CIP
section 3.4 requires.

The CIP's Backwards Compatibility section is the sentence worth quoting to a wallet author: wallets
that do not implement the package "still display conditionally locked holdings as locked holdings
and fall back to the generic rendering CIP-0056 prescribes for choices outside the standard (`lock`
is a new `tx-kind` value)." So the minimum wallet change is a new `tx-kind` label and a lock-terms
view, not a rewrite.

Two obligations from the CIP's Security Considerations that belong in front of a wallet author
rather than buried:

- **Submission delay.** Wallets MUST allow for the registry's submission delay when choosing
  `expiresAt` and `Guard_Before`. Read the registry's advertised `min-duration` (section 3.3) and
  treat it as a floor on the window you offer, not as a suggestion.
- **Authoring errors.** A rule whose `fixedLegs` exceed the remaining amount can never fire. Wallets
  SHOULD check that every sequence of rule firings stays enactable. `conditional-lock-utils` exists
  precisely so you do not have to reimplement that arithmetic.

---

## 6. Run it on a local ledger

The quickstart goes from downloaded DARs to a lock that is created, approved, enacted, and asserted,
on an isolated single-process Canton sandbox. No Docker, no network funds, no account on anything.

The `dars/` directory section 2 builds has everything the quickstart needs. The quickstart itself
compiles against six of those files — the three first-party DARs plus `metadata-v1`, `holding-v2`,
and `splice-test-token-v2`, because it drives the reference registry over the test issuer. The
authoritative list is the `data-dependencies` of
[`docs/quickstart/daml.yaml`](quickstart/daml.yaml); the script reads that file, checks each entry,
and names any that are missing before it starts a sandbox.

```bash
# Against the DARs you downloaded in section 2:
./scripts/quickstart-check.sh dars/

# Against this repository's own build outputs, which does not need the release assets:
./scripts/quickstart-check.sh
# or
just quickstart
```

The two files the script runs are real files in this repository, not transcriptions:

- [`docs/quickstart/daml.yaml`](quickstart/daml.yaml) — the consumer project. Its
  `data-dependencies` are `dars/`-relative, so it is literally the file you have after following
  section 2. It drives the *reference* registry, so it lists the adapter and the test issuer as well
  as the interface; a production consumer's list is the shorter one in section 4.
- [`docs/quickstart/daml/Quickstart.daml`](quickstart/daml/Quickstart.daml) — one Daml Script:
  allocate parties, create the registry's token rules, mint a holding, create the factory, lock under
  a single `Guard_Parties` rule, have the receiver accept, have the enactor enact, and assert the
  holding moved.

What the script does, and what you would do by hand on your own participant:

1. Start a sandbox on unused loopback ports with static time
   ([`scripts/lib/sandbox.sh`](../scripts/lib/sandbox.sh), shared with
   [`scripts/test-compatibility.sh`](../scripts/test-compatibility.sh), which runs the full proof
   suite the same way).
2. Upload the three consumer DARs **in dependency order** — interface, utils, adapter — to the JSON
   Ledger API's `/v2/packages`. A DAR carries its transitive dalfs, but uploading in order keeps the
   failure legible when one is missing.
3. Build the consumer project and run its script against the Ledger API.

**This topology is not a production network.** A single-process sandbox with `--static-time` is one
participant and one synchronizer with controlled time. `Guard_After` and `Guard_Before` behave very
differently under wall-clock time on a real participant with a submission delay — which is the whole
reason section 3.3 exists. Treat the quickstart as proof that your dependency set is right, not as
proof that your timing is. The next step after it passes is a real network, which
[adoption-evidence.md](adoption-evidence.md) records.

---

## 7. Compatibility, and what changes when Splice merges

**What you are pinning.** A Daml package's identity is its package ID, a content hash over the
compiled package: its name, its version, the Daml-LF version, the package IDs of its dependencies,
and its module contents. Your ledger stores contracts against package IDs, and your
`data-dependencies` resolve to them. The SHA-256 of a `.dar` file is a different thing — it is
download integrity. Two `.dar` files with different SHA-256 digests can contain the same package.
This is not hypothetical: `splice-token-standard-utils-2.0.0.dar` ships from Splice release 0.7.4
with SHA-256 `60cd6851…` and from release 0.8.1 with SHA-256 `3346dedf…`, and both contain package
ID `9a8f41a2b145…`. Two different files, one package. Pin, and reason about compatibility, using
package IDs.

**What will change.** This is a `0.x` release, and the interface issues are open. Every one of them
that lands changes the interface package ID. When that happens you must re-pin and re-upload; there
is no in-place migration, because the ledger's contracts reference the old ID. The changelog names
which package IDs changed in each release, so a release that only touches the adapter costs you
nothing. Re-pinning is the expected cost of adopting before the CIP is Final, and it is the cost
this document is asking you to accept knowingly.

**What happens when Splice merges the interface.** If Splice builds
`splice-api-token-conditional-lock-v1` from the same source, with the same package name, the same
version, the same dependency package IDs, and the same compiler flags (`sdk-version: 3.5.2`,
`--target=2.1`, `--explicit-serializable=yes`), the resulting package ID is **identical** to the one
you are already using, and your integration needs no change — the in-tree package and the
out-of-tree package are the same package. If any of those inputs differs, it is a different package
and you re-pin as for any interface change. Splice is under no obligation to match those inputs, so
this is a conditional, not a promise; it is not "when Splice merges, nothing changes". What makes it
checkable rather than a matter of trust is that the release manifest records every one of those
inputs, so the comparison is mechanical.

**What does not depend on which Splice release.** The interface package depends only on
`splice-api-token-metadata-v1` and `splice-api-token-holding-v2`. Both DARs are byte-identical at
Splice releases 0.7.4, 0.8.0, and 0.8.1, so the interface package ID does not vary with which of
those Splice releases it was built against. In fact all six pinned Splice DARs are byte-identical at
0.8.0 and 0.8.1 — the two releases the live networks reference. **One release of these DARs
therefore serves both Mainnet (Splice 0.8.0 reference) and Testnet (Splice 0.8.1 reference); there
is no variant to choose.** The Daml proofs were run through a real Ledger API on local Canton 3.5.16
and 3.5.17 sandboxes, the runtimes those two networks report. The point-in-time network reference is
in [`fixtures/runtime-versions.json`](../fixtures/runtime-versions.json), and `just
check-compatibility` is the live answer; this release has not been run against Mainnet itself.

### A note on how this is distributed

*From general knowledge, not from a local citation — there is no Daml Finance checkout in either
repository, and nothing in this repository verifies the following paragraph:*

> Daml Finance is distributed the same way. Its packages are not part of the Daml SDK or of Canton;
> they are released as versioned artifacts on GitHub Releases, and a consumer downloads them into a
> local directory (conventionally `.lib/`, populated by a `get-dependencies.sh`-style script) and
> lists those files in `data-dependencies`. The pattern — out-of-tree packages, released
> independently, referenced as downloaded files, with the package version and the release tag as the
> coordination point — is the one this repository follows. It is a normal way to ship Daml
> libraries, not a workaround.

---

## 8. Reporting adoption

If you follow this document, the result is evidence the CIP thread needs. The open question in front
of the community is whether anyone would adopt an out-of-tree package before Splice merges it; a
registry, an application, or a wallet that did is the concrete answer.

- **[`adoption-evidence.md`](adoption-evidence.md)** — the adoption evidence log. It records each observed
  adoption: who adopted which packages at which package IDs, on which network, what they built, and
  what broke. The reference deployment on a real network is also recorded here, but does not count
  as adoption outside this repository.
- **The Splice PR** — <https://github.com/canton-network/splice/pull/7294> is where the interface is
  proposed to Splice and where the CIP discussion lives. Adoption reports belong there too.
- **This repository's issues** — <https://github.com/tankcdr/conditional-holding-lock/issues> for
  anything that made this document wrong.

If something here did not work, that is the most useful report of all: the commands in this document
are executed by `scripts/quickstart-check.sh`, and anything it does not cover is a gap.
