#!/bin/sh
set -eu

printf '%s\n' "${OFFSITE_BOX_KNOWN_HOSTS}" > /tmp/known_hosts
printf '%s\n' "${OFFSITE_BUCKETS}" > /tmp/buckets

failed=0
listed=0
while read -r bucket mode; do
  [ -n "${bucket}" ] || continue
  listed=$((listed + 1))

  case "${mode}" in
    crypt) dest="boxcrypt:${bucket}" ;;
    plain) dest="box:offsite/plain/${bucket}" ;;
    *)
      echo "${bucket}: unknown mode '${mode}'"
      failed=1
      continue
      ;;
  esac

  if ! size=$(rclone size --json "s3:${bucket}" < /dev/null); then
    echo "${bucket}: listing failed"
    failed=1
    continue
  fi
  count=$(printf '%s' "${size}" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  if [ "${count:-0}" -eq 0 ]; then
    echo "skip ${bucket}: the source lists no objects"
    continue
  fi

  echo "sync ${bucket} (${count} objects)"
  rclone sync "s3:${bucket}" "${dest}" < /dev/null || failed=1
done < /tmp/buckets

if [ "${listed}" -eq 0 ]; then
  echo "OFFSITE_BUCKETS lists no buckets"
  exit 1
fi

if [ "${failed}" -ne 0 ]; then
  echo "one or more buckets failed to sync"
  exit 1
fi

printf 'offsite_sync_last_success_timestamp_seconds %s\n' "$(date +%s)" > /tmp/metric
wget -q -O /dev/null --post-file=/tmp/metric http://127.0.0.1:8429/api/v1/import/prometheus
