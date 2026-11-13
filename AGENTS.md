# AGENTS.md

Guidance for agents working in `homelabs-apps`. This repository *is* the agent's
write path: nanobot changes the cluster by committing here, and Flux applies it.

## Classification

Every change is a tenant-manifest change: no SDLC funnel, no worktree, commit
straight to `main` (this repo's `smores.flow` is `local` and `main` is the
applied branch). One commit per concern; the commit is the rollout record.

## What may live here

Only objects the tenant ServiceAccount can create inside `tenant-apps`:
Deployments, Services, PVCs, ConfigMaps, NetworkPolicies.

Never add — CI fails and cluster admission rejects them anyway:

- `Secret`, `ServiceAccount`, `Role`, `RoleBinding`, CRDs, or any RBAC,
  admission, storage or scheduling API group;
- cluster-scoped objects of any kind (`apps/nanobot/namespace.yaml` is a
  contract copy that stays out of the build);
- Flux custom resources, or anything that would change how this repo is
  reconciled;
- `hostPath`, `hostNetwork`, `hostPID`, `hostIPC`, privileged containers, a
  runtime class other than `gvisor`;
- credentials of any kind, including "placeholder" tokens, broker tokens,
  Cloudflare tokens and encrypted blobs.

Data-bearing namespaces are platform-owned. Do not read, copy or reference their
Secrets, PVCs, logs, or service DNS names; propose a diff to the human instead.

## Network

`BROKER_URL` is the only address that carries a credential and the only route to
an internal service: the broker is an HTTP API
(`$BROKER_URL/<logical-host>/<path>`), not a forward proxy: no `CONNECT`, no
`HTTP_PROXY`. The network contract also allows direct public 80/443 with every
private, CGNAT, metadata, loopback and ULA range excepted, so a download needs
no rule; a service that needs a secret is still a broker enrollment in
`homelabs-platform`, not a new rule here. `scripts/policy-scan.sh` rejects a
config file that names a real upstream or asks for a proxy.

## Conventions

- Images are digest-pinned (`@sha256:`); a tag alone fails the scan.
- Pods stay `restricted`: non-root, read-only rootfs, `drop: [ALL]`,
  `allowPrivilegeEscalation: false`, `runtimeClassName: gvisor`, no token
  automount, `serviceAccountName: nanobot`.
- NetworkPolicy is default-deny; a new dependency is a new rule in
  `apps/nanobot/networkpolicy.yaml`, not a wider selector.
- Config is declarative under `apps/nanobot/config/`; read its README before
  adding a skill or cron entry. The prompt, model catalog and image source are
  platform-owned and checked by `scripts/policy-scan.sh`.
- Comments explain why a rule exists. Delete dead files instead of commenting
  them out.

## Verify

```sh
nix shell nixpkgs#kustomize nixpkgs#kubeconform nixpkgs#yamllint \
  nixpkgs#shellcheck -c bash scripts/verify.sh
```

That is the exact CI job (`verify`). Do not push a commit you have not run it
against. If `main` goes red, revert first and diagnose second. The live T8
acceptance is `scripts/acceptance-t8.sh` inside the pod; it skips without
`BROKER_URL` and needs no token.

## Docs

`README.md` holds the tenant model and the platform seams; `docs/manual-steps.md`
holds the steps only a human can do (GitHub App, credential files, image
automation, merge tiers, storage migration, broker wiring, tunnel route). Keep
both current when a seam moves; neither carries TODO/TBD items.
