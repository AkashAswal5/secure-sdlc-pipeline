#!/bin/bash

set -euo pipefail
 # -e  Exit on error
 # -u  Undefined variables become errors
 # -o pipefail  Detect failures inside pipelines

source config/env.sh
echo -e "\n starting scan on directory $WORKSPACE"

echo "Running gitleaks"

if [ ! -d "$WORKSPACE" ]; then
    echo "Workspace not found: $WORKSPACE"
    exit 1
fi

# find gitleaks: PATH first, then tools-workspace binary (github release fallback)
if command -v gitleaks >/dev/null 2>&1; then
    GITLEAKS_BIN=$(command -v gitleaks)
elif [ -x "$TOOLS_WORKSPACE/bin/gitleaks" ]; then
    GITLEAKS_BIN="$TOOLS_WORKSPACE/bin/gitleaks"
else
    echo "Gitleaks is not installed."
    exit 1
fi

REPORT_GIT1="$REPORT_DIR/gitleaks/gitleaks_git_${TIMESTAMP}.json"
REPORT_DIR1="$REPORT_DIR/gitleaks/gitleaks_dir_${TIMESTAMP}.json"

set +e # gitleaks return non zero exit code (because it found secrets), script may exit before
# scan git repositories for secrets
# scan git repositories for secrets
"$GITLEAKS_BIN" git "$WORKSPACE" --report-format json --report-path "$REPORT_GIT1"
GIT_SCAN_EXIT_CODE=$?
# scan directory and files for secrets
"$GITLEAKS_BIN" dir "$WORKSPACE" --report-format json --report-path "$REPORT_DIR1"
DIR_SCAN_EXIT_CODE=$?

set -e

if [ "$GIT_SCAN_EXIT_CODE" -eq 0 ] && [ "$DIR_SCAN_EXIT_CODE" -eq 0 ]; then
	echo "scan completed, no issue found"
	echo "gitleaks scan completed, report generated in $REPORT_DIR"
else
	echo "gitleaks issue found, git exit code: $GIT_SCAN_EXIT_CODE, dir exit code: $DIR_SCAN_EXIT_CODE"
fi

echo -e "............. summary of gitleaks .............."
GIT_LEAK_COUNT=$(jq length "$REPORT_GIT1")
DIR_LEAK_COUNT=$(jq length "$REPORT_DIR1")
echo -e "\n total secret found in current working directory is: $DIR_LEAK_COUNT & in git history is: $GIT_LEAK_COUNT"

echo -e "\n GIT REPORT: $REPORT_GIT1"
echo -e "\n DIR REPORT: $REPORT_DIR1"

echo "gitleaks found in these files: "
jq -r '.[].File' "$REPORT_GIT1"

echo "these are the Rules IDs"
jq -r '.[].RuleID' "$REPORT_GIT1"

echo -e "\n \n "
jq -r '.[] | "\(.File) -> \(.RuleID)"' "$REPORT_GIT1"


