#!/usr/bin/env bash
# setup-environments.sh <owner/repo> [prod_branch] [stage_branch]
#
# Defines a custom-code repo's GitHub environments and cleans up the stale
# records left behind by the Vercel Git integration (vercel[bot]):
#   - deletes the `Production` / `Preview` environments Vercel created
#   - purges orphaned deployment records (deleting an environment does NOT
#     delete its deployments; the repo's Deployments view keeps showing them)
#   - creates `production` (branch policy: <prod_branch>) and
#     `stage` (branch policy: <stage_branch>) with deployment branch policies
#
# 3-env repo (main + production): prod_branch=production, stage_branch=main  (default)
# 2-env repo (main only):         prod_branch=main       -> no `stage` env
#
# The deploy.yml reusable records deploys into these environments when the
# caller grants `deployments: write`. Idempotent: safe to re-run.
#
# Requires: gh authenticated with admin on the repo.
#
# WARNING: only run this on repos whose deployment history is purely stale
# vercel[bot] failures. Repos with real/active deployments (created by users or
# github-actions) must NOT be purged — check the creators/states first:
#   gh api "repos/<owner>/<repo>/deployments" --jq '[.[].creator.login] | unique'
set -euo pipefail

REPO="${1:?usage: setup-environments.sh <owner/repo> [prod_branch] [stage_branch]}"
PROD_BRANCH="${2:-production}"
STAGE_BRANCH="${3:-main}"

echo "== $REPO =="

# 1) Delete the stale Vercel environments.
for env in Production Preview; do
  if gh api -X DELETE "repos/$REPO/environments/$env" >/dev/null 2>&1; then
    echo "  - deleted stale environment: $env"
  fi
done

# 1b) Purge orphaned deployment records (the red vercel[bot] entries; deleting
#     the environment does not remove them). GitHub requires marking a
#     deployment inactive before it can be deleted.
for id in $(gh api "repos/$REPO/deployments?per_page=100" --jq '.[].id' 2>/dev/null); do
  gh api -X POST "repos/$REPO/deployments/$id/statuses" -f state=inactive >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/deployments/$id" >/dev/null 2>&1 \
    && echo "  - deleted orphaned deployment: $id" || true
done

# 2) Create our environments with a deployment branch policy.
create_env() {
  local name="$1" branch="$2"
  printf '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
    | gh api -X PUT "repos/$REPO/environments/$name" --input - >/dev/null
  # Clear any existing branch policies so the script is idempotent.
  for id in $(gh api "repos/$REPO/environments/$name/deployment-branch-policies" --jq '.branch_policies[]?.id' 2>/dev/null); do
    gh api -X DELETE "repos/$REPO/environments/$name/deployment-branch-policies/$id" >/dev/null 2>&1 || true
  done
  printf '{"name":"%s","type":"branch"}' "$branch" \
    | gh api -X POST "repos/$REPO/environments/$name/deployment-branch-policies" --input - >/dev/null
  echo "  + environment: $name  (branch policy: $branch)"
}

create_env production "$PROD_BRANCH"
if [ "$PROD_BRANCH" != "$STAGE_BRANCH" ]; then
  create_env stage "$STAGE_BRANCH"
fi

echo "-- result --"
gh api "repos/$REPO/environments" --jq '.environments[] | "  \(.name)"'
