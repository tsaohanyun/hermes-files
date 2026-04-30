#!/bin/bash
# Auto-push files from hermes-files directory to GitHub
# Usage: bash git-push.sh "commit message"

cd /home/agentuser/hermes-files || exit 1

# Add all changes
git add -A

# Check if there are changes to commit
if git diff --cached --quiet; then
    echo "No changes to commit."
    exit 0
fi

# Commit with message or default
MSG="${1:-Auto-sync $(date '+%Y-%m-%d %H:%M')}"
git commit -m "$MSG"

# Push
GIT_TERMINAL_PROMPT=0 git push origin master 2>&1

echo "Push complete: $MSG"
