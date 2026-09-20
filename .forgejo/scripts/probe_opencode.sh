#!/usr/bin/env bash
# List the opencode zen go catalog and probe every model with a 4-token
# completion. Writes /tmp/catalog.txt and /tmp/probes.jsonl for the agent,
# which never sees OPENCODE_API_KEY itself.
set -euo pipefail

: "${OPENCODE_API_KEY:?OPENCODE_API_KEY is required}"

base="${OPENCODE_BASE_URL:-https://opencode.ai/zen/go/v1}"
catalog="${CATALOG_FILE:-/tmp/catalog.txt}"
probes="${PROBES_FILE:-/tmp/probes.jsonl}"
auth="Authorization: Bearer ${OPENCODE_API_KEY}"

curl -fsS -H "${auth}" "${base}/models" | jq -r '.data[].id' | sort > "${catalog}"
echo "Catalog lists $(wc -l < "${catalog}" | tr -d ' ') models."

body_file="$(mktemp)"
trap 'rm -f "${body_file}"' EXIT

: > "${probes}"
while read -r id; do
  status="$(curl -s -o "${body_file}" -w '%{http_code}' --max-time 60 \
    -H "${auth}" -H 'Content-Type: application/json' \
    -H "x-opencode-session: model-sync-${RANDOM}" \
    "${base}/chat/completions" \
    -d "$(jq -n --arg m "${id}" \
      '{model: $m, max_tokens: 4, messages: [{role: "user", content: "hi"}]}')" \
    || echo 000)"
  jq -nc --arg id "${id}" --arg status "${status}" \
    --arg error "$(jq -r '.error.message // ""' "${body_file}" 2>/dev/null | head -c 200)" \
    '{id: $id, status: ($status | tonumber? // 0), error: $error}' >> "${probes}"
done < "${catalog}"

echo "Probe results:"
jq -r '"\(.status)\t\(.id)\t\(.error)"' "${probes}"
