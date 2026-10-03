#!/usr/bin/env bash
# model_sync.sh plan: probe opencode zen go and decide the datasheet sync.
# model_sync.sh apply: apply the plan and the judge's decisions, write the PR body.
set -euo pipefail

config=kubernetes/apps/ai/bifrost/app/config
base=https://opencode.ai/zen/go/v1
plan=/tmp/model-sync-plan.json
decisions=/tmp/model-sync-decisions.json
summary="${SUMMARY_FILE:-/tmp/model-sync.md}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

read -r -d '' PLAN_JQ <<'JQ' || true
$catalog[0] as $catalog | $dev[0] as $dev | $sheet[0] as $sheet | $pinned[0] as $pinned |

def per_token: if . == null then null else "\(.)e-6" | tonumber end;

def probe($id): first($probes[] | select(.id == $id)) // {chat: 0, messages: 0, chat_error: "", messages_error: ""};

def status($p; $provider): if $provider == "opencode" then $p.chat else $p.messages end;

def other($provider): if $provider == "opencode" then "opencode-anthropic" else "opencode" end;

# A shape counts as not served only on a definitive rejection, never on a
# timeout, quota, outage or request validation error.
def rejected($status; $error):
  ($status | IN(401, 403, 404, 405)) or ($status == 400 and ($error | test("does not support this protocol"; "i")));

