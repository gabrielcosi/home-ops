#!/usr/bin/env bash
# Commit the working tree onto a single reused branch and open or update its
# pull request. Idempotent: a PR left unmerged from an earlier run is updated
# in place rather than duplicated.
set -euo pipefail

: "${FORGEJO_API:?FORGEJO_API is required}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${BRANCH:?BRANCH is required}"
: "${COMMIT_MESSAGE:?COMMIT_MESSAGE is required}"

paths="${COMMIT_PATHS:-.}"
summary="${SUMMARY_FILE:-/tmp/summary.md}"
title="${PR_TITLE:-${COMMIT_MESSAGE}}"

if [ -z "$(git status --porcelain --untracked-files=all -- ${paths})" ]; then
  echo "Nothing to propose."
  exit 0
fi

[ -s "${summary}" ] || echo 'The run produced changes but no summary. Read the diff.' > "${summary}"

git config user.name "${GIT_AUTHOR_NAME:-Angel}"
git config user.email "${GIT_AUTHOR_EMAIL:-angel@xcd.dev}"

git checkout -b "${BRANCH}"
git add -- ${paths}
git commit -m "${COMMIT_MESSAGE}"

remote="http://x:${FORGEJO_TOKEN}@forgejo-http.tools.svc.cluster.local:3000/${REPO}.git"
git push --force "${remote}" "${BRANCH}"

existing="$(curl -fsS --retry 3 --retry-all-errors \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  "${FORGEJO_API}/repos/${REPO}/pulls?state=open&limit=50" \
  | jq -r --arg b "${BRANCH}" '[.[] | select(.head.ref == $b)] | first | .number // empty')"

if [ -n "${existing}" ]; then
  curl -fsS --retry 3 --retry-all-errors -X PATCH \
    -H "Authorization: token ${FORGEJO_TOKEN}" -H "Content-Type: application/json" \
    "${FORGEJO_API}/repos/${REPO}/pulls/${existing}" \
    -d "$(jq -n --rawfile body "${summary}" '{body: $body}')" -o /dev/null
  echo "Updated pull request #${existing}."
else
  number="$(curl -fsS --retry 3 --retry-all-errors -X POST \
    -H "Authorization: token ${FORGEJO_TOKEN}" -H "Content-Type: application/json" \
    "${FORGEJO_API}/repos/${REPO}/pulls" \
    -d "$(jq -n --rawfile body "${summary}" --arg head "${BRANCH}" --arg title "${title}" \
      '{title: $title, head: $head, base: "main", body: $body}')" \
    | jq -r .number)"
  echo "Opened pull request #${number}."
fi
