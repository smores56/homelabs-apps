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
| `apps/nanobot/` | Deployment, Service, scratch + books PVCs (Namespace and NetworkPolicies are contract copies; platform owns them) |
| `apps/nanobot/config/` | skills and cron — the tenant-owned half; prompt and model catalog are platform's |
| `scripts/verify.sh` | local + CI: kustomize, yamllint, kubeconform, shellcheck, policy scan |
| `scripts/policy-scan.sh` | deny list for kinds, host escapes, tokens, platform-owned paths and the network contract |
| `scripts/apply-merge-tiers.sh` | idempotent GitHub rulesets for the per-repository merge tiers |
| `scripts/acceptance-t8.sh` | live T8 test: model call, apps push, agent branch, same-repo platform PR through the broker |
| `docs/manual-steps.md` | operator steps: the GitHub App, broker credential files, image automation, merge tiers, storage and uid migration |

## Contracts with platform

These names are the seam; changing either side needs both.

The mounts split by owner:

| Component | Store | Mount |
|---|---|---|
| Prompt and model catalog | platform `nanobot-policy` ConfigMap, keys `system-prompt.md` and `providers.yaml` | `/etc/nanobot/prompts/system.md`, `/etc/nanobot/models/providers.yaml` (`subPath`) |
| Skills and cron | tenant `nanobot-config` ConfigMap | `/etc/nanobot/skills`, `/etc/nanobot/cron` |
| Library | PVC `nanobot-books` over platform PV `nanobot-books-data` (`/mnt/data/books`, the Calibre share) | `/data/books` (`BOOK_SHELF`) |
| Scratch | PVC `nanobot-scratch` | `/data/home` (`HOME`), `/data/outbox` |

The seams themselves:

| Seam | Value |
|---|---|
| Namespace | `tenant-apps`, Pod Security `restricted` |
| Agent identity | ServiceAccount `nanobot` in `tenant-apps`, no token automount, no API route |
| Runtime | `RuntimeClass gvisor` (containerd handler `runsc`); absence fails admission |
| Broker | `BROKER_URL=http://broker.broker.svc.cluster.local:8080`, pods labelled `app.kubernetes.io/name: broker` in tier `broker` |
| Logical hosts | `neuralwatt`, `github-apps`, `github-platform-push`, `github-platform`, `tinyfish`, `loki`, `status` (`docs/broker.md` in `homelabs-platform`) |
| DNS | CoreDNS in `kube-system`, pods labelled `k8s-app: kube-dns` |
| Public egress | direct 80/443; private, CGNAT, metadata, loopback and ULA ranges refused (`networkpolicy.yaml`) |
| Ingress | pods labelled `app.kubernetes.io/name: cloudflared` in namespace `ingress` (Cloudflare Access in front of `agent.sammohr.dev`) |
| Image | `ghcr.io/smores56/nix-config/nanobot@sha256:…`, digest-pinned and rewritten by Flux `ImagePolicy flux-system:nanobot`; source is platform-owned |
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

## Merge tiers

Each repository is a tier, recorded in an idempotent script
(`scripts/apply-merge-tiers.sh`) and enforced as a GitHub ruleset when a token
with **Administration: write** runs it. The script updates the ruleset with the
tier's name and never creates a second one. The verified applied state (with
ruleset ids) is in `docs/manual-steps.md` step 6.

```sh
bash scripts/apply-merge-tiers.sh
gh api repos/smores56/homelabs-apps/rulesets
```

| Repository | Tier | Effective rule |
|---|---|---|
| `smores56/sdlc` | agent-writable | recorded; the free plan refuses rulesets, so the guard is the broker scope |
| `smores56/homelabs-apps` | agent-writable | same as `sdlc` |
| `smores56/nix-config` | human review | `main` requires a PR and one approving review |
| `smores56/kanbei` | human review | same, plus Code Owners and unattributed-change approvals |
| `smores56/homelabs-platform` | human only | no agent installation and no agent broker scope; `main` requires a PR and one review |

Every ruleset lists the repository Admin role as a bypass actor (the script also
adds `smores56` explicitly), so the owner's local commits still land directly;
`homelabs-agent` has no bypass. In the agent-writable tier the agent pushes
`main` directly and CI reports on the result. In the review tier its work lands
on `agent/*` and stops at the PR.
`smores56/sdlc` is private on a free plan, where the rulesets API answers 403
("Upgrade to GitHub Pro"); the script reports that and leaves it unapplied, so
the guard there is the broker scope and the App installation, not GitHub.
Status checks are deliberately not required: a required check would block every
direct push because a new commit has no status yet. CI still runs on each push; a
red `verify` on `main` means revert.

### Path guards

A ruleset cannot say "this path is platform-owned", so that split is enforced at
three other layers:

- **Prompt and model catalog:** `apps/nanobot/config/` holds only skills and
  cron. The prompt and `providers.yaml` live in platform's `nanobot-policy`
  ConfigMap, admission pins the two mount paths, and `scripts/policy-scan.sh`
  fails if a copy or a generator entry reappears here.
- **Image source:** platform builds and publishes the image, and Flux's
  `ImagePolicy flux-system:nanobot` is the only writer of the digest. The
  Deployment carries the matching marker; policy-scan fails without it.
- **`.github/` is an agent-writable residual:** the workflow runs from the
  agent's own commit, so a tenant push can change CI. It cannot change what CI
  runs with — `permissions: contents: read`, no persisted checkout credential,
  every action pinned by SHA — but `verify` is a fast local check, not a
  security boundary.

### Trusted-CI boundary

The trusted boundary is platform's pinned build/push workflow plus cluster
admission. That workflow holds the only token that can publish an image, and
admission pins the image prefix, the policy mount and the uid. This repository's
CI is a lint gate on the tenant's own commit; it earns no trust it cannot be
given by the agent that writes it.
