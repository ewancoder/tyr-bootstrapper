#!/usr/bin/env bash
# Usage: check-changes.sh module1 module2 module3
# Example: ./check-changes.sh web api db
# Environment variables:
#   PREVIOUS_SHA - previous commit SHA, "${{ github.event.before }}"
#   GITHUB_TOKEN - github access token, "${{ secrets.GITHUB_TOKEN }}"
#   GITHUB_REPOSITORY - current github repository, "${{ github.repository }}"
#   GITHUB_API_URL - github API url, "${{ github.api_url }}"
#   GITHUB_REF - current branch/tag, "${{ github.ref }}"
# This script will place module1=true module2=false etc variables into $GITHUB_OUTPUT.

# TODO: Filter out CURRENT deployment by deployment ID or by something, when checking last deployment status.

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "No modules provided."
    exit 1
fi

if [ -z "${PREVIOUS_SHA:-}" ] \
    || [ -z "${GITHUB_TOKEN:-}" ] \
    || [ -z "${GITHUB_REPOSITORY:-}" ] \
    || [ -z "${GITHUB_API_URL:-}" ] \
    || [ -z "${GITHUB_REF:-}" ]; then
    echo "Mandatory environment variables are not set."
    exit 1
fi

modules=("$@")
current_sha=$(git rev-parse HEAD)

echo "=== Checking changes ==="
echo "PREVIOUS_SHA: $PREVIOUS_SHA"
echo "CURRENT_SHA: $current_sha"
echo "GITHUB_REF: $GITHUB_REF"
echo "GITHUB_REPOSITORY: $GITHUB_REPOSITORY"
echo "GITHUB_API_URL: $GITHUB_API_URL"
echo "GITHUB_TOKEN: ***"
echo "modules: ${modules[*]}"

# First ever push, or force-push with commits overwriting, will have PREVIOUS_SHA = "0000...".
# PREVIOUS_SHA will also be "0000..." for any tags, so for tags we always deploy all modules.
if [ -z "$PREVIOUS_SHA" ] || [[ "$PREVIOUS_SHA" == "0000000000000000000000000000000000000000" ]]; then
    echo "First push. Deploying all modules."
    for module in "${modules[@]}"; do
        echo "$module=true" >> "$GITHUB_OUTPUT"
    done
    exit 0
fi

# We check which files have changed between previous and current builds, and place that info into 'diff' file.
# If the diff itself fails for any reason - we deploy everything.
if ! git diff --name-only "$PREVIOUS_SHA" HEAD > diff; then
    echo "Git diff failed. Deploying all modules."
    for module in "${modules[@]}"; do
        echo "$module=true" >> "$GITHUB_OUTPUT"
    done
    exit 0
fi

# If any of the repository-wide important files have changed - we deploy everything.
# These files include:
#   - Anything in .github/* folder
#   - docker-compose*/swarm-compose* files
#   - .env* files
if grep -qE '^(.github|docker-compose|.env|swarm-compose)' diff; then
    echo "Critical workflow/config files changed. Deploying all modules."
    for module in "${modules[@]}"; do
        echo "$module=true" >> "$GITHUB_OUTPUT"
    done
    exit 0
fi

# Get last run status from GitHub API.
# GITHUB_REF looks like "refs/heads/main", we strip the first part leaving only "main".
# We get latest GitHub Actions run for this ref.
# This will not work for tags, so for tags we will not have any conclusions
# and we will deploy everything every time.
# This makes sense for tags because we have no idea what the previous release contained.
# If last run failed - we deploy everything.
branch=$(echo "${GITHUB_REF}" | sed 's#refs/heads/##')
last_run=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/runs?status=completed&branch=$branch&per_page=2")
last_conclusion=$(echo "$last_run" | jq -r '.workflow_runs | sort_by(.created_at) | reverse | .[0].conclusion')
echo "Last run conclusion: $last_conclusion"
if [ "$last_conclusion" != "null" ] && [ "$last_conclusion" != "success" ]; then
    echo "Last run failed. Deploying all modules."
    for module in "${modules[@]}"; do
        echo "$module=true" >> "$GITHUB_OUTPUT"
    done
    exit 0
fi

# We check each module against the 'diff' file generated earlier.
# If any of the files within 'modulename/*' folder have changed - we deploy this module.
for module in "${modules[@]}"; do
    if grep -q "^${module}/" diff; then
        echo "$module changed. Deploying $module."
        echo "$module=true" >> "$GITHUB_OUTPUT"
    fi
done
