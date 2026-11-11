#!/usr/bin/env bash
# The same checks CI runs: kustomize (with the flags kustomize-controller uses),
# yamllint, kubeconform, and the tenant deny-list scan.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

for tool in kustomize yamllint kubeconform; do
  command -v "$tool" >/dev/null || {
    echo "$tool is not on PATH; run this through 'nix shell nixpkgs#kustomize nixpkgs#kubeconform nixpkgs#yamllint -c bash scripts/verify.sh'" >&2
    exit 2
  }
done

render=$(mktemp -t render-XXXXXX.yaml)
trap 'rm -f "$render"' EXIT

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
