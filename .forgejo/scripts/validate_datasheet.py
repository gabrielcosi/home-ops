#!/usr/bin/env python3
"""Guard the bifrost datasheet edits a model-sync run produced.

Refuses anything outside the datasheet and the provider allowlist, then checks
the invariants that keep bifrost billing correctly:

  * both JSON files parse and hold the same keys
  * each explicit provider allowlist matches its datasheet keys, both ways
  * no virtual key pins a model the datasheet no longer carries
  * every price is a positive number

Exits 0 when the tree is clean or every check passes, 1 on the first failure.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

CONFIG_DIR = Path("kubernetes/apps/ai/bifrost/app/config")
ALLOWED_PATHS = {
    CONFIG_DIR / "models.json",
    CONFIG_DIR / "pricing.json",
    CONFIG_DIR / "providers.yaml",
}
# A providers.yaml diff may only add or remove allowlist entries: "  - <model>".
ALLOWLIST_LINE = re.compile(r"^[+-] +- [a-z0-9][a-z0-9._-]*$")

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs pyyaml
    sys.exit("pyyaml is required")


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout


def changed_paths() -> list[Path]:
    """Every path the run touched, including files it newly created.

    `git diff` alone would miss an untracked file the agent wrote, letting a
    stray path slip past the scope guard unreported.
    """
    paths: list[Path] = []
    for line in git("status", "--porcelain", "--untracked-files=all").splitlines():
        if not line:
            continue
        path = line[3:]
        if " -> " in path:  # rename: report the destination
            path = path.split(" -> ", 1)[1]
        paths.append(Path(path.strip('"')))
    return sorted(set(paths))


def check_scope(changed: list[Path]) -> list[str]:
    stray = sorted(str(p) for p in changed if p not in ALLOWED_PATHS)
    if stray:
        return [f"touched files outside the datasheet and allowlist: {stray}"]

    providers = CONFIG_DIR / "providers.yaml"
    if providers not in changed:
        return []

    offending = [
        line
        for line in git("diff", "-U0", "--", str(providers)).splitlines()
        if line[:1] in "+-" and not line.startswith(("+++", "---"))
        and not ALLOWLIST_LINE.match(line)
    ]
    if offending:
        return [f"providers.yaml changed outside the model allowlist: {offending}"]
    return []


def check_invariants() -> list[str]:
    models = json.loads((CONFIG_DIR / "models.json").read_text())
    pricing = json.loads((CONFIG_DIR / "pricing.json").read_text())
    providers = yaml.safe_load((CONFIG_DIR / "providers.yaml").read_text())
    governance = yaml.safe_load((CONFIG_DIR / "governance.yaml").read_text())
    providers = providers["bifrost"]["providers"]
    governance = governance["bifrost"]["governance"]

    fail: list[str] = []

    if set(models) != set(pricing):
        fail.append(f"key sets differ: {sorted(set(models) ^ set(pricing))}")

    sheets: dict[str, set[str]] = {}
    for key in models:
        provider, model = key.split("/", 1)
        sheets.setdefault(provider, set()).add(model)

    for name, config in providers.items():
        allow: set[str] = set()
        for key in config.get("keys", []):
            allow |= set(key.get("models", []))
        if "*" in allow:
            continue
        sheet = sheets.get(name, set())
        if sheet - allow:
            fail.append(f"{name}: in datasheet, not allowlisted: {sorted(sheet - allow)}")
        if allow - sheet:
            fail.append(f"{name}: allowlisted, not in datasheet: {sorted(allow - sheet)}")

    for vk in governance.get("virtualKeys", []):
        for pc in vk.get("provider_configs", []):
            provider = pc["provider"]
            if provider not in sheets:
                continue
            for model in pc.get("allowed_models", []):
                if model == "*" or model in sheets[provider]:
                    continue
                fail.append(f"virtual key {vk['id']} pins missing model {provider}/{model}")

    for key, entry in pricing.items():
        for field in ("input_cost_per_token", "output_cost_per_token"):
            value = entry.get(field)
            if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
                fail.append(f"{key}: {field} is not a positive number")

    return fail


def main() -> int:
    changed = changed_paths()
    if not changed:
        print("No changes produced.")
        return 0

    print("Changed files:")
    for path in changed:
        print(f"  {path}")

    failures = check_scope(changed) or check_invariants()
    if failures:
        print("\nRefusing:")
        print("\n".join(f"  {f}" for f in failures))
        return 1

    models = json.loads((CONFIG_DIR / "models.json").read_text())
    print(f"\nValidation passed: {len(models)} models, key sets and allowlists consistent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
