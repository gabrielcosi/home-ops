#!/usr/bin/env bash
# Guard the datasheet and allowlist edits of a model-sync run.
set -euo pipefail

CONFIG=kubernetes/apps/ai/bifrost/app/config
DATASHEET="${CONFIG}/datasheet.json"
PROVIDERS="${CONFIG}/providers.yaml"
GOVERNANCE="${CONFIG}/governance.yaml"

# Extending this list is a deliberate edit, not a sync.
FIELDS="
  provider base_model mode
  max_input_tokens max_output_tokens architecture
  supports_function_calling supports_tool_choice supports_reasoning
  input_cost_per_token output_cost_per_token
  cache_read_input_token_cost cache_creation_input_token_cost
  output_cost_per_image
"

fail() { echo "Refusing: $*" >&2; exit 1; }

changed="$(git status --porcelain --untracked-files=all \
  | awk '{ if ($0 ~ / -> /) sub(/.* -> /, ""); else sub(/^.../, ""); print }')"

if [ -z "${changed}" ]; then
  echo "No changes produced."
  exit 0
fi

echo "Changed files:"
echo "${changed}" | sed 's/^/  /'

stray="$(echo "${changed}" | grep -vxF -e "${DATASHEET}" -e "${PROVIDERS}" || true)"
[ -z "${stray}" ] || fail "touched files outside the datasheet and allowlist: $(echo "${stray}" | tr '\n' ' ')"

if echo "${changed}" | grep -qxF "${PROVIDERS}"; then
  outside="$(git diff -U0 -- "${PROVIDERS}" \
    | grep -E '^[+-]' | grep -vE '^[+-]{3}' \
    | grep -vE '^[+-] +- [a-z0-9][a-z0-9._-]*$' || true)"
  [ -z "${outside}" ] || fail "providers.yaml changed outside the model allowlist: ${outside}"
fi

# One mistyped value makes bifrost reject the whole file.
bad_field="$(jq -r --arg fields "${FIELDS}" '
  ($fields | [splits("\\s+")] | map(select(. != ""))) as $allowed
  | to_entries[] | .key as $row | .value | to_entries[]
  | if (.key | IN($allowed[]) | not) then "\($row).\(.key) (unknown field)"
    elif (.key | test("cost|_tokens$")) and (.value | type) != "number" then "\($row).\(.key) (not a number)"
    elif (.key | endswith("_tokens")) and .value != (.value | floor) then "\($row).\(.key) (not an integer)"
    elif (.key | startswith("supports_")) and (.value | type) != "boolean" then "\($row).\(.key) (not a boolean)"
    elif .key == "architecture" and (.value | type) != "object" then "\($row).architecture (not an object)"
    elif .key == "architecture" then .value | keys[]
      | select(IN("input_modalities", "output_modalities") | not) | "\($row).architecture.\(.) (unknown field)"
    else empty end' "${DATASHEET}")"
[ -z "${bad_field}" ] || fail "fields outside the allowlist or of the wrong type: $(echo "${bad_field}" | tr '\n' ' ')"

bad_row="$(jq -r 'to_entries[]
  | select(.value.provider != (.key | split("/")[0])
      or .value.base_model != (.key | sub("^[^/]+/"; ""))
      or (.value.mode | IN("chat", "decisions", "embedding", "image_generation") | not)
      or (.value.mode != "image_generation" and (.value.max_input_tokens // 0) <= 0)
      or (.value.mode == "chat" and (.value.max_output_tokens // 0) <= 0))
  | .key' "${DATASHEET}")"
[ -z "${bad_row}" ] || fail "provider, base_model, mode or token limits wrong: $(echo "${bad_row}" | tr '\n' ' ')"

bad_arch="$(jq -r 'to_entries[]
  | .value as $m
  | select(($m.architecture.input_modalities // []) as $in
      | ($in | type) != "array"
        or ($in | index("text")) == null
        or ($in - ["text", "image"]) != []
        or $m.architecture.output_modalities != {chat: ["text"], decisions: ["text"], embedding: ["embeddings"], image_generation: ["image"]}[$m.mode])
  | .key' "${DATASHEET}")"
[ -z "${bad_arch}" ] || fail "architecture modalities wrong for the mode: $(echo "${bad_arch}" | tr '\n' ' ')"

bad_price="$(jq -r 'to_entries[]
  | select(if .value.mode == "image_generation"
           then (.value.output_cost_per_image // 0) <= 0
           else (.value.input_cost_per_token // 0) <= 0
             or ((.value.mode | IN("embedding", "decisions") | not) and (.value.output_cost_per_token // 0) <= 0)
           end
           or ([.value | to_entries[] | select(.key | startswith("cache_")) | .value <= 0] | any))
  | .key' "${DATASHEET}")"
[ -z "${bad_price}" ] || fail "not a positive price: $(echo "${bad_price}" | tr '\n' ' ')"

twice="$(jq -r '[.[] | select(.provider | IN("opencode", "opencode-anthropic")) | .base_model]
  | group_by(.) | map(select(length > 1) | first)[]' "${DATASHEET}")"
[ -z "${twice}" ] || fail "under both opencode providers: $(echo "${twice}" | tr '\n' ' ')"

for provider in opencode opencode-anthropic; do
  allowlist="$(awk -v p="    ${provider}:" '
    /^    [a-z0-9-]+:$/    { inprov = ($0 == p) }
    inprov && /^ +models:$/ { inlist = 1; next }
    inlist && /^ +- /       { sub(/^ +- /, ""); print; next }
    inlist                  { inlist = 0 }
  ' "${PROVIDERS}" | sort -u)"

  pinned="$(awk -v p="${provider}" '
    /^ +- provider: /            { prov = $3; inlist = 0 }
    /^ +allowed_models:$/        { inlist = 1; next }
    inlist && /^ +- /            { sub(/^ +- /, ""); gsub(/["'"'"']/, "");
                                   if (prov == p && $0 != "*") print; next }
    inlist                       { inlist = 0 }
  ' "${GOVERNANCE}" | sort -u)"

  sheet="$(jq -r --arg p "${provider}/" 'keys[] | select(startswith($p)) | ltrimstr($p)' "${DATASHEET}" | sort -u)"

  missing_allow="$(comm -23 <(echo "${sheet}") <(echo "${allowlist}"))"
  [ -z "${missing_allow}" ] || fail "${provider}: in datasheet, not allowlisted: $(echo "${missing_allow}" | tr '\n' ' ')"

  missing_sheet="$(comm -13 <(echo "${sheet}") <(echo "${allowlist}"))"
  [ -z "${missing_sheet}" ] || fail "${provider}: allowlisted, not in datasheet: $(echo "${missing_sheet}" | tr '\n' ' ')"

  orphan_pin="$(comm -13 <(echo "${sheet}") <(echo "${pinned}"))"
  [ -z "${orphan_pin}" ] || fail "${provider}: a virtual key pins a model the datasheet dropped: $(echo "${orphan_pin}" | tr '\n' ' ')"
done

echo
echo "Validation passed: $(jq -r 'keys | length' "${DATASHEET}") models, rows and allowlists consistent."
