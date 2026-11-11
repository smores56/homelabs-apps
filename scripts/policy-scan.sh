#!/usr/bin/env bash
# Deny-list policy scan for the tenant tree. Runs on the render that Flux would
# apply plus the raw files, so a forbidden object cannot hide outside the build.
set -euo pipefail

rendered=${1:-}
if [ -z "$rendered" ] || [ ! -r "$rendered" ]; then
  echo "usage: policy-scan.sh <rendered-manifests.yaml>" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

note() {
  printf 'FAIL %s\n' "$*" >&2
  fail=1
}

check() { # pattern description
  local hits
  if hits=$(grep -nE -- "$1" "$rendered"); then
    note "$2: $hits"
  fi
}

# Namespaced kinds plus everything the tenant ServiceAccount cannot create or
# must never hold.
forbidden_kinds='Secret|ServiceAccount|Role|RoleBinding|ClusterRole|ClusterRoleBinding|CustomResourceDefinition|PodSecurityPolicy|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|PersistentVolume|StorageClass|CSIDriver|CSINode|IngressClass|RuntimeClass|PriorityClass|APIService|Node|Namespace|ClusterIssuer|Issuer'

# --- rendered tree -----------------------------------------------------------

check "^kind: *($forbidden_kinds)\$" "forbidden kind"
check '^apiVersion: *(rbac\.authorization\.k8s\.io|apiextensions\.k8s\.io|admissionregistration\.k8s\.io|storage\.k8s\.io|node\.k8s\.io|scheduling\.k8s\.io|certificates\.k8s\.io|apiregistration\.k8s\.io|flowcontrol\.apiserver\.k8s\.io)/' "forbidden api group"
check '^apiVersion: *[a-z.]*fluxcd\.io/' "Flux custom resource"

if hits=$(grep -nE '^  namespace: ' "$rendered" | grep -vE '^[0-9]+:  namespace: nanobot$'); then
  note "object outside the nanobot namespace: $hits"
fi

# Escape hatches that turn a pod into a node.
check '^ +hostPath:' "hostPath"
check '^ +(hostNetwork|hostPID|hostIPC): *true$' "host namespace"
check '^ +privileged: *true$' "privileged container"
check '^ +allowPrivilegeEscalation: *true$' "privilege escalation"
check '^ +automountServiceAccountToken: *true$' "ServiceAccount token automount"

if ! grep -qE '^ +runtimeClassName: *gvisor$' "$rendered"; then
  note "no pod declares runtimeClassName: gvisor"
fi
if hits=$(grep -nE '^ +runtimeClassName:' "$rendered" | grep -vE '^[0-9]+: +runtimeClassName: *gvisor$'); then
  note "runtime class other than gvisor: $hits"
fi

# Pinned by digest, always.
if hits=$(grep -nE '^ +image:' "$rendered" | grep -vE '@sha256:[0-9a-f]{64}$'); then
  note "image not pinned by digest: $hits"
fi
if grep -qE '@sha256:0{64}$' "$rendered"; then
  echo "::warning title=placeholder-image::deployment still carries the placeholder digest; see docs/manual-steps.md"
fi

# --- repository files --------------------------------------------------------

scan_kinds() { # file allowed-kind
  local file=$1 allowed=${2:-} line kind
  while IFS= read -r line; do
    kind=${line#*kind: }
    [ "$kind" = "$allowed" ] && continue
    case $kind in
      Secret | ServiceAccount | Role | RoleBinding | ClusterRole | ClusterRoleBinding | \
        CustomResourceDefinition | PodSecurityPolicy | ValidatingAdmissionPolicy | \
        ValidatingAdmissionPolicyBinding | MutatingWebhookConfiguration | \
        ValidatingWebhookConfiguration | PersistentVolume | StorageClass | CSIDriver | \
        CSINode | IngressClass | RuntimeClass | PriorityClass | APIService | Node | \
        Namespace | ClusterIssuer | Issuer)
        note "$file:${line%%:*} holds a forbidden kind ($kind)"
        ;;
    esac
  done < <(grep -nE '^kind: ' "$root/$file" || true)
}

files=$(cd "$root" && git ls-files '*.yaml' '*.yml' | grep -vE '^\.github/|kustomization\.yaml$' || true)
for file in $files; do
  allowed=''
  case $file in
    apps/nanobot/namespace.yaml) allowed='Namespace' ;;
  esac
  scan_kinds "$file" "$allowed"
  if hits=$(grep -nE 'fluxcd\.io/|rbac\.authorization\.k8s\.io/' "$root/$file"); then
    note "$file: forbidden api group: $hits"
  fi
  if hits=$(grep -nE '^ +(hostPath|privileged|hostNetwork|hostPID|hostIPC):' "$root/$file"); then
    note "$file: $hits"
  fi
done

# The Namespace stays out of the applied set: the tenant cannot create it.
if grep -qE '^kind: *Namespace$' "$rendered"; then
  note "Namespace is in the build output"
fi

if [ "$fail" -ne 0 ]; then
  echo "policy scan failed" >&2
  exit 1
fi
echo "policy scan passed"
