#!/usr/bin/env bash
# The same checks CI runs: kustomize (with the flags kustomize-controller uses),
# yamllint, kubeconform, shell syntax, and the tenant deny-list scan.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

missing=()
for tool in kustomize yamllint kubeconform; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if [ "${#missing[@]}" -ne 0 ]; then
  # In the pod the toolchain lives on the nanobot-tools PVC, so a missing tool is
  # an install the agent owes, not a broken checkout; on a workstation it is the
  # nix shell. Both are named, with the pod's target first.
  echo "missing: ${missing[*]}" >&2
  echo "install each into \$HOME/tools/bin (already first on PATH) with" \
    "'uv tool install', 'pip install --user', 'npm install -g' or 'cargo install'" >&2
  echo "on a workstation, run this through 'nix shell nixpkgs#kustomize" \
    "nixpkgs#kubeconform nixpkgs#yamllint nixpkgs#shellcheck -c bash scripts/verify.sh'" >&2
  exit 2
fi

render=$(mktemp -t render-XXXXXX.yaml)
trap 'rm -f "$render"' EXIT

echo "== shell syntax"
bash -n scripts/*.sh
if command -v shellcheck >/dev/null; then
  shellcheck scripts/*.sh
fi

echo "== kustomize build deploy"
# Load-restrictor matches kustomize-controller (fluxcd.io FAQ).
kustomize build --load-restrictor LoadRestrictionsNone deploy > "$render"
echo "== kustomize build apps/nanobot"
kustomize build apps/nanobot > /dev/null
echo "== yamllint"
yamllint --strict .
echo "== kubeconform"
kubeconform -strict -summary -kubernetes-version 1.34.0 "$render"
echo "== policy scan"
bash scripts/policy-scan.sh "$render"
echo "== git diff --check"
git diff --check
