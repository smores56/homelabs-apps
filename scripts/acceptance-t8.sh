#!/usr/bin/env bash
# T8 acceptance test (smores56/sdlc#582), run inside the nanobot pod.
#
# Proves the whole path end to end: the broker injects the Neuralwatt key, git
# pushes reach homelabs-apps, an agent/* branch reaches homelabs-platform, and a
# same-repo pull request opens - all without the agent holding a credential. The
# broker mints GitHub App installation tokens; this process never sees one.
#
#   cluster-kubectl -n tenant-apps exec deploy/nanobot -- \
#     bash scripts/acceptance-t8.sh
#
# Preconditions: homelabs-platform docs/manual-steps.md steps 1 and 10 (the
# homelabs-agent app installed, its files in the broker Secret). The PR
# and its branch are deleted afterwards.
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
branch="agent/acceptance-${stamp}"
identity=(-c user.name='homelabs-agent[bot]' -c user.email='356043151+homelabs-agent[bot]@users.noreply.github.com')
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
git -C "$work/apps" "${identity[@]}" commit -q -m "test: broker acceptance $stamp"
git -C "$work/apps" remote add broker "$BROKER_URL/github-apps/smores56/homelabs-apps.git"
git -C "$work/apps" push -q broker "$branch"
say "pushed $branch"

# 3. The same branch in homelabs-platform, through github-platform-push. The
# ruleset admits the app only on agent/*.
say "== push an agent branch to homelabs-platform"
git clone -q "$BROKER_URL/github-platform-push/smores56/homelabs-platform.git" "$work/platform"
git -C "$work/platform" checkout -q -b "$branch"
mkdir -p "$work/platform/docs/acceptance"
printf 'broker acceptance %s\n' "$stamp" >"$work/platform/docs/acceptance/$stamp.md"
git -C "$work/platform" add "docs/acceptance/$stamp.md"
git -C "$work/platform" "${identity[@]}" commit -q -m "test: broker acceptance $stamp"
git -C "$work/platform" remote set-url origin "$BROKER_URL/github-platform-push/smores56/homelabs-platform.git"
git -C "$work/platform" push -q origin "$branch"

# 4. Open the same-repo pull request through github-platform, then close it and
# delete both branches. The token is the broker's; this process never sees it.
say "== open the platform pull request"
payload=$(printf '{"title":"test: broker acceptance %s","head":"%s","base":"main","body":"Automated T8 acceptance. Close without review."}' "$stamp" "$branch")
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

# 5. Negative probes. A success here means a control disappeared, so the run
#    fails and the ref is removed rather than left behind.
say "== the app cannot push outside agent/*"
if git -C "$work/platform" push -q origin "HEAD:probe/denied-$stamp" 2>"$work/probe1.err"; then
  git -C "$work/platform" push -q origin ":probe/denied-$stamp" || true
  fail "the push to probe/denied-$stamp succeeded; the ruleset does not confine the app"
fi
say "refused: $(head -c 200 "$work/probe1.err")"

# The app's Workflows permission (No access) does NOT gate pushes: on
# 2026-11-12 an installation token with contents:write pushed a workflow edit to
# an agent/* branch. The control for `.github/` changes is the Code Owners
# review required on main, not this token.

# 5. Clean up the branches over the git transport. A failed delete is reported,
# not fatal: the PR is already closed and a leftover branch is visible in Git.
if ! git -C "$work/apps" push -q broker ":$branch"; then
  say "warning: could not delete $branch from homelabs-apps"
fi
if ! git -C "$work/platform" push -q origin ":$branch"; then
  say "warning: could not delete $branch from homelabs-platform"
fi

say "PASS: model call, apps push, agent branch and same-repo PR through the broker"
