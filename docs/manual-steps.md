# Manual steps

Steps only the owner can do. Each one names its verification; nothing here is
optional for the agent to work.

## 1. Create the `homelabs-agent` GitHub App

There is no machine user and no PAT for the agent. The identity is the app;
`homelabs-platform` owns the one-time creation steps (its
`docs/manual-steps.md` step 1): permissions (Contents: read/write, Pull
requests: read/write, Metadata: read), install on `homelabs-apps` and
`homelabs-platform`, and the branch ruleset that confines writes to `agent/*`.

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

## 3. Pin the image digest

`apps/nanobot/deployment.yaml` ships a deliberate all-zero digest; the pod will
not start until it is replaced, and `scripts/policy-scan.sh` **fails** on it
(`image is a placeholder digest`), so CI is red until this step is done. That is
the honest signal: the repository ships a manifest no registry can pull.

1. The image is `packages.nanobot-image` in `smores56/nix-config`; its
   `publish-nanobot` workflow builds and pushes
   `ghcr.io/smores56/nix-config/nanobot:sha-<12>` with the job token on any
   change under `pkgs/nanobot/`, and prints the digest in the run summary. The
   package must be public (Profile -> Packages -> nanobot -> visibility); the
   node has no pull secret.
2. Put the printed digest in the manifest:

   ```sh
   nix run nixpkgs#crane -- digest ghcr.io/smores56/homelabs-apps/nanobot:<git-sha>
   ```

   Replace the `image:` line with
   `ghcr.io/smores56/homelabs-apps/nanobot@sha256:<digest>`, delete the
   `PLACEHOLDER DIGEST` comment, run `scripts/verify.sh`, commit.
3. The package must be public, or the k3s node needs a pull credential for it in
   `tenant-apps`; either way that credential belongs to platform's SOPS file,
   not here.

Verify: `scripts/policy-scan.sh` passes (it fails on `@sha256:0{64}`), and the
pod reaches `Running` after reconcile.

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

## 5. Branch protection

Applied once, from a checkout, after step 4 (a branch must exist first):

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
```

No status check is required: the branch is pushed to directly, and a required
check would block every direct push. CI runs anyway; red `main` means revert.

The app `homelabs-agent` is already the sole non-human pusher; it is
listed in `restrictions.apps`.

Verify: `gh api repos/smores56/homelabs-apps/branches/main/protection -q '.restrictions.users[].login'`
lists exactly the accounts allowed to push.

Precondition, not yet satisfied: this call needs a token with
**Administration: write** on the repository, and classic branch protection on a
private repository needs GitHub Pro (the rulesets API answers "Upgrade to
GitHub Pro" on the current plan). Until both hold, `main` is unprotected and the
only guard is the commit review the agent does itself.

## 6. Broker, tunnel and the acceptance run

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
deleted. From a scratch shell in `tenant-apps`, a call to another namespace
times out and a direct `https://api.neuralwatt.com` call is refused by
NetworkPolicy.
