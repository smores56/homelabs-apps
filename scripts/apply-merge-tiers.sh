#!/usr/bin/env bash
# Apply the per-repository merge tiers from README.md as GitHub rulesets.
#
# Owner-run and idempotent: a ruleset is updated by name and never duplicated,
# so running this twice is a no-op. It needs a token with Administration: write
# on every repository. A repository the token cannot administer, or a private
# repository on a plan without rulesets, is reported and skipped whole; no
# repository is ever half-configured. The exit status is non-zero if an intended
# write was refused.
#
# The owner and the repository Admin role are always bypass actors, so a local
# commit by smores56 still lands directly. homelabs-agent has no bypass: it
# pushes main only where the tier says agent-writable.
set -euo pipefail

owner=${OWNER:-smores56}
owner_id=${OWNER_ID:-22140449}
admin_role_id=${ADMIN_ROLE_ID:-5}

applied=0
skipped=0
failed=0

gh api user >/dev/null || {
  echo "gh is not authenticated; run 'gh auth status'" >&2
  exit 2
}

bypass=$(
  cat <<JSON
[
  {"actor_id": $admin_role_id, "actor_type": "RepositoryRole", "bypass_mode": "always"},
  {"actor_id": $owner_id, "actor_type": "User", "bypass_mode": "always"}
]
JSON
)

agent_writable_body() { # main refuses deletion and force-push; direct pushes land
  cat <<JSON
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"}
  ],
  "bypass_actors": $bypass
}
JSON
}

review_body() { # code-owner-review extra-approval-for-unattributed-changes
  cat <<JSON
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": false,
      "required_reviewers": [],
      "require_code_owner_review": $1,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false,
      "require_extra_approval_for_unattributed_changes": $2,
      "allowed_merge_methods": ["merge", "squash", "rebase"]
    }}
  ],
  "bypass_actors": $bypass
}
JSON
}

skip() { # repo reason
  printf 'skip %s: %s\n' "$1" "$2" >&2
  skipped=$((skipped + 1))
}

apply() { # repo body
  local repo=$1 body=$2 id summary
  if ! gh api "repos/$owner/$repo" >/dev/null 2>&1; then
    skip "$repo" "not visible to this token"
    return 0
  fi
  if ! gh api "repos/$owner/$repo/rulesets" >/dev/null 2>&1; then
    skip "$repo" "rulesets API refused (private on a plan without rulesets)"
    return 0
  fi

  id=$(gh api "repos/$owner/$repo/rulesets" \
    --jq '.[] | select(.name == "main") | .id')
  if [ -n "$id" ]; then
    gh api --method PUT "repos/$owner/$repo/rulesets/$id" --input - <<<"$body" \
      >/dev/null 2>&1 || {
      printf 'FAIL %s: ruleset write refused (token needs Administration: write)\n' \
        "$repo" >&2
      failed=$((failed + 1))
      return 0
    }
  else
    gh api --method POST "repos/$owner/$repo/rulesets" --input - <<<"$body" \
      >/dev/null 2>&1 || {
      printf 'FAIL %s: ruleset create refused (token needs Administration: write)\n' \
        "$repo" >&2
      failed=$((failed + 1))
      return 0
    }
    id=$(gh api "repos/$owner/$repo/rulesets" \
      --jq '.[] | select(.name == "main") | .id')
  fi

  summary=$(gh api "repos/$owner/$repo/rulesets/$id" \
    --jq '"ruleset \(.id): rules=\([.rules[].type] | join(",")) bypass=\(.current_user_can_bypass)"')
  printf '%s %s\n' "$repo" "$summary"
  applied=$((applied + 1))
  if [ "$(gh api "repos/$owner/$repo/rulesets/$id" --jq '.current_user_can_bypass')" != "always" ]; then
    printf 'WARNING %s: the owner cannot bypass; direct pushes may be blocked\n' \
      "$repo" >&2
    failed=$((failed + 1))
  fi
}

# agent-writable: the agent pushes main directly and CI reports on the result.
apply sdlc "$(agent_writable_body)"
apply homelabs-apps "$(agent_writable_body)"

# human review: the agent's work lands on agent/* and stops at the PR.
apply nix-config "$(review_body false false)"
apply kanbei "$(review_body true true)"

# human only: no agent installation and no agent broker scope; the ruleset only
# records that main takes a PR even for other collaborators.
apply homelabs-platform "$(review_body false false)"

printf '\napplied=%d skipped=%d failed=%d\n' "$applied" "$skipped" "$failed"
[ "$failed" -eq 0 ]
