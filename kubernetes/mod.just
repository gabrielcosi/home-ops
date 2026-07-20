set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l kube

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f -

[doc('Browse a PVC')]
browse-pvc ns claim:
    kubectl run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
debug-node node:
    trap 'kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    kubectl debug node/{{ node }} -n default -it --image=mirror.gcr.io/alpine:latest --profile=sysadmin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl delete -f -

[private]
_maintenance re who action hours:
    re='{{ re }}'
    who='{{ who }}'
    kubectl -n monitoring port-forward pod/vmalertmanager-victoria-metrics-cluster-0 19093:9093 >/dev/null 2>&1 &
    pf=$!
    trap 'kill $pf 2>/dev/null' EXIT
    base="http://127.0.0.1:19093/api/v2"
    for _ in $(seq 1 60); do curl -sf "$base/status" >/dev/null && break; sleep 0.5; done
    curl -sf "$base/status" >/dev/null || { echo "alertmanager port-forward failed (is vmalertmanager-victoria-metrics-cluster-0 running?)"; exit 1; }
    case "{{ action }}" in
    on)
        existing=$(curl -sS "$base/silences" | jq -r --arg w "$who" '.[]|select(.status.state=="active" and .createdBy==$w)|.id' | head -n1)
        if [ -n "$existing" ]; then
            echo "🔕 $who already ON — silence $existing (run off first to change duration)"
            echo "   end early: just kube maintenance (select ${who#just-maintenance:} → off)"
            exit 0
        fi
        start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        end=$(date -u -v+{{ hours }}H +%Y-%m-%dT%H:%M:%SZ)
        id=$(curl -sS -X POST "$base/silences" -H 'Content-Type: application/json' -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$re\",\"isRegex\":true,\"isEqual\":true}],\"startsAt\":\"$start\",\"endsAt\":\"$end\",\"createdBy\":\"$who\",\"comment\":\"$who ({{ hours }}h) via just\"}" | jq -r .silenceID)
        echo "🔕 $who ON — silence $id (expires $end)"
        echo "   end early: just kube maintenance (select ${who#just-maintenance:} → off)"
        ;;
    off)
        n=0
        for id in $(curl -sS "$base/silences" | jq -r --arg w "$who" '.[]|select(.status.state=="active" and .createdBy==$w)|.id'); do
            curl -sS -o /dev/null -X DELETE "$base/silence/$id" && echo "🔔 lifted $id" && n=$((n+1))
        done
        echo "$who OFF ($n lifted)"
        ;;
    status)
        curl -sS "$base/silences" | jq -r '.[]|select(.status.state=="active")|"• \(.createdBy)  ends=\(.endsAt)"'
        ;;
    esac

[doc('Interactively silence a node or NAS outage cascade in Alertmanager (auto-expiring; never touches Watchdog)')]
maintenance:
    node_re='^(CephMonDown|CephMonDownQuorumAtRisk|CephOSDDown|CephOSDDownHigh|CephOSDHostDown|CephHealthWarning|CephPGsUnclean|KubeNodeUnreachable|KubeletInstanceUnreachable|KubePodNotReady|KubePdbNotEnoughHealthyPods|KubeDeploymentReplicasMismatch|KubeDaemonSetMisScheduled|KubeDaemonSetRolloutStuck|TargetDown|TooManyScrapeErrors|TooManyLogs)$'
    nas_re='^(LastFailedArchiveTime|KopiurBackupConsecutiveFailures|KopiurBackupStale|KopiurRepositoryNotReady|KopiurRestoreFailed|KopiurSnapshotFailed)$'
    PS3='> '
    echo 'What is going offline for maintenance?'
    select target in node nas quit; do [ -n "${target:-}" ] && break; done
    [ "${target:-}" = node ] || [ "${target:-}" = nas ] || { echo aborted; exit 1; }
    echo 'Action?'
    select action in on off status; do [ -n "${action:-}" ] && break; done
    case "${action:-}" in on|off|status) ;; *) echo aborted; exit 1 ;; esac
    case "$target" in node) re="$node_re" ;; nas) re="$nas_re" ;; esac
    hours=4
    if [ "$action" = on ]; then
        read -r -p 'Silence duration in hours [4]: ' h || true
        hours="${h:-4}"; [[ "$hours" =~ ^[0-9]+$ ]] || hours=4
        read -r -p "Silence all $target-outage alerts for ${hours}h? [y/N] " ok || true
        case "${ok:-}" in y|Y|yes) ;; *) echo aborted; exit 1 ;; esac
    fi
    just kube _maintenance "$re" "just-maintenance:$target" "$action" "$hours"

[doc('Prune pods in Failed, Pending, or Succeeded state')]
prune-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource')]
sync resource:
    kubectl get {{ resource }} --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$name" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('View a secret')]
view-secret ns secret:
    kubectl view-secret -n {{ ns }} {{ secret }}

[private]
render-local-ks ns ks:
    flate build ks --namespace "{{ ns }}" --path "{{ justfile_directory() }}/kubernetes" --output yaml "{{ ks }}"
