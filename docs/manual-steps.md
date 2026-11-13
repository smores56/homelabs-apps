# Manual steps

Steps only the owner can do. Each one names its verification; nothing here is
optional for the agent to work.

## 1. Create the `homelabs-agent` GitHub App

There is no machine user and no PAT for the agent. The identity is the app;
`homelabs-platform` owns the one-time creation steps (its
`docs/manual-steps.md` step 1): permissions (Contents: read/write, Pull
requests: read/write, Metadata: read), install on `homelabs-apps` **only**, and
the rulesets described in step 6.

`homelabs-platform` is human-only: the app is not installed there. The agent's
platform writes go through the broker's `github-platform-push` logical host,
with the token the broker holds.

Verify: `gh api "/users/homelabs-agent%5Bbot%5D"` returns the bot user; the
acceptance script probes both refusals (outside `agent/*`, and a workflow
edit); and
`gh api repos/smores56/homelabs-apps/installation` lists the installation.

## 2. Supply the app to the broker

The broker mints installation tokens from `homelabs-agent`; the agent
holds none. Put the app id, the private key and the installation id in the
platform broker Secret (`homelabs-platform` `docs/manual-steps.md` step 10).
Nothing enters this repository.

Verify: a call through `$BROKER_URL/github-platform/rate_limit` from the agent
pod returns `200`; `$BROKER_URL/github-apps` can push to `homelabs-apps` but the
platform scopes refuse every other repository.

## 3. The image digest is Flux's

`apps/nanobot/deployment.yaml` carries the Flux marker
`# {"$imagepolicy": "flux-system:nanobot"}` directly above a digest-pinned
`image:` line. The image source belongs to platform: its trusted workflow builds
and pushes the package, and Flux's `ImageRepository`/`ImagePolicy` watch that
package and commit the new digest here. Do not hand-edit the digest; the marker
is the only image edit point, and the next reconcile reverts a manual change.

The current digest is the artifact the last trusted build published; only Flux
changes it. A placeholder all-zero digest still fails `scripts/policy-scan.sh`,
so CI stays honest about a manifest no node can pull.

Verify: the marker is present, `scripts/policy-scan.sh` passes, and a trusted
build produces a Flux commit that rolls the Deployment.

## 4. Wire the tenant into platform

Platform already owns the namespace, the `nanobot` ServiceAccount, the gVisor
and broker-hop admission policies, and the tenant `Kustomization`
(`clusters/homelab/platform/tenants/homelabs-apps.yaml`). The first push is the
wiring:

1. From the repository checkout:

   ```sh
   git push -u origin main
   git log --oneline -1
   ```

2. Confirm the platform objects the Deployment needs exist before the first
   reconcile:

   ```sh
   cluster-kubectl -n tenant-apps get sa nanobot
   cluster-kubectl get runtimeclass gvisor
   cluster-kubectl -n broker get svc broker
   flux -n tenant-apps get kustomization homelabs-apps
   ```

3. Confirm the render lands where intended (the tenant ServiceAccount cannot
   create a Namespace):

   ```sh
   cluster-kubectl -n tenant-apps get deploy nanobot -o jsonpath='{.spec.template.spec.serviceAccountName}'
   cluster-kubectl -n tenant-apps get deploy nanobot -o jsonpath='{.spec.template.spec.runtimeClassName}'
   ```

Verify: both print `nanobot` and `gvisor`; `flux -n tenant-apps get
kustomization homelabs-apps` reports `Applied`.

## 5. Books share and the uid migration

Two platform objects must exist before the tenant binds them; neither is in this
repository:

1. PV `nanobot-books-data`: class `data-local`, local path `/mnt/data/books` (the
   share Calibre and OPDS already read), claimRef `tenant-apps/nanobot-books`.
