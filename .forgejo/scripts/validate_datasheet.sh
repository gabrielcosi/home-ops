#!/usr/bin/env bash
# Guard the bifrost datasheet edits a model-sync run produced: refuse anything
# outside the datasheet and the opencode allowlist, then check the invariants
# that keep bifrost billing correctly. Needs only git, jq and awk.
set -euo pipefail

CONFIG=kubernetes/apps/ai/bifrost/app/config
MODELS="${CONFIG}/models.json"
PRICING="${CONFIG}/pricing.json"
PROVIDERS="${CONFIG}/providers.yaml"
GOVERNANCE="${CONFIG}/governance.yaml"

fail() { echo "Refusing: $*" >&2; exit 1; }

# Every path the run touched, untracked files included — `git diff` alone would
# miss a file the agent created and let it slip past unreported.
changed="$(git status --porcelain --untracked-files=all \
  | awk '{ if ($0 ~ / -> /) sub(/.* -> /, ""); else sub(/^.../, ""); print }')"

if [ -z "${changed}" ]; then
  echo "No changes produced."
  exit 0
fi

echo "Changed files:"
echo "${changed}" | sed 's/^/  /'

stray="$(echo "${changed}" | grep -vxF -e "${MODELS}" -e "${PRICING}" -e "${PROVIDERS}" || true)"
[ -z "${stray}" ] || fail "touched files outside the datasheet and allowlist: $(echo "${stray}" | tr '\n' ' ')"

# providers.yaml may only gain or lose allowlist entries ("  - <model>").
if echo "${changed}" | grep -qxF "${PROVIDERS}"; then
  outside="$(git diff -U0 -- "${PROVIDERS}" \
    | grep -E '^[+-]' | grep -vE '^[+-]{3}' \
    | grep -vE '^[+-] +- [a-z0-9][a-z0-9._-]*$' || true)"
  [ -z "${outside}" ] || fail "providers.yaml changed outside the model allowlist: ${outside}"
fi

# The datasheet replaces bifrost's built-in pricing rather than merging with it,
# so a key in one file and not the other bills as silent zero.
if ! diff -q <(jq -r 'keys[]' "${MODELS}") <(jq -r 'keys[]' "${PRICING}") >/dev/null; then
  fail "key sets differ: $(diff <(jq -r 'keys[]' "${MODELS}") <(jq -r 'keys[]' "${PRICING}") | tr '\n' ' ')"
fi

# Embedding models bill no output tokens, so only their input cost must be set.
bad_price="$(jq -r 'to_entries[]
  | select((.value.input_cost_per_token // 0) <= 0
        or (.value.mode != "embedding" and (.value.output_cost_per_token // 0) <= 0))
  | .key' "${PRICING}")"
[ -z "${bad_price}" ] || fail "not a positive price: $(echo "${bad_price}" | tr '\n' ' ')"

# The opencode allowlist in providers.yaml, and the models governance pins to
# the opencode provider. Both files are 2-space indented with no anchors or
# flow style, so the block structure is unambiguous.
allowlist="$(awk '
  /^    [a-z0-9-]+:$/    { inprov = ($0 == "    opencode:") }
  inprov && /^ +models:$/ { inlist = 1; next }
  inlist && /^ +- /       { sub(/^ +- /, ""); print; next }
  inlist                  { inlist = 0 }
' "${PROVIDERS}" | sort -u)"

pinned="$(awk '
  /^ +- provider: /            { prov = $3; inlist = 0 }
  /^ +allowed_models:$/        { inlist = 1; next }
  inlist && /^ +- /            { sub(/^ +- /, ""); gsub(/["'"'"']/, "");
                                 if (prov == "opencode" && $0 != "*") print; next }
  inlist                       { inlist = 0 }
' "${GOVERNANCE}" | sort -u)"

sheet="$(jq -r 'keys[] | select(startswith("opencode/")) | sub("^opencode/"; "")' "${MODELS}" | sort -u)"

missing_allow="$(comm -23 <(echo "${sheet}") <(echo "${allowlist}"))"
[ -z "${missing_allow}" ] || fail "in datasheet, not allowlisted: $(echo "${missing_allow}" | tr '\n' ' ')"

missing_sheet="$(comm -13 <(echo "${sheet}") <(echo "${allowlist}"))"
[ -z "${missing_sheet}" ] || fail "allowlisted, not in datasheet: $(echo "${missing_sheet}" | tr '\n' ' ')"

orphan_pin="$(comm -13 <(echo "${sheet}") <(echo "${pinned}"))"
[ -z "${orphan_pin}" ] || fail "a virtual key pins a model the datasheet dropped: $(echo "${orphan_pin}" | tr '\n' ' ')"

echo
echo "Validation passed: $(jq -r 'keys | length' "${MODELS}") models, key sets and allowlists consistent."
