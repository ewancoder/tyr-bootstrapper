#!/usr/bin/env bash
# Usage: list-todos.sh
# Environment variables:
#   GITHUB_REPOSITORY - current github repository, "${{ github.repository }}"
# This script will append TODOs to $GITHUB_STEP_SUMMARY.
# And we place amount of TODOs to $TODOS_COUNT ($GITHUB_ENV).

set -euo pipefail

if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "Mandatory environment variables are not set."
    exit 1
fi

current_sha=$(git rev-parse HEAD)

echo "=== Listing todos ==="
echo "CURRENT_SHA: $current_sha"
echo "GITHUB_REPOSITORY: $GITHUB_REPOSITORY"

# Count total TODOs.
# grep -rniE - lists all found matches with their line numbers in a separate column.
# We use wc -l to count the lines/matches.
# TODOs patterns (case-insensitive, anything before/after, any amount of spaces):
#   - //todo, // todo
#   - #todo, # todo
todos_count=$(grep --exclude-dir=.git --recursive --line-number --ignore-case --extended-regexp ".*//[[:space:]]*todo|.*#[[:space:]]*todo" | wc -l)
echo "TODOS_COUNT=$todos_count" >> "$GITHUB_ENV"

echo "### Pending TODOs - ${todos_count}" >> "$GITHUB_STEP_SUMMARY"
echo "" >> "$GITHUB_STEP_SUMMARY"

# Find TODOs
grep --exclude-dir=.git -rniE ".*//[[:space:]]*todo|.*#[[:space:]]*todo" | while IFS= read -r line; do
    file=$(echo "$line" | awk -F: '{print $1}') # File path of the TODO.
    line_number=$(echo "$line" | awk -F: '{print $2}') # Line number of the TODO.

    # Text of the TODO (cutting file path and line number from it).
    todo=$(echo "$line" | awk -F: '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF ? ":" : ""); print ""}' | awk '{$1=$1; print}')
    
    {
        echo "- \`$todo\`" # Text of the todo.
        # URL of the file including line numbers, so we can click on it and view conviniently.
        echo "  > [$file](https://github.com/$GITHUB_REPOSITORY/blob/$current_sha/$file#L$line_number)"
        echo ""
    } >> "$GITHUB_STEP_SUMMARY"
done
