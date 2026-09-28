Sync the bifrost datasheet's `opencode/` entries with what the opencode zen go tier serves. You run unattended: never ask questions or wait for confirmation.

## Scope

Edit only these, under `kubernetes/apps/ai/bifrost/app/config/`:

- `models.json` and `pricing.json`: the `opencode/` keys. Both files must keep identical key sets.
- `providers.yaml`: the `opencode` key's `models` allowlist, which must match those keys.

Leave edits in the working tree; don't commit, push or call the forge. When nothing needs changing, change nothing.

## Candidates

`/tmp/catalog.txt` lists every served id and `/tmp/probes.jsonl` holds `{id, status, error}` from a real completion per id. They are your only source of ids.

- Served and not a key in `models.json` under any provider: a candidate.
- An `opencode/` key no longer served: remove it, unless `governance.yaml` names it.

Skip a candidate that is:

- superseded by a newer generation of the same line
- unreleased: `-preview`, `-exp`, `-alpha` and the like, whatever the vendor
- anonymous: undisclosed vendor or joke description
- free: `-free` or `-contributor`
- a bare alias with no version
- not a chat model
- not probed `200`

Size tiers (`flash`, `mini`) are not a reason to skip. A failed probe never justifies removing an existing entry.

## Facts

Every number comes from models.dev's go tier, never from recall or inference:

```
curl -sL https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/opencode-go/models/<id>.toml
curl -s https://models.dev/api.json   # ."opencode-go".models
```

`providers/opencode/` is another tier with other prices; never use it. Costs there are per million tokens, these files per token (`0.15` becomes `0.00000015`). Omit a field the rate card lacks.

Reprice every existing `opencode/` entry, not only new ones: an expired promo fails silently.

Add a model only when its TOML has `[interleaved] field = "reasoning_content"`. A missing marker is not evidence either way, so never move or drop a carried model over it.

## Pull request body

Write `/tmp/model-sync.md` in exactly this form. No preamble, sources, rationale or checks:

```
| | Model | Context / output | $/M in / out / cache |
|---|---|---|---|
| added | <id> | <context> / <output> | <in> / <out> / <cache> |
| repriced | <id> | | <old> → <new> |
| removed | <id> | | |

Skipped: `<id>` <reason> · `<id>` <reason>
```

Reasons are one or two words (unreleased, free, gated, no 200). Add a `**Needs you:**` line per item only when a human must act, such as a workspace setting blocking a model or a pinned model no longer served. Mention nothing outside the `opencode/` keys.
