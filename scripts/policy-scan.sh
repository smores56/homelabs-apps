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
# An all-zero digest is a placeholder, not a pin: it is syntactically valid and
# points at nothing. Failing here keeps CI honest about a manifest no node can
# pull, instead of downgrading it to a warning nobody reads.
if hits=$(grep -nE '@sha256:0{64}$' "$rendered"); then
  note "image is a placeholder digest (docs/manual-steps.md step 3): $hits"
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

# --- platform-owned paths ----------------------------------------------------

# The prompt and the model catalog are platform-owned (smores56/sdlc#639). A copy
# here is a shadow the agent could edit and the next restart would discard, and
# it would let a tenant push change the agent's instructions.
for owned in config/prompts/system.md config/models/providers.yaml; do
  if [ -e "$root/apps/nanobot/$owned" ]; then
    note "platform-owned file checked in: apps/nanobot/$owned"
  fi
done
if hits=$(grep -nE 'config/(prompts/system\.md|models/providers\.yaml)' \
  "$root/apps/nanobot/kustomization.yaml"); then
  note "kustomization publishes a platform-owned file: $hits"
fi

# Admission pins these mount paths; the tenant half only has to keep them.
for pinned in /etc/nanobot/prompts/system.md /etc/nanobot/models/providers.yaml; do
  grep -qF "mountPath: $pinned" "$root/apps/nanobot/deployment.yaml" ||
    note "deployment does not mount the platform policy at $pinned"
done
grep -qE '^ +name: nanobot-policy$' "$root/apps/nanobot/deployment.yaml" ||
  note "deployment does not source the platform nanobot-policy ConfigMap"
grep -qE '^ +- name: NANOBOT_CONFIG_DIR$' "$root/apps/nanobot/deployment.yaml" ||
  note "deployment no longer sets NANOBOT_CONFIG_DIR"

# The digest is Flux's to rewrite; without the marker a hand-typed image drifts.
# shellcheck disable=SC2016 # the marker is a literal, not an expansion
marker='# {"$imagepolicy": "flux-system:nanobot"}'
grep -qF "$marker" "$root/apps/nanobot/deployment.yaml" ||
  note "no Flux image policy marker in apps/nanobot/deployment.yaml"

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

# ConfigMap keys must equal the tenant-owned mounts (cron and skills), so a
# config edit cannot silently go unread. The prompt and model keys mount from
# platform's nanobot-policy and are deliberately not compared to this generator.
mapfile -t config_keys < <(sed -nE 's/^[[:space:]]*- ([a-z0-9-]+\.(md|yaml))=.*/\1/p' \
  "$root/apps/nanobot/kustomization.yaml" | sort)
mapfile -t mount_keys < <(awk '
  /^ +- name: (skills|cron)$/ { tenant = 1; next }
  /^ +- name: / { tenant = 0 }
  tenant && /^ +- key: / { print $3 }
' "$root/apps/nanobot/deployment.yaml" | sort)
if [ "${config_keys[*]}" != "${mount_keys[*]}" ]; then
  note "ConfigMap keys (${config_keys[*]}) differ from Deployment mounts (${mount_keys[*]})"
fi

# The toolchain roots are the trust boundary apps/nanobot/pvc.yaml describes: an
# install has to land on nanobot-tools (5Gi, so a pip or cargo build fits) and
# never on the scratch volume or the 64Mi memory emptyDir, which dies with the
# pod. A claim that is not declared here is a volume nobody reviewed.
mapfile -t claims < <(awk '/^ +claimName: / { print $2 }' "$rendered" | LC_ALL=C sort -u)
expected_claims='nanobot-books nanobot-scratch nanobot-tools'
if [ "${#claims[@]}" -gt 0 ] && [ "${claims[*]}" != "$expected_claims" ]; then
  note "pod volumes claim (${claims[*]}); the reviewed set is ($expected_claims)"
fi
for claim in "${claims[@]}"; do
  grep -qE "^  name: ${claim}$" "$root/apps/nanobot/pvc.yaml" ||
    note "claim $claim is not declared in apps/nanobot/pvc.yaml"
done
grep -qF 'mountPath: /data/home/tools' "$root/apps/nanobot/deployment.yaml" ||
  note "deployment does not mount nanobot-tools at /data/home/tools"

# Every env var is reviewed. A key outside the allowlist widens the agent's reach
# (a proxy, a credential path, a second state root) in a diff nobody reads.
mapfile -t env_names < <(awk '
  /^ *env:$/ { match($0, /[^ ]/); depth = RSTART - 1; inside = 1; next }
  inside {
    match($0, /[^ ]/)
    lead = RSTART - 1
    if (lead < depth) { inside = 0; next }
    if (lead == depth) {
      if ($0 ~ /^ *- name: /) { print $3; next }
      inside = 0
    }
  }
' "$rendered" | LC_ALL=C sort)
expected_env='BOOK_SHELF BROKER_URL CARGO_HOME GIT_TERMINAL_PROMPT GOPATH HOME NANOBOT_CONFIG_DIR NPM_CONFIG_PREFIX PATH PIP_USER PYTHONUSERBASE TINYFISH_BASE_URL TMPDIR UV_TOOL_BIN_DIR UV_TOOL_DIR'
if [ "${env_names[*]}" != "$expected_env" ]; then
  note "deployment env (${env_names[*]}) differs from the reviewed allowlist ($expected_env)"
fi
# The install roots are all on nanobot-tools, and TMPDIR is on the scratch PVC.
for key in UV_TOOL_DIR UV_TOOL_BIN_DIR PYTHONUSERBASE NPM_CONFIG_PREFIX CARGO_HOME GOPATH; do
  grep -A1 -E "^ +- name: ${key}\$" "$root/apps/nanobot/deployment.yaml" |
    grep -qF 'value: /data/home/tools/' ||
    note "$key does not point into /data/home/tools"
done
grep -A1 -E '^ +- name: TMPDIR$' "$root/apps/nanobot/deployment.yaml" |
  grep -qF 'value: /data/tmp' ||
  note "TMPDIR is not /data/tmp on the scratch PVC"

# --- network contract --------------------------------------------------------

# The public-egress rule is only safe with its exception list; dropping a range
# re-opens the cluster's own networks (and the metadata endpoint) to the agent.
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
  172.16.0.0/12 192.168.0.0/16 ::1/128 ::ffff:0:0/96 fc00::/7 fe80::/10; do
  grep -qF -- "- $cidr" "$root/apps/nanobot/networkpolicy.yaml" ||
    note "networkpolicy public egress no longer excepts $cidr"
done
for cidr in 0.0.0.0/0 ::/0; do
  grep -qF -- "cidr: $cidr" "$root/apps/nanobot/networkpolicy.yaml" ||
    note "networkpolicy has no public egress rule for $cidr"
done

if [ "$fail" -ne 0 ]; then
  echo "policy scan failed" >&2
  exit 1
fi
echo "policy scan passed"