# Where a model answers decides its provider; models.dev breaks a tie. $was is
# the carried provider, or null for a new model.
def provider_of($id; $was):
  probe($id) as $p | $dev[$id] as $m
  | if ($m.provider.npm // "") == "@ai-sdk/openai" then $was
    elif $p.chat == 200 and $p.messages == 200 then
      if $m == null then $was elif $m.provider.npm == "@ai-sdk/anthropic" then "opencode-anthropic" else "opencode" end
    elif $p.chat == 200 and rejected($p.messages; $p.messages_error) then "opencode"
    elif $p.messages == 200 and rejected($p.chat; $p.chat_error) then "opencode-anthropic"
    else $was end;

def row($provider; $id):
  $dev[$id] as $m
  | {provider: $provider, base_model: $id, mode: "chat",
     max_input_tokens: $m.limit.context, max_output_tokens: $m.limit.output,
     architecture: {
       input_modalities: (if ($m.modalities.input | index("image")) then ["text", "image"] else ["text"] end),
       output_modalities: ["text"]},
     supports_function_calling: ($m.tool_call == true),
     supports_tool_choice: ($m.tool_call == true),
     supports_reasoning: ($m.reasoning == true),
     input_cost_per_token: ($m.cost.input | per_token),
     output_cost_per_token: ($m.cost.output | per_token)}
  + if $m.cost.cache_read == null then {} else {cache_read_input_token_cost: ($m.cost.cache_read | per_token)} end
  + if $m.cost.cache_write == null then {} else {cache_creation_input_token_cost: ($m.cost.cache_write | per_token)} end;

def complete:
  (.max_input_tokens // 0) > 0 and (.max_output_tokens // 0) > 0
  and (.input_cost_per_token // 0) > 0 and (.output_cost_per_token // 0) > 0
  and ([to_entries[] | select(.key | startswith("cache_")) | .value <= 0] | any | not);

def suffix_rule($id):
  if $id | test("(^|-)(preview|exp|experimental|alpha|beta)(-|$)") then "unreleased"
  elif $id | test("(^|-)(free|contributor)(-|$)") then "free"
  else null end;

def gone($id; $was):
  if ($catalog | index($id)) == null then "gone"
  elif status(probe($id); $was) == 410 then "410"
  elif $dev[$id].status == "deprecated" then "deprecated"
  else null end;

($sheet | to_entries | map(select(.value.provider | IN("opencode", "opencode-anthropic")))) as $carried
| ($carried | map(.value.base_model)) as $carried_ids
| {
    carried: [$carried[] | .key as $key | .value.base_model as $id | .value.provider as $was
      | probe($id) as $p | gone($id; $was) as $gone
      | provider_of($id; $was) as $to
      | ($pinned | index($key)) as $pin
      | (if $dev[$id] == null then null else row($to; $id) end) as $row
      | if $gone and $pin == null then {key: $key, action: "remove", reason: $gone}
        elif $gone then {key: $key, action: "keep", needs_you: "`\($key)` is \($gone) but governance.yaml names it"}
        elif $to != $was and $pin != null then {key: $key, action: "keep", needs_you: "`\($key)` answers as \($to) but governance.yaml names it"}
        elif status($p; $was) != 200 and status($p; other($was)) != 200 then
          {key: $key, action: "keep", needs_you: "`\($key)` answers on neither API (chat \($p.chat), messages \($p.messages))"}
        elif $row == null then {key: $key, action: "keep", needs_you: "`\($key)` is served but missing from models.dev"}
        elif ($row | complete | not) then {key: $key, action: "keep", needs_you: "`\($key)` has an incomplete rate card on models.dev"}
        else {key: $key, action: "keep", new_key: "\($to)/\($id)", row: $row} end],
    candidates: [], skipped: []
  }
| reduce ($catalog[] | . as $c | select(($carried_ids | index($c)) == null)) as $id (.;
    $dev[$id] as $m | provider_of($id; null) as $to
    | (suffix_rule($id)
       // if $m == null then "no rate card"
          elif $m.status == "deprecated" then "deprecated"
          elif ($m.family // "") == "" then "anonymous"
          elif ($m.provider.npm // "") == "@ai-sdk/openai" then "responses only"
          elif $m.modalities.output != ["text"] then "not chat"
          elif $to == null then (probe($id) | if .chat == 200 or .messages == 200 then "unclear shape" else "no 200" end)
          elif row($to; $id) | complete | not then "no rate card"
          else null end) as $skip
    | if $skip then .skipped += [{id: $id, reason: $skip}]
      else .candidates += [{
        id: $id, provider: $to, row: row($to; $id),
        description: $m.description, family: $m.family, release_date: $m.release_date,
        superseded_by: [$dev[] | select(.family == $m.family and .release_date > $m.release_date
          and suffix_rule(.id) == null and .status != "deprecated") | .id]}]
      end)
| .served = [$catalog[] | {id: ., family: $dev[.].family, release_date: $dev[.].release_date}]
JQ

read -r -d '' APPLY_JQ <<'JQ' || true
$plan[0] as $plan | $decisions[0] as $decisions | $sheet[0] as $sheet |

($plan.carried | map({key, value: .}) | from_entries) as $carried
| ($plan.candidates | map(select($decisions[.id] == "add"))) as $added
| $sheet | to_entries
| map($carried[.key] as $c
    | if $c == null then .
      elif $c.action == "remove" then empty
      elif $c.new_key then {key: $c.new_key, value: $c.row}
      else . end)
| . + ($added | map({key: "\(.provider)/\(.id)", value: .row}))
| from_entries
JQ

read -r -d '' BODY_JQ <<'JQ' || true
$old[0] as $old | $new[0] as $new | $plan[0] as $plan | $decisions[0] as $decisions |

def ours: to_entries | map(select(.value.provider | IN("opencode", "opencode-anthropic")) | {key: .value.base_model, value})
  | from_entries;
def per_m: if . == null then "–" else (. * 1e12 | round) / 1e6 | tostring end;
def price: [.input_cost_per_token, .output_cost_per_token, .cache_read_input_token_cost, .cache_creation_input_token_cost]
  | map(per_m) | join(" / ");
def limits: "\(.max_input_tokens) / \(.max_output_tokens)";
def name($id): "\(.provider)/\($id)";
def cell($a; $b): if $a == $b then $b else "\($a) → \($b)" end;
def costs: with_entries(select(.key | test("cost")));
def rest: with_entries(select(.key != "provider" and (.key | test("cost") | not)));

($old | ours) as $o | ($new | ours) as $n
| ($plan.carried | map(select(.action == "remove") | {key: (.key | sub("^[^/]+/"; "")), value: .reason}) | from_entries) as $why
| [($o + $n | keys[]) as $id | $o[$id] as $a | $n[$id] as $b
    | if $a == null then ["added", ($b | name($id)), ($b | limits), ($b | price)]
      elif $b == null then ["removed (\($why[$id] // "gone"))", ($a | name($id)), "", ""]
      elif $a == $b then empty
      else [([if $a.provider != $b.provider then "moved" else empty end,
              if ($a | costs) != ($b | costs) then "repriced" else empty end,
              if ($a | rest) != ($b | rest) then "updated" else empty end] | join(", ")),
            cell($a | name($id); $b | name($id)), cell($a | limits; $b | limits), cell($a | price; $b | price)]
      end] as $rows
| ([$plan.skipped[] | [.id, .reason]]
   + [$plan.candidates[] | select($decisions[.id] != "add") | [.id, $decisions[.id] // "no verdict"]]) as $skipped
| [$plan.carried[] | .needs_you // empty] as $needs
| [if $rows == [] then empty else
     "| | Model | Context / output | $/M in / out / cache read / cache write |", "|---|---|---|---|",
     ($rows[] | "| \(join(" | ")) |"), "" end,
   if $skipped == [] then empty else
     "| Skipped | Reason |", "|---|---|", ($skipped[] | "| `\(.[0])` | \(.[1]) |"), "" end,
   ($needs[] | "**Needs you:** \(.)")]
| join("\n")
JQ

probe() {
  local path="$1" id="$2"
  local -a auth=(-H "Authorization: Bearer ${OPENCODE_API_KEY}")
  [ "${path}" = messages ] && auth=(-H "x-api-key: ${OPENCODE_API_KEY}" -H 'anthropic-version: 2023-06-01')
  : > "${work}/body.json"
  curl -s -o "${work}/body.json" -w '%{http_code}' --max-time 20 \
    "${auth[@]}" -H 'Content-Type: application/json' \
    -H "x-opencode-session: model-sync-${RANDOM}" \
    "${base}/${path}" \
    -d "$(jq -n --arg m "${id}" '{model: $m, max_tokens: 16, messages: [{role: "user", content: "hi"}]}')" || true
}

error() { jq -r '.error.message // .error // ""' "${work}/body.json" 2>/dev/null | head -c 200 || true; }

plan() {
  : "${OPENCODE_API_KEY:?OPENCODE_API_KEY is required}"
  curl -fsS -H "Authorization: Bearer ${OPENCODE_API_KEY}" "${base}/models" | jq '[.data[].id] | sort' > "${work}/catalog.json"
  [ "$(jq length "${work}/catalog.json")" -gt 0 ] || { echo "The zen go catalog is empty" >&2; exit 1; }
  curl -fsS https://models.dev/api.json | jq '."opencode-go".models // {}' > "${work}/dev.json"
  [ "$(jq length "${work}/dev.json")" -gt 0 ] || { echo "models.dev lists no opencode-go models" >&2; exit 1; }

  for id in $(jq -r '.[]' "${work}/catalog.json"); do
    chat="$(probe chat/completions "${id}")"
    chat_error="$(error)"
    messages="$(probe messages "${id}")"
    jq -nc --arg id "${id}" --arg chat "${chat}" --arg chat_error "${chat_error}" \
      --arg messages "${messages}" --arg messages_error "$(error)" \
      '{id: $id, chat: ($chat | tonumber? // 0), chat_error: $chat_error,
        messages: ($messages | tonumber? // 0), messages_error: $messages_error}'
  done > "${work}/probes.jsonl"

  awk '
    /^ +- provider: /     { prov = $3; inlist = 0 }
    /^ +allowed_models:$/ { inlist = 1; next }
    inlist && /^ +- /     { sub(/^ +- /, ""); gsub(/["'"'"']/, ""); if ($0 != "*") print prov "/" $0; next }
    inlist                { inlist = 0 }
  ' "${config}/governance.yaml" | jq -Rn '[inputs] | unique' > "${work}/pinned.json"

  jq -n \
    --slurpfile catalog "${work}/catalog.json" --slurpfile dev "${work}/dev.json" \
    --slurpfile probes "${work}/probes.jsonl" --slurpfile sheet "${config}/datasheet.json" \
    --slurpfile pinned "${work}/pinned.json" \
    "${PLAN_JQ}" > "${plan}"

  jq -r '"Plan: \(.candidates | length) candidates, \([.carried[] | select(.action == "remove")] | length) removals.",
    (.carried[] | select(.needs_you) | "Needs you: \(.needs_you)")' "${plan}"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "candidates=$(jq '.candidates | length' "${plan}")" >> "${GITHUB_OUTPUT}"
}

apply() {
  [ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "Refusing: the tree changed before apply" >&2; exit 1; }
  [ -e "${decisions}" ] || echo '{}' > "${decisions}"
  jq -e 'type == "object" and all(.[]; type == "string")' "${decisions}" >/dev/null \
    || { echo "Refusing: ${decisions} is not an object of strings" >&2; exit 1; }

  cp "${config}/datasheet.json" "${work}/old.json"

  jq -n --slurpfile plan "${plan}" --slurpfile decisions "${decisions}" --slurpfile sheet "${work}/old.json" \
    "${APPLY_JQ}" > "${config}/datasheet.json"

  for provider in opencode opencode-anthropic; do
    models="$(jq -r --arg p "${provider}" '[.[] | select(.provider == $p) | .base_model] | sort | join(",")' "${config}/datasheet.json")"
    awk -v p="    ${provider}:" -v models="${models}" '
      /^    [a-z0-9-]+:$/            { inprov = ($0 == p) }
      inprov && /^ +models:$/        { print; match($0, /^ +/); pad = substr($0, 1, RLENGTH) "  "
                                       n = split(models, ids, ","); for (i = 1; i <= n; i++) print pad "- " ids[i]
                                       skip = 1; next }
      skip && /^ +- /                { next }
                                     { skip = 0; print }
    ' "${config}/providers.yaml" > "${work}/providers.yaml"
    cp "${work}/providers.yaml" "${config}/providers.yaml"
  done

  others='with_entries(select(.value.provider | IN("opencode", "opencode-anthropic") | not))'
  diff -q <(jq -S "${others}" "${work}/old.json") <(jq -S "${others}" "${config}/datasheet.json") >/dev/null \
    || { echo "Refusing: apply changed rows outside the opencode providers" >&2; exit 1; }

  jq -rn --slurpfile old "${work}/old.json" --slurpfile new "${config}/datasheet.json" \
    --slurpfile plan "${plan}" --slurpfile decisions "${decisions}" \
    "${BODY_JQ}" > "${summary}"
  cat "${summary}"

  if [ -z "$(git status --porcelain --untracked-files=all)" ] && jq -e 'any(.carried[]; .needs_you)' "${plan}" >/dev/null; then
    echo "Nothing changed, but the plan needs a human." >&2
    exit 1
  fi
}

case "${1:-}" in
  plan | apply) "$1" ;;
  *) echo "usage: $0 plan|apply" >&2; exit 2 ;;
esac
