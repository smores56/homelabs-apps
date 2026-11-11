#!/usr/bin/env bash
# T8 acceptance test (smores56/sdlc#582), run inside the nanobot pod.
#
# Proves the whole path end to end: the broker injects the Neuralwatt key, git
# pushes reach homelabs-apps, a branch reaches the machine user's fork, and a
# pull request opens against homelabs-platform - all without the agent holding a
# credential. The script never reads or prints a token; if BROKER_URL is unset
# (i.e. not running in the agent pod) it skips cleanly.
#
#   cluster-kubectl -n tenant-apps exec deploy/nanobot -- \
#     bash scripts/acceptance-t8.sh
#
# Preconditions: docs/manual-steps.md steps 2-4 (machine user, tokens, broker
# credential Secret, image digest). The PR branch is deleted afterwards.
set -euo pipefail

BROKER_URL=${BROKER_URL:-}
if [[ -z $BROKER_URL ]]; then
  echo "skip: BROKER_URL is unset, so this is not the agent pod"
  exit 0
fi

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}
say() { printf '%s\n' "$*"; }

for tool in git curl; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing $tool in the image"
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
branch="acceptance/${stamp}"
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# 1. A credentialed logical host answers. 200 means the broker resolved the
# endpoint, injected the key and relayed the response.
say "== neuralwatt"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$BROKER_URL/neuralwatt/v1/models")
[[ $code == 200 ]] || fail "neuralwatt returned $code (expected 200)"

# 2. Push a marker branch to homelabs-apps through github-apps. The commit
# touches docs/ only, so a merge would not change the applied tree.
say "== push to homelabs-apps"
git init -q "$work/apps"
git -C "$work/apps" checkout -q -b "$branch"
mkdir -p "$work/apps/docs/acceptance"
printf 'broker acceptance %s\n' "$stamp" >"$work/apps/docs/acceptance/$stamp.md"
git -C "$work/apps" add "docs/acceptance/$stamp.md"
git -C "$work/apps" \
  -c user.name=nanobot -c user.email=nanobot@users.noreply.github.com \
  commit -q -m "test: broker acceptance $stamp"
git -C "$work/apps" remote add broker "$BROKER_URL/github-apps/smores56/homelabs-apps.git"
git -C "$work/apps" push -q broker "$branch"
say "pushed $branch"

# 3. The same branch in the platform fork, through github-fork.
say "== push to the platform fork"
git clone -q "$BROKER_URL/github-fork/smores56-nanobot/homelabs-platform.git" "$work/platform"
git -C "$work/platform" checkout -q -b "$branch"
mkdir -p "$work/platform/docs/acceptance"
printf 'broker acceptance %s\n' "$stamp" >"$work/platform/docs/acceptance/$stamp.md"
git -C "$work/platform" add "docs/acceptance/$stamp.md"
git -C "$work/platform" \
  -c user.name=nanobot -c user.email=nanobot@users.noreply.github.com \
  commit -q -m "test: broker acceptance $stamp"
git -C "$work/platform" remote set-url origin "$BROKER_URL/github-fork/smores56-nanobot/homelabs-platform.git"
git -C "$work/platform" push -q origin "$branch"

# 4. Open the pull request through github-platform, then close it and delete
# both branches. The token is the broker's; this process never sees it.
say "== open the platform pull request"
payload=$(printf '{"title":"test: broker acceptance %s","head":"smores56-nanobot:%s","base":"main","body":"Automated T8 acceptance. Close without review."}' "$stamp" "$branch")
response=$(curl -sS --max-time 30 -X POST \
  -H 'Accept: application/vnd.github+json' \
  -H 'Content-Type: application/json' \
  --data "$payload" \
  "$BROKER_URL/github-platform/repos/smores56/homelabs-platform/pulls")
number=$(printf '%s' "$response" | grep -o '"number":[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$')
[[ -n $number ]] || fail "no pull request number in the response: $response"
say "opened pull request #$number"

curl -sS --max-time 30 -X PATCH \
  -H 'Accept: application/vnd.github+json' \
  -H 'Content-Type: application/json' \
  --data '{"state":"closed"}' \
  "$BROKER_URL/github-platform/repos/smores56/homelabs-platform/pulls/$number" >/dev/null
say "closed pull request #$number"

# 5. Clean up the branches. A failed delete is reported, not fatal: the PR is
# already closed and a leftover branch is visible in Git.
for spec in \
  "github-apps/smores56/homelabs-apps" \
  "github-fork/smores56-nanobot/homelabs-platform"; do
  if ! curl -sS --max-time 30 -o /dev/null -X DELETE \
    "$BROKER_URL/$spec/git/refs/heads/$branch"; then
    say "warning: could not delete $branch from $spec"
  fi
done

say "PASS: model call, apps push, fork push and platform PR through the broker"
