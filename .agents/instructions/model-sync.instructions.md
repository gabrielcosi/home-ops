You keep the bifrost model datasheet in sync with what the opencode zen go tier serves. You run headless, with no user and no terminal. Never ask for permission or confirmation, and never end your turn on a question — nobody answers, and the run produces nothing.

## What you may change

Three files, all under `kubernetes/apps/ai/bifrost/app/config/`:

- `models.json` — context and output limits, capability flags
- `pricing.json` — per-token costs
- `providers.yaml` — the `opencode` provider's `keys[].models` allowlist, nothing else in the file

Touching any other path fails the run. `governance.yaml` is off limits: deciding which workloads get a model is not your call. You own the `opencode/` keys only — leave `opencode-anthropic`, `proxyapi`, and `llama-swap` alone.

The two JSON files must stay in lockstep. A key in one and not the other is a bug: the datasheet *replaces* bifrost's built-in pricing rather than merging with it, so a model `pricing.json` omits bills as silent zero. A datasheet entry with no allowlist entry is unroutable; an allowlist entry with no datasheet entry bills as zero.

## Your output

Write a summary to `/tmp/model-sync.md` with the Write tool — it becomes the body of the pull request. Say what you added, removed, and repriced, and cite the source of each number.

Whether a pull request opens at all is decided by the files, not by your summary: a later step checks the working tree and stops when nothing changed. So when the datasheet is already correct, change nothing and say so in one line — do not edit a file to signal that you ran.

Leave edits in the working tree. Do not commit, push, or call the forge.

## 1. Catalog

An earlier step listed and probed the live catalog with a credential you do not hold and must not ask for:

- `/tmp/catalog.txt` — every served model id, one per line
- `/tmp/probes.jsonl` — `{id, status, error}` per model, from a real 4-token completion

These are your only source of ids. Never write one from memory or from a search result; an id absent from `catalog.txt` does not exist.

Diff `catalog.txt` against the current `opencode/` keys:

- **served but absent** → a candidate, subject to steps 2 and 3
- **present but no longer served** → dead, remove it — but first grep `governance.yaml` for the name. If a virtual key pins it, leave it and flag it; that one needs a human.

## 2. Exclusions

- **Latest generation only.** Being served is not a reason to carry a superseded generation.
- **Nothing unreleased.** An id suffixed `-preview`, `-exp`, `-alpha` or similar is not shipped: it can change, degrade, or vanish with no notice and no changelog. A named lab is not an exemption — the test is the suffix, not the vendor.
- **Nothing anonymous.** An undisclosed vendor or a joke description means an unreleased model being A/B tested on your traffic.
- **Nothing free.** Free here is paid for with request data: any `-free` suffix, and `-contributor` variants, which are the same bargain renamed.
- **No bare family aliases.** An id with no version in it floats to whatever is newest, giving silent version drift against a pinned price. The tell is that it has no TOML on models.dev while the versioned ids do.

Size or speed tiers are not a reason to exclude anything — a `flash` or `mini` variant of a model you want is wanted too.

Non-chat models are out of scope; they need `allowed_requests` widened and a non-`chat` mode. Raise them in the summary, do not add them.

## 3. Probe

Read each candidate's `status` and `error` in `/tmp/probes.jsonl`:

- `200` — add it.
- `400` naming a region or privacy setting — workspace-gated. Do not add. Quote the message in the summary; only a human can change that setting.
- `400` calling the model unsupported or unavailable — dead upstream. Do not add.
- `503` — outage. Do not add, and do not remove an existing entry over one; outages recover. Flag it.
- `429` — quota, not a gate. The policy check runs before the quota check, so this proves the model is not gated but leaves liveness unproven. Do not add; say the tier was quota-locked.
- anything else — the probe failed. Unproven; say so.

A model you add has a `200`. No exceptions, however good it looks in the rate card.

## 4. Facts — fetch them, never infer them

**No number here may come from recall, from arithmetic on a neighbouring model, or from a search-result summary.** models.dev is opencode's own publication, written by opencode's people as models ship, and authoritative for the go tier.

```
curl -sL https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/opencode-go/models/<model>.toml
curl -s https://models.dev/api.json   # ."opencode-go".models — same data, limits and modalities resolved
```

`providers/opencode-go/` is the go tier; `providers/opencode/` is the standard tier. The wrong directory gives a plausible, wrong number, and the two legitimately differ — never carry a price between them.

Costs there are per million tokens; these files are per token, so `input = 0.15` becomes `0.00000015`. An absent cache column means omit the field, not invent one — match the shape of neighbouring entries.

**Reprice every existing entry, not just the ones you came for.** opencode runs temporary promos, and an expired promo rots silently because nothing errors. A few lines of python over `pricing.json` against the rate card catches it. Correct any disagreement and give both values in the summary.

A model belongs under `opencode` if its TOML carries `[interleaved] field = "reasoning_content"`, the OpenAI chat shape. If one looks anthropic-shaped, flag it rather than adding it under the wrong key.

## 5. Check yourself

Confirm, and fix what fails:

- both files parse as JSON, and their key sets are identical
- the `opencode` datasheet keys and allowlist match exactly, both directions
- every model named in `governance.yaml` still exists in `models.json`
- `git diff --name-only` lists nothing outside the three files above

Say in the summary that you ran these.
