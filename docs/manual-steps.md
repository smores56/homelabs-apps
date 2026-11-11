# Manual steps

Steps only the owner can do. Each one names its verification; nothing here is
optional for the agent to work.

## 1. Create the nanobot machine user

Fork-and-PR against a private repository needs a distinct GitHub account, and
creating one needs the owner's email and 2FA.

1. Sign up `smores56-nanobot` with an owner-controlled email and TOTP in the
   owner's password manager. Enable 2FA before the first push.
2. Add it as a collaborator with **Write** on `smores56/homelabs-apps` and
   **Read** on `smores56/homelabs-platform`, then fork `homelabs-platform` from
   that account (the fork is where PR branches come from).
3. Record the recovery codes and the TOTP seed in the owner's vault, not in a
   repository.

Verify: `gh api repos/smores56/homelabs-apps/collaborators/smores56-nanobot -q .permissions.push` prints `true`.

## 2. Mint the two tokens (they never enter this repository)

| Token | Scope | Holder |
|---|---|---|
| `github-apps-token` | fine-grained PAT, `homelabs-apps` only, Contents: read/write, Workflows: no | broker, logical host `github-apps` |
| `github-platform-token` | fine-grained PAT, `smores56/homelabs-platform`, Contents: read, Pull requests: read/write | broker, logical host `github-platform` |
| `github-fork-token` | fine-grained PAT, `smores56-nanobot/homelabs-platform` (the fork), Contents: read/write | broker, logical host `github-fork` |

1. Mint all three under `smores56-nanobot`, 90-day expiry, no other repositories.
2. Put them in `homelabs-platform`'s SOPS contract as
   `broker-credentials.yaml` (`docs/manual-steps.md` step 10 there) and let the
   broker's enrollment name them. The agent never sees either value, and this
   repository must never contain one.

Verify: a call through `$BROKER_URL/github-platform/user` from the agent pod
returns the machine user's JSON; `$BROKER_URL/github-apps` cannot reach the
platform repository.

**Deploy-key alternative** for the push token: generate an SSH key, register it
under *Settings → Deploy keys* with **Allow write access**, and let the broker
hold the private half. That needs an SSH-speaking path (the broker's git
logical hosts speak HTTP), so the PAT remains the documented route.

## 3. Pin the image digest

`apps/nanobot/deployment.yaml` ships a deliberate all-zero digest; the pod will
not start until it is replaced.

1. The image wraps nix-config's `pkgs/nanobot` virtualenv plus the entrypoint
   that implements `apps/nanobot/config/README.md` (render `config.json`, index
   skills, load cron). Build it and push it as
   `ghcr.io/smores56/homelabs-apps/nanobot:<git-sha>`.
2. Read the registry digest and put it in the manifest:

   ```sh
   nix run nixpkgs#crane -- digest ghcr.io/smores56/homelabs-apps/nanobot:<git-sha>
   ```

   Replace the `image:` line with
   `ghcr.io/smores56/homelabs-apps/nanobot@sha256:<digest>`, delete the
   `PLACEHOLDER DIGEST` comment, run `scripts/verify.sh`, commit.
3. The package must be public, or the k3s node needs a pull credential for it in
   `tenant-apps`; either way that credential belongs to platform's SOPS file,
   not here.

Verify: `scripts/policy-scan.sh` stops printing the `placeholder-image`
warning, and the pod reaches `Running` after reconcile.

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
  "restrictions": {"users": ["smores56"], "teams": [], "apps": []},
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
```

No status check is required: the branch is pushed to directly, and a required
check would block every direct push. CI runs anyway; red `main` means revert.

When the machine user starts pushing, add `smores56-nanobot` to
`restrictions.users` and re-run the same call.

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
   `github-fork`, `github-platform`, `tinyfish`, `loki`, `status`.
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
