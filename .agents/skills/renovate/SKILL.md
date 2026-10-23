---
name: renovate
description: How to review a Renovate dependency update in this Flux repository and write its summary. Covers finding the upstream, what breaks, what actuates a bump, what depends on it here, rendering with flate, and what a check proves.
---

# Reviewing Renovate updates in home-ops

Flux reconciles `kubernetes/` from `main`: a merge rolls out within minutes. `talos/` is applied to the nodes by hand, `ansible/` and `docker/` deploy off-cluster through doco-cd. Secrets are ExternalSecrets from the `onepassword-connect` ClusterSecretStore: judge key names and mappings from the manifests.

## A Renovate update

Judge whether the update is safe to merge: what changed upstream between the old and new versions, and whether anything here depends on it.

### The update

Take from the title, body and diff the package, its datasource (container image, chart as an `OCIRepository`, GitHub Action, mise tool, Grafana dashboard, Renovate preset), the old and new version or digest, and the changed files. `v1.2.3@sha256:aaa -> v1.3.0@sha256:bbb` is a version bump; `v1.2.3@sha256:aaa -> v1.2.3@sha256:bbb` is a rebuild of the same tag, a different question rather than a smaller one.

Renovate's body carries collapsed release notes. Read them first; go upstream when they are missing, truncated or ambiguous, and always for a major update or a jump over several versions: read every intermediate release, breaking changes land in the middle.

### Finding the upstream

The changelog lives at the source, not the wrapper: an image bump v1.2 -> v1.3 may re-wrap a tool that jumped 4.0 -> 5.0.

- Read GitHub with `gh`: `gh release view <tag> -R <o>/<r>`, `gh api repos/<o>/<r>/releases`, `gh api "repos/<o>/<r>/compare/<old>...<new>"`, a CHANGELOG or UPGRADING file with `gh api -H "Accept: application/vnd.github.raw+json" repos/<o>/<r>/contents/<path>?ref=<tag>`. Anything else (GitLab, Artifact Hub, vendor docs) with `curl`.
- An image's `org.opencontainers.image.source`, `version` and `revision` labels, read with `fetch_oci` on the new pinned digest, show what it was built from: check them against the release reviewed. A label naming another version or source than the PR claims is a finding; an image without labels is not.
- A chart's source is the app's `ocirepository.yaml`: `url` is the registry path, `ref.tag` the version. Charts under `registry.xcd.dev/x/<host>/...` are pulled through the cachette proxy: `<host>/...` is the real upstream. A repository that publishes many charts prefixes its release tags with the chart name (`<chart>-1.2.3`). Chart and app versions are independent streams: read the chart's changelog, and the app's too when `appVersion` moved.
- A release note that says "see #123" is read with `gh pr view` or `gh issue view`, and an issue is taken to the merged PR that closed it.
- A rebuilt tag still has a cause: a scheduled base-image rebuild, a CI re-run of the same commit, a floating tag now resolving to newer source, or a re-tag of different code. Compare the two digests' `created` and `revision`. If the source moved, treat it as a version bump.

Images under `registry.xcd.dev/gabrielcosi/` build from private sources: say in one line that their upstream could not be read, and review only what else the PR moves.

### What breaks

Flag in each release: `BREAKING CHANGE`, `⚠` or `!:` markers; removed or renamed Helm values, CRD fields, environment variables and flags; a required Kubernetes, Flux, Talos or kernel version; one-way schema or data migrations; changed defaults (authentication, storage, ports, probes); deprecations that became errors; new required keys without a default; label values or resource names that changed while the key stayed.

An update also moves images that appear nowhere in the diff: a chart or operator that changes its default images. Name each with its old and new version, read from the chart's `values.yaml` at both tags unless the HelmRelease pins it.

Some apps pin `image.tag` in values on top of the chart, so chart and image bump as separate Renovate PRs. Say so only when the order matters: a chart whose templates need the newer app, or an image needing a value the current chart cannot express.

### What actuates the bump