2. The `nanobot-policy` ConfigMap in `tenant-apps` with keys `system-prompt.md`
   and `providers.yaml` (smores56/sdlc#639).

The pod now runs as uid/gid 1000 (`smores`), the owner of every host share.
`nanobot-scratch` was written under the old fsGroup 65532, so its contents are
migrated once. Nothing durable lives there; recreate the claim while Flux is
suspended, because a plain scale-down is reverted by the next reconcile:

```sh
flux -n tenant-apps suspend kustomization homelabs-apps
cluster-kubectl -n tenant-apps scale deploy/nanobot --replicas=0
cluster-kubectl -n tenant-apps delete pvc nanobot-scratch
flux -n tenant-apps resume kustomization homelabs-apps
```

On resume Flux recreates the PVC and the single replica, and the image renders
an empty home. `fsGroupChangePolicy: OnRootMismatch` fixes the volume root but
does not rewrite files the old uid created. Repeat the delete for
`nanobot-tools` once it exists (smores56/sdlc#626): the same uid change applies
to it, and it must not be added to this repository before that ticket lands.

Do not migrate the books tree: the host already owns it as 1000, and the pod must
not chown a share other apps read. The mount is read-write so the agent adds
files as that same uid; nothing in it changes ownership.

Verify: `cluster-kubectl -n tenant-apps get pvc nanobot-books` prints `Bound`;
`id` in the pod prints `uid=1000`; an EPUB written under `/data/books` is owned
by `smores:users` on the host and still present after a pod restart; no mount
translation for 65532 remains.

## 6. Merge tiers and rulesets

`scripts/apply-merge-tiers.sh` applies the per-repository tiers from
`README.md`. It needs a token with **Administration: write** on every repository
and is idempotent, so running it twice changes nothing.

```sh
bash scripts/apply-merge-tiers.sh
for repo in homelabs-apps nix-config kanbei homelabs-platform; do
  gh api "repos/smores56/$repo/rulesets" --jq '.[] | "\(.id) \(.name)"'
done
```

`smores56/sdlc` is private on a free plan; the rulesets API answers 403 there,
the script reports it and leaves that repository alone. Do not re-enable
classic branch protection either (also a Pro feature); the guard is the broker
scope and the App installation.

Current state, verified 2026-11-13: `nix-config` ruleset `27179536`, `kanbei`
`27179584` and `homelabs-platform` `27170976` carry the PR tier with the Admin
role as the bypass actor (`current_user_can_bypass: always`), so the owner's
direct pushes are unaffected. `homelabs-apps` and `sdlc` have no `main` ruleset:
the token available from this checkout reads rulesets but every write is refused
with 403 (`Resource not accessible by personal access token`), and `sdlc`
additionally answers 403 for its plan. Nothing was applied from this checkout;
rerun the script with a token holding **Administration: write**, or add the same
rules in the repository settings. Do not apply a ruleset that omits the bypass.

Verify: each repository lists one `main` ruleset;
`gh api repos/<owner>/<repo>/rulesets/<id> --jq '.bypass_actors[].actor_type'`
includes the Admin role, and a direct push by the owner still lands.

## 7. Broker, tunnel and the acceptance run

1. Broker logical hosts are enrolled in `homelabs-platform`
   (`clusters/homelab/broker/config/broker.json`): `neuralwatt`, `github-apps`,
   `github-platform-push`, `github-platform`, `tinyfish`, `loki`, `status`.
   `agent.sammohr.dev` is not a logical host and must never appear in an
   allowlist.
2. The tunnel rule admits pods labelled `app.kubernetes.io/name: cloudflared` in
   namespace `ingress` on port 8080, and the Access application for
   `agent.sammohr.dev` uses the owner's identity plus a service token for maki
   (`homelabs-platform` `docs/broker.md`, "OpenTofu fragment").
3. No Cloudflare token is copied into this repository or the pod. The tunnel
   token lives in the `ingress` namespace.
4. Run the acceptance test from inside the pod:

   ```sh
   cluster-kubectl -n tenant-apps exec deploy/nanobot -- bash scripts/acceptance-t8.sh
   ```

Verify: the script prints `PASS: model call, apps push, fork push and platform
PR through the broker`, and its marker branch/pull request are closed and
deleted. From a scratch shell in `tenant-apps`, a call to another namespace or
to `169.254.169.254` times out; a public `https://` call succeeds, because the
reviewed contract allows direct public egress (the broker still owns every
credential and every internal address).
