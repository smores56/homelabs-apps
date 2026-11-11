#!/usr/bin/env bash
# Deny-list policy scan for the tenant tree. Runs on the render that Flux would
# apply plus the raw files, so a forbidden object or a credential cannot hide
# outside the build.
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

if hits=$(grep -nE '^  namespace: ' "$rendered" | grep -vE '^[0-9]+:  namespace: tenant-apps$'); then
  note "object outside the tenant-apps namespace: $hits"
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

# The agent holds no credential of any kind: no Secret volume, env or key.
check '^ +secretKeyRef:' "Secret-backed env"
check '^ +envFrom:' "envFrom (can reference a Secret)"
check '^ +secretName:' "Secret volume"
check '^ +automountServiceAccountToken: *true$' "token automount"

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

# --- credentials -------------------------------------------------------------

token_pattern='ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|Bearer [A-Za-z0-9._-]{16,}|Basic [A-Za-z0-9+/=]{16,}|CLOUDFLARE_[A-Z_]*TOKEN'
if hits=$(grep -RInE -- "$token_pattern" "$root/apps" "$root/deploy" "$root/scripts" "$root/docs" 2>/dev/null | grep -vE 'policy-scan\.sh|acceptance-t8\.sh'); then
  note "token-shaped value in the tenant tree: $hits"
fi
if hits=$(grep -RInE '^[[:space:]]*(Authorization|Proxy-Authorization|Cookie|Set-Cookie|X-Api-Key|X-API-Key)[[:space:]]*:' \
  "$root/apps" 2>/dev/null); then
  note "credential header in a manifest or config: $hits"
fi
# The config never names a real endpoint: the broker owns the mapping.
if hits=$(grep -RInE 'api\.neuralwatt\.com|api\.github\.com|api\.search\.tinyfish\.ai|loki-gateway\.observability' \
  "$root/apps/nanobot/config" 2>/dev/null); then
  note "config names a real upstream instead of a logical host: $hits"
fi
if hits=$(grep -RInE '^[[:space:]]*(proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY)[[:space:]]*:' \
  "$root/apps/nanobot/config" 2>/dev/null); then
  note "config asks for a forward proxy; the broker is an HTTP API: $hits"
fi

# --- config tree contract ----------------------------------------------------

if ! grep -qE '^api_base: http://broker\.broker\.svc\.cluster\.local:8080/neuralwatt/v1$' \
  "$root/apps/nanobot/config/models/providers.yaml"; then
  note "providers.yaml does not point at the broker's neuralwatt logical host"
fi
if ! grep -qE '^  default: ' "$root/apps/nanobot/config/models/providers.yaml"; then
  note "providers.yaml has no default model"
fi

for skill in "$root"/apps/nanobot/config/skills/*/SKILL.md; do
  [ -e "$skill" ] || continue
  name=$(basename "$(dirname "$skill")")
  grep -qE "^name: ${name}$" "$skill" || note "$skill front matter does not name $name"
  grep -qE '^description: .+' "$skill" || note "$skill has no description"
done

for cron in "$root"/apps/nanobot/config/cron/*.yaml; do
  [ -e "$cron" ] || continue
  for key in name schedule model prompt delivery; do
    grep -qE "^${key}:" "$cron" || note "$cron has no $key"
  done
  grep -qE '^  path: /data/outbox/' "$cron" || note "$cron does not deliver under /data/outbox"
done

# ConfigMap keys must equal the Deployment's mounted item keys (plus prompt and
# model files), so a config edit cannot silently go unread.
mapfile -t config_keys < <(sed -nE 's/^[[:space:]]*- ([a-z0-9-]+\.(md|yaml))=.*/\1/p' \
  "$root/apps/nanobot/kustomization.yaml" | sort)
mapfile -t mount_keys < <(sed -nE 's/^[[:space:]]+- key: (.*)$/\1/p' "$root/apps/nanobot/deployment.yaml" | sort)
if [ "${config_keys[*]}" != "${mount_keys[*]}" ]; then
  note "ConfigMap keys (${config_keys[*]}) differ from Deployment mounts (${mount_keys[*]})"
fi

if [ "$fail" -ne 0 ]; then
  echo "policy scan failed" >&2
  exit 1
fi
echo "policy scan passed"
