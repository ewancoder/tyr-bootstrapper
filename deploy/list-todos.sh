#!/usr/bin/env bash
# Usage: list-todos.sh
# Environment variables:
#   GITHUB_REPOSITORY - current github repository, "${{ github.repository }}"

set -euo pipefail
echo "list-todos.sh v1"

if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "Mandatory environment variables are not set."
    exit 1
fi

current_sha=$(git rev-parse HEAD)

echo "=== Listing todos ==="
echo "CURRENT_SHA: $current_sha"
echo "GITHUB_REPOSITORY: $GITHUB_REPOSITORY"

# Count total TODOs
todos_count=$(grep --exclude-dir=.git -rniE ".*//[[:space:]]*todo|.*#[[:space:]]TODO" | wc -l)
echo "TODOS_COUNT=$todos_count" >> "$GITHUB_ENV"

echo "### Pending TODOs - ${todos_count}" >> "$GITHUB_STEP_SUMMARY"
echo "" >> "$GITHUB_STEP_SUMMARY"

# Find TODOs
grep --exclude-dir=.git -rniE ".*//[[:space:]]*todo|.*#[[:space:]]TODO" | while IFS= read -r line; do
    file=$(echo "$line" | awk -F: '{print $1}')
    line_number=$(echo "$line" | awk -F: '{print $2}')
    todo=$(echo "$line" | awk -F: '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF ? ":" : ""); print ""}' | awk '{$1=$1; print}')
    
    {
        echo "- \`$todo\`"
        echo "  > [$file](https://github.com/$GITHUB_REPOSITORY/blob/$current_sha/$file#L$line_number)"
        echo ""
    } >> "$GITHUB_STEP_SUMMARY"
done

