# homelabs-apps

The tenant half of the home cluster's GitOps split. Flux reconciles this
repository as an **unprivileged tenant** that may only write the `nanobot`
namespace, which is also where the cluster administrator agent lives. It can
change what runs; it cannot see what the cluster stores.

Machine counterpart: `smores56/homelabs-platform` (Flux bootstrap, namespaces,
RBAC, admission policy, network policy, ESO/SOPS, data-bearing apps, cluster
tunnel). Humans merge there; this repository is agent-writable.

## Tenant model

Flux's tenant `Kustomization` lives in `homelabs-platform`, points `spec.path` at
`deploy`, sets `spec.targetNamespace: nanobot`, and impersonates a
ServiceAccount bound to `admin` inside `nanobot` only. Nothing in this
repository can widen that.

That bound is what makes the following rules structural rather than stylistic,
and `scripts/policy-scan.sh` enforces them on every push:

- **Forbidden here:** `Secret`, `ServiceAccount`, `Role`, `RoleBinding`, any
  RBAC or admission API group; CRDs; cluster-scoped objects; Flux custom
  resources; `hostPath`, `hostNetwork`, `hostPID`, `hostIPC`; privileged pods;
  a runtime class other than `gvisor`; any pod in another namespace.
- **Data namespaces are out of reach:** Immich, Navidrome, Calibre, Graphiti and
  their PVCs, credentials and logs belong to `homelabs-platform`. The agent
  proposes diffs; a human applies them.
- **Credentials never live here.** Egress goes to the broker, which injects the
  token, strips whatever the agent sent, refuses internal addresses, and logs
  every request. The agent holds the broker's address, nothing else.

`apps/nanobot/namespace.yaml` is the one cluster-scoped file, kept for review and
deliberately **not** part of the build: the tenant cannot create a Namespace, so
platform owns the live object and this copy is the contract it must match.

## Layout

| Path | Contents |
|---|---|
| `deploy/kustomization.yaml` | the Flux entrypoint (`spec.path: deploy`) |
| `apps/nanobot/` | Deployment, Service, scratch PVC, NetworkPolicies |
| `apps/nanobot/config/` | prompts, model catalog, cron entries, skills — see its README |
| `scripts/` | `verify.sh` (local + CI) and `policy-scan.sh` (deny list) |
| `docs/manual-steps.md` | operator steps: machine user, tokens, image digest, first push |

## Contracts with platform

These names are the seam; changing either side needs both.

| Seam | Value |
|---|---|
| Namespace | `nanobot`, Pod Security `restricted` |
| Tenant identity | ServiceAccount `nanobot` in `nanobot`, no API access (`automountServiceAccountToken: false`) |
| Runtime | `RuntimeClass gvisor` (containerd handler `runsc`); absence fails admission |
| Broker | `broker.broker.svc.cluster.local:3128`, pods labelled `app.kubernetes.io/name: broker` |
| DNS | CoreDNS in `kube-system`, pods labelled `k8s-app: kube-dns` |
| Ingress | pods labelled `app.kubernetes.io/name: cloudflared` in namespace `tunnel` (Cloudflare Access in front of `agent.sammohr.dev`) |
| Image | `ghcr.io/smores56/nanobot@sha256:…`, digest-pinned |

## Verify

```sh
nix run nixpkgs#kustomize -- build apps/nanobot
nix run nixpkgs#kustomize -- build --load-restrictor LoadRestrictionsNone deploy
nix shell nixpkgs#kustomize nixpkgs#kubeconform nixpkgs#yamllint -c bash scripts/verify.sh
git diff --check
```

`--load-restrictor LoadRestrictionsNone` is what kustomize-controller itself
passes (fluxcd.io FAQ); plain `kustomize build deploy` refuses the parent
directory by design. CI runs the identical script.

## Branch protection

`main` is protected for the owner: force pushes, deletions and merge commits are
refused, and only the accounts in `restrictions.users` may push. It is applied
once, after the first push (a branch must exist), from a checkout of this
repository:

```sh
gh api -X PUT repos/smores56/homelabs-apps/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": {"users": ["smores56"], "teams": [], "apps": []},
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
gh api repos/smores56/homelabs-apps/branches/main/protection
```

Status checks are deliberately not required: this branch is pushed to directly,
and a required check would block every direct push because a new commit has no
status yet. CI still runs on each push — a red `verify` on `main` means revert,
which is the rule the agent's system prompt states.

Not applied yet: the call needs a token with **Administration: write** on the
repository, and classic branch protection on a private repository requires
GitHub Pro (the rulesets API currently answers "Upgrade to GitHub Pro"). Once
both hold, run the block above unchanged.

When the nanobot machine user starts pushing (see `docs/manual-steps.md`), add
it to `restrictions.users` with the same call. The CI check stays required:
pushing a commit that fails `verify` reports red on `main`, and the fix is a
revert, which is the rule the agent's system prompt states.
