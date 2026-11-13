# homelabs-apps

The tenant half of the home cluster's GitOps split. Flux reconciles this
repository as an **unprivileged tenant** into the `tenant-apps` namespace, which
is where the cluster administrator agent lives. It can change what runs; it
cannot see what the cluster stores.

Machine counterpart: `smores56/homelabs-platform` (Flux bootstrap, namespaces,
RBAC, admission policy, network policy, SOPS/ESO, the broker, data-bearing apps,
cluster tunnel). Humans merge there; this repository is agent-writable.

## Tenant model

Flux's tenant `Kustomization` lives in `homelabs-platform`, points `spec.path` at
`deploy`, sets `spec.targetNamespace: tenant-apps`, and impersonates the
`tenant-apps-reconciler` ServiceAccount. The platform owns the `nanobot`
ServiceAccount in that namespace and binds it to nothing but read-only debug
RBAC in the data namespaces. Nothing in this repository can widen either.

That bound is structural, and `scripts/policy-scan.sh` enforces it on every push:

- **Forbidden here:** `Secret`, `ServiceAccount`, `Role`, `RoleBinding`, any
  RBAC or admission API group; CRDs; cluster-scoped objects; Flux custom
  resources; `hostPath`, `hostNetwork`, `hostPID`, `hostIPC`; privileged pods;
  a runtime class other than `gvisor`; any pod in another namespace.
- **Data namespaces are out of reach:** Immich, Navidrome, Calibre, Graphiti and
  their PVCs, credentials and logs belong to `homelabs-platform`. The agent
  proposes diffs; a human applies them.
- **Credentials never live here, and the agent holds none.** Every outbound
  request goes to the broker (`BROKER_URL`) in the `broker` namespace. The
  broker maps a logical host to a real endpoint, injects the token, strips
  whatever the agent sent, refuses internal addresses and redirects, and logs
  every request. There is no forward proxy, no CONNECT and no broker token.

`apps/nanobot/namespace.yaml` is the one cluster-scoped file, kept for review and
deliberately **not** part of the build: the tenant cannot create a Namespace, so
platform owns the live object and this copy is the contract it must match.

## Layout

| Path | Contents |
|---|---|
| `deploy/kustomization.yaml` | the Flux entrypoint (`spec.path: deploy`) |
| `apps/nanobot/` | Deployment, Service, scratch PVC, NetworkPolicies |
| `apps/nanobot/config/` | prompts, model catalog, cron entries, skills — see its README |
| `scripts/verify.sh` | local + CI: kustomize, yamllint, kubeconform, shellcheck, policy scan |
| `scripts/policy-scan.sh` | deny list for kinds, host escapes, tokens and config drift |
| `scripts/acceptance-t8.sh` | live T8 test: model call, apps push, agent branch, same-repo platform PR through the broker |
| `docs/manual-steps.md` | operator steps: the GitHub App, broker credential files, image digest, wiring |

## Contracts with platform

These names are the seam; changing either side needs both.

| Seam | Value |
|---|---|
| Namespace | `tenant-apps`, Pod Security `restricted` |
| Agent identity | ServiceAccount `nanobot` in `tenant-apps`, no token automount, no API route |
| Runtime | `RuntimeClass gvisor` (containerd handler `runsc`); absence fails admission |
| Broker | `BROKER_URL=http://broker.broker.svc.cluster.local:8080`, pods labelled `app.kubernetes.io/name: broker` in tier `broker` |
| Logical hosts | `neuralwatt`, `github-apps`, `github-platform-push`, `github-platform`, `tinyfish`, `loki`, `status` (`docs/broker.md` in `homelabs-platform`) |
| DNS | CoreDNS in `kube-system`, pods labelled `k8s-app: kube-dns` |
| Ingress | pods labelled `app.kubernetes.io/name: cloudflared` in namespace `ingress` (Cloudflare Access in front of `agent.sammohr.dev`) |
| Image | `ghcr.io/smores56/homelabs-apps/nanobot@sha256:…`, digest-pinned |
| Cloudflare | no token in this repository or the pod; the tunnel connector in `ingress` owns it |

## Verify

```sh
nix run nixpkgs#kustomize -- build apps/nanobot
nix run nixpkgs#kustomize -- build --load-restrictor LoadRestrictionsNone deploy
nix shell nixpkgs#kustomize nixpkgs#kubeconform nixpkgs#yamllint nixpkgs#shellcheck \
  -c bash scripts/verify.sh
git diff --check
```

`--load-restrictor LoadRestrictionsNone` is what kustomize-controller itself
passes (fluxcd.io FAQ); plain `kustomize build deploy` refuses the parent
directory by design. CI runs the identical script.

Live acceptance (inside the pod, after the broker and its credentials exist):

```sh
cluster-kubectl -n tenant-apps exec deploy/nanobot -- bash scripts/acceptance-t8.sh
```

It skips with exit 0 when `BROKER_URL` is unset (i.e. outside the agent pod) and
never reads or prints a token.

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
  "restrictions": {"users": ["smores56"], "teams": [], "apps": ["homelabs-agent"]},
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

The app `homelabs-agent` is the only non-human identity that pushes
here; it is listed in `restrictions.apps`, not `restrictions.users`. The CI check stays unrequired: pushing
a commit that fails `verify` reports red on `main`, and the fix is a revert.
