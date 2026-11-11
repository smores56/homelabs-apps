# AGENTS.md

Guidance for agents working in `homelabs-apps`. This repository *is* the agent's
write path: nanobot changes the cluster by committing here, and Flux applies it.

## Classification

Every change is a tenant-manifest change: no SDLC funnel, no worktree, commit
straight to `main` (this repo's `smores.flow` is `local` and `main` is the
applied branch). One commit per concern; the commit is the rollout record.

## What may live here

Only objects the tenant ServiceAccount can create inside `nanobot`: Deployments,
Services, PVCs, ConfigMaps, NetworkPolicies.

Never add — CI fails and cluster admission rejects them anyway:

- `Secret`, `ServiceAccount`, `Role`, `RoleBinding`, CRDs, or any RBAC,
  admission, storage or scheduling API group;
- cluster-scoped objects of any kind (`apps/nanobot/namespace.yaml` is a
  contract copy that stays out of the build);
- Flux custom resources, or anything that would change how this repo is
  reconciled;
- `hostPath`, `hostNetwork`, `hostPID`, `hostIPC`, privileged containers, a
  runtime class other than `gvisor`;
- credentials of any kind, including "placeholder" tokens and encrypted blobs.

Data-bearing namespaces are platform-owned. Do not read, copy or reference their
Secrets, PVCs, logs, or service DNS names; propose a diff to the human instead.

## Conventions

- Images are digest-pinned (`@sha256:`); a tag alone fails the scan.
- Pods stay `restricted`: non-root, read-only rootfs, `drop: [ALL]`,
  `allowPrivilegeEscalation: false`, `runtimeClassName: gvisor`, no token
  automount.
- NetworkPolicy is default-deny; a new dependency is a new rule in
  `apps/nanobot/networkpolicy.yaml`, not a wider selector.
- Config is declarative under `apps/nanobot/config/`; read its README before
  adding a prompt, skill, cron entry or model. No config value duplicates a
  Deployment env var.
- Comments explain why a rule exists. Delete dead files instead of commenting
  them out.

## Verify

```sh
nix shell nixpkgs#kustomize nixpkgs#kubeconform nixpkgs#yamllint -c bash scripts/verify.sh
```

That is the exact CI job (`verify`). Do not push a commit you have not run it
against. If `main` goes red, revert first and diagnose second.

## Docs

`README.md` holds the tenant model and the platform seams; `docs/manual-steps.md`
holds the steps only a human can do (machine user, tokens, image digest, first
push). Keep both current when a seam moves; neither carries TODO/TBD items.
