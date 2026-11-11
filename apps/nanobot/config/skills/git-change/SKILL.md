---
name: git-change
description: Make a cluster change through this repository, the only write path.
metadata: {"nanobot":{"requires":{"bins":["git","bash"]}}}
---

# Changing the cluster

There is no `kubectl` here. A change is a commit, and Flux is the applier.

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
   git push origin main
   ```

5. Watch the commit, not the logs: CI on `main` re-runs the same checks, and a
   red run means revert first (`git revert HEAD && git push`) and diagnose second.

Anything that needs a Secret, a namespace, RBAC, a Flux resource, a
cluster-scoped object, a new image build, or data access is not a Git change
you can make. Write the diff into the report and hand it to the human.
