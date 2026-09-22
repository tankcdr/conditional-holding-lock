# Adoption evidence

Adoptions of the conditional lock packages outside this repository, and the reference deployments
run from inside it. This is the evidence the CIP thread asks for: the open question in front of the
community is whether anyone would adopt an out-of-tree package before Splice merges it, and a
registry, an application, or a wallet that did is the concrete answer.

**The reference deployment does not satisfy the "adoption outside this repository" criterion.** The
first row below is our own, run from this repository against a local participant. It exists so the
table opens with a worked example rather than an empty header, and so the columns are demonstrated
rather than described. It is not an adoption. Do not mark the distribution epic complete on it.

## How to add a row

Open a pull request against this file, or comment on
[issue #18](https://github.com/tankcdr/conditional-holding-lock/issues/18) and we will add it. The
issue is the low-friction intake; this file is the record, because the CIP needs a citable URL that
is versioned, reviewable, and diffable.

Every row records the **release tag** and the **interface package ID**. Both are required, and the
reason is in the next section. "Adopter" may be an organization or an individual. "What was done" is
one sentence in plain language, written to be quotable as-is in the CIP thread. "Link or update IDs"
is a pull request, a commit, a demo recording, a blog post, or a generated evidence file.

## The table

| Date | Adopter | What was done | Network | Release tag | Interface package ID | Link or update IDs |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-22 | Long Run Advisory (this repository) | Escrowed DvP with a dispute window: the `settle` path enacted jointly by both counterparties before the deadline, and the arbiter's `award` path after it, from one set of `LockTerms` — two conditions, two outcomes, one pool of funds. Run under wall-clock time, not the static time the rest of the proof suite uses. | LocalNet (isolated Canton 3.5.17 sandbox, the Testnet runtime) | `unreleased` | `cc541d14181e265667ea06c6e738e2415881ec49f849474da63319fcfb10d5ac` | [localnet-reference-evidence.json](runbook/localnet-reference-evidence.json) — contract IDs for both paths; see "Update IDs" below |
| — | — | *pending a participant* | DevNet | — | — | — |

The exact git commit, DAR digests, package IDs, and enactment timestamps for any reference-deployment row are in the linked evidence file, not transcribed into the table; the evidence file also records the deadline and the time each path was enacted, which lets a reader confirm the settle path ran before the deadline and the arbiter's award path after it, under wall-clock time.

The DevNet row is deliberately empty. The path is built and parameterized; to run it against a real participant, set all of these:

```bash
LEDGER_JSON_API=https://<participant>/api/json \
LEDGER_HOST=<participant-host> LEDGER_PORT=<port> \
LEDGER_TOKEN=<oauth2-token> \
./scripts/devnet-reference.sh --network devnet --release v0.1.0
```

The `v0.1.0` tag does not exist yet; use that form once the release is tagged. No DevNet participant was available when this was written. Standing one up is validator onboarding, which is its own exercise and out of proportion to one log row. The LocalNet row proves the mechanics; the DevNet row will prove the network.

## What you do not need

**No Canton Coin, and no network funds, for the assets being locked.** The reference deployment
locks holdings issued by a `TestTokenV2` registry, which mints its own. This is a material lowering
of the barrier: "run an escrowed trade on DevNet" sounds like it needs funding, and it does not.

This is also a boundary worth stating precisely, because blurring it would misrepresent the work.
These packages target **non-Amulet registries**. Canton Coin follows Splice's own track, because
Amulet changes land through Splice and the CIP process on the maintainers' schedule. Nothing in this
log involves Amulet. Traffic and fees for submitting to a real synchronizer are a validator-level
concern, not a per-script one.

## Update IDs, and why the rows carry contract IDs instead

Daml Script returns choice results, not ledger update IDs; `submit` gives no handle on the update.
The LocalNet run therefore records the **contract IDs** the script itself returned — the lock
contract for each path and the holdings each enactment produced — and its `update_id_source` field
says so in as many words. A contract ID is equally citable and proves the same thing: a real Ledger
API accepted the transaction and created the contract. Update IDs would come from the participant's
`/v2/updates` stream and can be added to a later row without changing the schema.

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