A version in the diff is a request; something else here carries it out: an operator that reconciles it, a controller that watches it, a CLI pinned in a job image. Find it, read its pinned version from the repo, and check its supported range against the new target. A target outside the range fails when it runs, not when it renders. The constraint runs both ways.

## A change under `kubernetes/`

Render a HelmRelease whose chart version or values change, from the repository root:

```
flate build hr <name> --path kubernetes/apps/<namespace> --allow-missing-secrets --no-progress
```

The checkout has no git history, so only the head renders: what the base produced is read upstream at the old tag, or from the names this repository already refers to. A HelmRelease whose Kustomization depends on another namespace's renders from the whole tree (`--path kubernetes/apps -n <namespace>`). flate exits nonzero for any failure in the path; a failure is a finding only when it belongs to the HelmRelease under review and the change caused it. A source that could not be fetched says nothing about the change. A successful render proves the tag exists and the values fit its schema; take label values, resource names and ports from it rather than from reading templates, narrowing with `--show-only <template>`.

Every HelmRelease also gets the patches in `kubernetes/flux/cluster/ks.yaml` (CRD policy `CreateReplace`, remediation); flate does not apply them.

### Exposure here

The question is whether anything here depends on what changed. Search `kubernetes/` for:

- a label key or value: `matchLabels` and `selector` fields of monitors, network policies and disruption budgets, label matchers in PromQL rules and dashboards;
- a resource name: route backends, `<name>.<namespace>.svc.cluster.local`, Flux `dependsOn` and `healthChecks`;
- a value, flag or CRD field: HelmRelease `values`, `valuesFrom`, `postRenderers`, kustomize patches, and the custom resources other apps create from the dependency's CRDs.

An app configured through its own UI keeps that configuration on its volume, not in git: a search here proves nothing about it.

Before prescribing a rename or new value, confirm it from the upstream PR's diff or the chart's template at the new tag. Without that, make it a check to do after the merge rather than an edit.

## Intentional here, never flag

- `metadata.namespace` absent on a HelmRelease or Kustomization: `ks.yaml` sets `targetNamespace`.
- CNPG clusters carrying a permanent `bootstrap.recovery` block.
- `# renovate:` annotations, digest pins, and versions Renovate manages.
- No generic GitOps, Helm or Flux best-practice notes.

## What a check proves

- Write an inference out, and only one the evidence carries. A default the release changes to a value this repository already sets explicitly changes nothing here.
- Put the evidence in the claim: the value found and the file it came from, or the source that says so.
- What the repository cannot show is not a check: say what could not be verified and what to look at after the merge.

## The summary

A Renovate review answers one question: what changed upstream, and does it hit this repository. The reader glances at it before an automerge, so these rules override the general guidance on the take.

- **Headline**: the package and the version range, nothing else: `jellyfin 12.2 → 12.3`, or `hermes-agent v2026.9.24 rebuild` for a digest-only move.
- **Take**: Markdown sections in this order, each a heading on its own line followed by bullets, one fact per bullet. Leave out a section with nothing in it, and never state an absence anywhere ("no breaking changes", "nothing renamed", "our values are unaffected").
  - `#### Breaking` — what needs a change to keep working, with the version that introduced it and the file it hits here.
  - `#### Security` — CVEs, advisories, hardening, credential or permission changes.
  - `#### Features` — what the new version adds. Name it only when this repository could use it, with the setting and file.
  - `#### Fixes` — bugs fixed, grouped; a long list is summarised in one or two bullets.
  - `#### Rebuild` — for a digest-only move: why the digest changed, from the image's `created` and `revision`.
- Every bullet is upstream substance. Never restate the diff (the tag, the digest, the file it sits in), never describe how Flux, Helm or the pod rolls it out, and never list what stayed the same.
- A breaking change that touches nothing here is still one bullet under Breaking, saying why it does not apply: the confidence scorer has no tools and credits only what the summary states.
- A defect this repository must fix before merging is a finding on the changed line, not only a bullet.
- Praise is empty.
