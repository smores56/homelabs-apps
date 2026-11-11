# Manual steps

Steps only the owner can do. Each one names its verification; nothing here is
optional for the agent to work.

## 1. Create the nanobot machine user

Fork-and-PR against a private repository needs a distinct GitHub account, and
creating one needs the owner's email and 2FA.

1. Sign up `nanobot-smores56` with an owner-controlled email and TOTP in the
   owner's password manager. Enable 2FA before the first push.
2. Add it as a collaborator with **Write** on `smores56/homelabs-apps` and
   **Read** on `smores56/homelabs-platform`, then fork `homelabs-platform` from
   that account (the fork is where PR branches come from).
3. Record the recovery codes and the TOTP seed in the owner's vault, not in a
   repository.

Verify: `gh api repos/smores56/homelabs-apps/collaborators/nanobot-smores56 -q .permissions.push` prints `true`.

## 2. Mint the two tokens (they never enter this repository)

| Token | Scope | Holder |
|---|---|---|
| `nanobot-apps-push` | fine-grained PAT, `homelabs-apps` only, Contents: read/write, Workflows: no | broker, logical host `github:homelabs-apps` |
| `nanobot-platform-pr` | fine-grained PAT, `homelabs-platform` fork only, Contents: read/write, Pull requests: read/write | broker, logical host `github:platform-pr` |

1. Mint both under the machine user, 90-day expiry, no other repositories.
2. Add them to platform's SOPS file as `nanobot/apps-token` and
   `nanobot/platform-token`, and enrol the two logical hosts in the broker
   config. The agent never sees either value.

Verify: `curl -sS -H "Authorization: Bearer $TOKEN" https://api.github.com/repos/smores56/homelabs-apps` returns
the repository JSON; a token minted for one scope must fail the other.

**Deploy-key alternative** for the push token: generate an SSH key on the
platform side, register it under *Settings → Deploy keys* with **Allow write
access**, and let the broker hold the private half. This is repo-scoped and
account-free; it does not cover the fork, so the PR token is still needed.

## 3. Pin the image digest

`apps/nanobot/deployment.yaml` ships a deliberate all-zero digest; the pod will
not start until it is replaced.

1. The image wraps nix-config's `pkgs/nanobot` virtualenv plus the entrypoint
   that implements `apps/nanobot/config/README.md` (render `config.json`, index
   skills, load cron). Build it in platform's image pipeline and push it as
   `ghcr.io/smores56/nanobot:<git-sha>`.
2. Read the registry digest and put it in the manifest:

   ```sh
   nix run nixpkgs#crane -- digest ghcr.io/smores56/nanobot:<git-sha>
   ```

   Replace the `image:` line with `ghcr.io/smores56/nanobot@sha256:<digest>`,
   delete the `PLACEHOLDER DIGEST` comment, run `scripts/verify.sh`, commit.
3. The package must be public, or the k3s node needs a pull credential for it in
   the `nanobot` namespace; either way that credential belongs to platform's
   SOPS file, not here.

Verify: `scripts/policy-scan.sh` stops printing the `placeholder-image`
warning, and the pod reaches `Running` after reconcile.

## 4. First push and platform wiring

1. From the repository checkout:

   ```sh
   git push -u origin main
   git log --oneline -1
   ```

2. In `homelabs-platform`, create the Namespace from
   `apps/nanobot/namespace.yaml` (verbatim, including the `restricted` labels),
   then add the tenant source and reconciler:

   ```yaml
   # clusters/homelab/apps/nanobot.yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata: {name: nanobot-apps, namespace: flux-system}
   spec:
     interval: 5m
     url: https://github.com/smores56/homelabs-apps
     ref: {branch: main}
     secretRef: {name: nanobot-apps-auth}   # deploy key or PAT, platform-owned
   ```
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata: {name: nanobot-apps, namespace: flux-system}
   spec:
     interval: 10m
     retryInterval: 1m
     prune: true
     wait: true
     path: ./deploy
     targetNamespace: nanobot
     sourceRef: {kind: GitRepository, name: nanobot-apps}
     serviceAccountName: tenant-reconciler   # bound to `admin` in nanobot only
   ```

3. Confirm the tenant ServiceAccount, the `gvisor` RuntimeClass, and the broker
   Service exist before the first reconcile; the Deployment stays pending
   otherwise.

Verify: `flux get kustomizations nanobot-apps` reports `Applied`, and
`kubectl -n nanobot get deploy nanobot -o jsonpath='{.spec.template.spec.runtimeClassName}'`
prints `gvisor`.

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

When the machine user starts pushing, add `nanobot-smores56` to
`restrictions.users` and re-run the same call.

Verify: `gh api repos/smores56/homelabs-apps/branches/main/protection -q '.restrictions.users[].login'`
lists exactly the accounts allowed to push.

## 6. Broker and tunnel enrolment

1. Broker logical hosts: `neuralwatt`, `github:homelabs-apps`,
   `github:platform-pr`, `search`, `loki` — with `agent.sammohr.dev` absent from
   every allowlist.
2. The tunnel rule admits pods labelled `app.kubernetes.io/name: cloudflared` in
   namespace `tunnel` on port 8080, and the Access application for
   `agent.sammohr.dev` uses a service token for the human's clients.

Verify: from a scratch pod in `nanobot`,
`curl -sS --max-time 5 http://broker.broker.svc.cluster.local:3128` returns the
broker's denial page, and a request to another namespace times out.
