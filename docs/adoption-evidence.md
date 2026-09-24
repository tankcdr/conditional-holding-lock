# Adoption evidence

Adoptions of the conditional lock packages outside this repository, and the reference deployments
run from inside it. This is the evidence the CIP thread asks for: the open question in front of the
community is whether anyone would adopt an out-of-tree package before Splice merges it, and a
registry, an application, or a wallet that did is the concrete answer.

**The reference deployment does not satisfy the "adoption outside this repository" criterion.** The
first row below is our own, run from this repository against a local participant. It exists so the
table opens with a worked example rather than an empty header, and so the columns are demonstrated
rather than described. It is not an adoption.

## How to add a row

Open an issue with the [use-case template](https://github.com/tankcdr/conditional-holding-lock/issues/new?template=use-case.yml), or a pull request against this file adding a row, and we will add it. The
issue is the low-friction intake; this file is the record, because the CIP needs a citable URL that
is versioned, reviewable, and diffable.

Every row records the **release tag** and the **interface package ID**. Both are required, and the
reason is in the next section. "Adopter" may be an organization or an individual. "What was done" is
one sentence in plain language, written to be quotable as-is in the CIP thread. "Link or update IDs"
is a pull request, a commit, a demo recording, a blog post, or a generated evidence file.

## The table

| Date | Adopter | What was done | Network | Release tag | Interface package ID | Link or update IDs |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-24 | Long Run Advisory (this repository) | The escrowed DvP with a dispute window, run on the Splice LocalNet stack at the release Canton Mainnet is running: a real participant behind a real synchronizer, with the Ledger API's authentication on, rather than an in-process sandbox. The `settle` path enacted 43 seconds before the deadline and the arbiter's `award` path 14 seconds after it. | LocalNet (Splice 0.8.0 / Canton 3.5.16, the Mainnet configuration) | `v0.2.0` | `ff9cd0184bcd2f3a88b0c8c1c74bcff94e49c7ff00c04e144b33f26f7266811e` | [localnet-mainnet-0.8.0-reference-evidence.json](runbook/localnet-mainnet-0.8.0-reference-evidence.json) — contract IDs for both paths; see "Update IDs" below |
| 2026-09-24 | Long Run Advisory (this repository) | CIP-0112 DvP between registries, against **real Canton Coin**. The seller's TestTokenV2 holding is locked under the conditional lock as the delivery leg; the buyer pays real Amulet as the payment leg, allocated on both sides through the token standard and settled through Splice's own `ExternalPartyAmuletRules` settlement factory. One submission, two commands, one update: `SettlementFactory_SettleBatch` and `ConditionalLock_Enact` are the two root nodes of the same transaction. The buyer is hosted on a second participant. A second lock proves the expiry path under wall-clock time. | LocalNet (Splice 0.8.0 / Canton 3.5.16, the Mainnet configuration; two participants) | `v0.2.0` | `ff9cd0184bcd2f3a88b0c8c1c74bcff94e49c7ff00c04e144b33f26f7266811e` | [localnet-mainnet-0.8.0-dvp-evidence.json](runbook/localnet-mainnet-0.8.0-dvp-evidence.json) — settlement update `12206db472f6198f90c90c69d17df77971b5b040086da096cd6d8233abf566312928`, expiry update `12203380d71d1935e21c29cc626def57488505e57405b687a0f920ef7bb277634449` |
| — | — | *pending a participant* | DevNet | — | — | — |

The exact git commit, DAR digests, and enactment timestamps for any reference-deployment row are in the linked evidence file, not transcribed into the table; the evidence file also records the deadline and the time each path was enacted, which lets a reader confirm the settle path ran before the deadline and the arbiter's award path after it, under wall-clock time. The interface package ID is the one value the table does carry, for the reason given above.

The DevNet row is deliberately empty. The path is built and parameterized; to run it against a real participant, set the first three of these, and the token only if the participant requires authentication:

```bash
LEDGER_JSON_API=https://<participant>/api/json \
LEDGER_HOST=<participant-host> LEDGER_PORT=<port> \
LEDGER_TOKEN=<oauth2-token> \
./scripts/devnet-reference.sh --network devnet --release v0.1.0
```

`v0.1.0` is tagged and released; the command above uses it as written. No DevNet participant was available when this was written. Standing one up is validator onboarding, which is its own exercise and out of proportion to one log row. The LocalNet row proves the mechanics; the DevNet row will prove the network.

## What you do not need

**No Canton Coin, and no network funds, for the assets being locked.** The reference deployment
and the DvP integration test both lock holdings issued by a `TestTokenV2` registry, which mints
its own. This is a material lowering of the barrier: "run an escrowed trade" sounds like it needs
funding, and the locked asset does not. The DvP test does settle a real Amulet payment leg
atomically against the locked TestTokenV2 delivery leg in a single transaction, but Amulet is
the counter-asset for settlement, not the thing being conditionally locked. That distinction
matters: the locked asset (TestTokenV2) follows the non-Amulet registry track, while settlement
with Amulet is a choice of payment method.

This is also a boundary worth stating precisely, because blurring it would misrepresent the work.
These packages target **non-Amulet registries** for the locked assets. Canton Coin follows Splice's
own track, because Amulet changes land through Splice and the CIP process on the maintainers'
schedule. The payment leg settles through Splice's own `SettlementFactory` and allocation standard.
Traffic and fees for submitting to a real synchronizer are a validator-level concern, not a
per-script one.

## Update IDs, and why the rows carry contract IDs instead

Daml Script returns choice results, not ledger update IDs; `submit` gives no handle on the update.
The LocalNet runs using Daml Script therefore record the **contract IDs** the script itself returned —
the lock contract for each path and the holdings each enactment produced — and their `update_id_source`
field says so in as many words. A contract ID is equally citable and proves the same thing: a real
Ledger API accepted the transaction and created the contract. The DvP integration test is different:
it drives the JSON Ledger API v2 directly with `submit-and-wait-for-transaction`, so it captures a
real `updateId` — a single update carrying both the Amulet settlement and the lock enactment — alongside
the contract IDs. Update IDs would come from a participant's `/v2/updates` stream and the schema
accommodates them without change.

## What survives a network reset

DevNet is periodically reset. When it is, contract IDs and update IDs stop resolving, and a row whose
only content is a dead link is worse than no row at all.

That is why the tag and the interface package ID are mandatory columns rather than nice-to-haves.
**Treat the ledger identifiers as supporting detail, not as the claim.** The date, the adopter, the
release tag, the interface package ID, and the description stay true after any reset. A reader who
finds a contract ID that no longer resolves can still tell exactly which interface was adopted, at
which release, by whom, and what it did.

The package ID matters for a second reason. A Daml-LF package ID is a content hash; there is no
in-place amendment and no migration. While the interface issues are open, every interface change
produces a new package ID and invalidates every adopter's pin. This log is therefore also the
re-pin notification list: the rows say who needs telling when the interface moves.

## Related

- [`adoption.md`](adoption.md) — the consumer adoption guide. It takes a registry, an application, or
  a wallet from an empty project to a working conditional lock against the released DARs; section 8
  links here.
- [`runbook/conditional-lock-validation.md`](runbook/conditional-lock-validation.md) — the local
  proof suite, run on both pinned Canton runtimes under static time. A different and complementary
  claim to the reference deployment above.
- The Splice pull request, <https://github.com/canton-network/splice/pull/7294>, where the interface
  is proposed and the CIP discussion lives. Adoption reports belong there too.
