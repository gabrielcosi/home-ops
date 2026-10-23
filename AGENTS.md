# AGENTS.md

Operational guide for coding agents working in this repository.

## Scope and stack

Homelab infrastructure-as-code. Work from the repo root.

- `kubernetes/` — Flux-managed cluster: `HelmRelease` + `OCIRepository`/`HelmRepository`, with reusable Kustomize Components.
- `talos/` — Talos machine-config rendering (minijinja + `talosctl`).
- `bootstrap/` — `just` module that brings up a fresh cluster (secrets, CRDs, core apps).
- `ansible/` + `docker/` — off-cluster nodes (VPS edge). `ansible` provisions them (`just ansible install|deploy <target>`); `docker/` holds their Compose stacks, deployed by doco-cd (compose-GitOps), not Flux.

## Tooling

- `just` is the entrypoint: the root justfile imports the `bootstrap`, `kube`, `talos`, and `ansible` modules (`*/mod.just`). Prefer `just` recipes over their underlying commands. After the user approves a mutating op, answer recipe confirmation prompts with `yes | just <recipe> ...` rather than bypassing the recipe.
- `flate` validates Kubernetes manifests — it renders the full Flux pipeline with bundled helm/kustomize/source SDKs (no `helm`/`kustomize`/`flux` binaries).
- `talosctl` (1.13.x) for Talos machine config, via `just talos` (render/validate/apply); `op` (1Password CLI) for secret material.
- Cluster reads default to `kubernetes-mcp-server` MCP tools; if RBAC blocks them, fall back to read-only `kubectl` (`get`/`describe`/`logs`).
- Outline wiki via `outline-mcp` tools — for a `https://docs.xcd.dev/` link use `outline-mcp_fetch` (`resource: "document"`); search with `outline-mcp_list_documents`.
- Self-hosted Forgejo (`git.xcd.dev`) via the `tea` CLI, not WebFetch (auth-gated): for any `git.xcd.dev/<owner>/<repo>` link use e.g. `tea pr <n> --repo <owner>/<repo>`. Read-only subcommands by default.

## Safety — read/validate-only by default

Never run commands that change live infrastructure or cluster state. If recovery genuinely needs one, ask for explicit permission first in the same conversation.

Forbidden:

- Mutating MCP tools: `kubernetes-mcp-server_kubectl_apply`, `_kubectl_rollout`, `_node_management`, `_run_pod`
- `just bootstrap cluster|base|apps`
- Live-mutating `kube` recipes: `apply-ks`, `delete-ks`, `sync`, `prune-pods`, `browse-pvc`, `debug-node`, `maintenance`
- Mutating `talos` recipes: `apply-node`, `reboot-node`, `reset-node`, `shutdown-node`, `upgrade-node`, `upgrade-k8s`

Allowed (non-mutating): `flate test|build|diff`, `just kube view-secret`, `just kube render-local-ks`, read-only `kubectl`/MCP diagnostics.

## Validate changes — `flate`, from repo root

flate renders what Flux applies (Kustomizations + HelmReleases + `postBuild` substitutions + components + OCI/Helm/Git sources). Pass `--allow-missing-secrets` locally so ExternalSecret-backed apps render without their auth Secrets.

- Whole tree (PASS/FAIL per object, non-zero exit on failure): `flate test all --path ./kubernetes --allow-missing-secrets`
- Change vs a baseline branch (git-to-git, not the live cluster): `flate diff all --path ./kubernetes --base main`
- Render one app: `flate build hr --path ./kubernetes <app> --allow-missing-secrets` (or `build ks --namespace <ns> <app>`)

The in-cluster `konflate` renders a preview of each PR at konflate.xcd.dev, outside CI. kritika reviews every PR; on Renovate's it follows `.agents/skills/renovate/SKILL.md` and its confidence score gates automerge through the `Kritika / Review` check. Its repository settings live in `.kritika.yaml`.

## Conventions

### Files & YAML

- 2-space indent (YAML, HCL, justfiles); one resource type per file where practical; no trailing whitespace.
- Filenames: no hyphens, at most 22 characters including the extension. Default to the lowercased kind, singular even when the file holds several objects (`externalsecret.yaml`, `trafficpolicy.yaml`).
- Where the kind is unwieldy use a short token (`pool.yaml`, `l3.yaml`, `talos.yaml`); in a collection directory name by subject instead (`dashboards/dcgm.yaml`, `netpols/cidrgroup.yaml`). Keep related objects together rather than splitting one kind per file (`vmauth.yaml` holds its `VMUser`s).
- Key order `apiVersion`, `kind`, `metadata`, `spec`. Explicit `namespace` on namespaced objects. Quote values YAML may coerce (bools, numbers, durations, IDs).

### Flux

- App shape: `kubernetes/apps/<group>/<app>` with a `ks.yaml` (Flux `Kustomization`) and an `app/` dir (`OCIRepository`/`HelmRepository` + `HelmRelease` + manifests). Apps use HelmReleases, not kustomize `helmCharts` inflation.
- Reusable Kopiur/dragonfly/alert behaviour attaches via `components` at the `ks.yaml` layer, parameterized with `postBuild.substitute`.

### Secrets

- Never commit plaintext secrets. Use `ExternalSecret` (`secretStoreRef` → the `onepassword-connect` `ClusterSecretStore`). `op://` paths live only in bootstrap/talos templates, not app manifests.

### Renovate & git hygiene

- Pin every version explicitly — source tags (`OCIRepository`/`HelmRepository` `ref`), container image tags, tool/provider versions; no floating tags or ranges. Renovate proposes the bumps.
- Small, low-risk changes go straight to `main`. Big or infra changes go through a Forgejo PR, merged in Forgejo, never by pushing to `main`.
- Never push a branch or open a PR without the user's explicit approval for that PR.
- Apply a `talos/` change to the nodes from its PR branch before the PR merges, so `main` only carries config that is live.
- Committing is fine unprompted; **pushing is not**. Never `git push` (or force-push) without the user's explicit say-so in the same conversation — approval for one push does not carry to the next.
- Preserve `# renovate:` annotations; don't bump chart/provider/image versions unless asked.
- Keep edits scoped to the request; don't reformat unrelated files.
