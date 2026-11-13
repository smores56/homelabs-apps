---
name: git-change
description: Make a cluster change through this repository, the only write path.
metadata: {"nanobot":{"requires":{"bins":["git","bash","curl"]}}}
---

# Changing the cluster

There is no `kubectl` here and no credential to clone with. Git traffic goes
through the broker, which injects the token; the URL is the logical host plus
the repository path.

```sh
git clone "$BROKER_URL/github-apps/smores56/homelabs-apps.git" repo
cd repo
```

1. Read the files you are about to touch, plus `README.md` and `AGENTS.md`.
2. Edit only under `apps/`, `deploy/` and `docs/`.
3. Verify before committing:

   ```sh
   bash scripts/verify.sh
   ```

4. Commit one concern, then push:

   ```sh
   git add -A apps/
   git commit -m "fix(nanobot): <what changed and why>"
   git push "$BROKER_URL/github-apps/smores56/homelabs-apps.git" HEAD:main
   ```

5. Watch the commit, not the logs: CI on `main` re-runs the same checks, and a
   red run means revert first and diagnose second.

A platform change is a pull request, not a push: clone
`$BROKER_URL/github-platform-push/smores56/homelabs-platform.git`, commit on an
`agent/<topic>` branch, push it to the same URL, then POST the pull request to
`$BROKER_URL/github-platform/repos/smores56/homelabs-platform/pulls` with that
branch as `head` (same repository). The identity is the
`smores56-homelabs-agent` app: the broker mints a short-lived, scoped token, so
you never see one. Never push to any branch outside `agent/*`; the ruleset
refuses it. Anything that needs a Secret, a
namespace, RBAC, a Flux resource, a cluster-scoped object, a new image build, or
data access is not a Git change you can make. Write the diff into the report and
hand it to the human.
