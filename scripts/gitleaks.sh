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
mkdir -p "$REPORT_DIR/gitleaks"

# gitleaks exits non-zero when it finds secrets, capture exit codes manually
set +e

# working-directory scan (always runs)
"$GITLEAKS_BIN" dir "$WORKSPACE" --report-format json --report-path "$REPORT_DIR1"
DIR_SCAN_EXIT_CODE=$?

# git-history scan: scan the workspace itself when it is a repo, plus every
# embedded repo (multi-repo scans copy a folder of repos into the workspace)
TMP_GIT=$(mktemp -d)
repos=""
if [ -d "$WORKSPACE/.git" ]; then
	repos="$WORKSPACE"
fi
# direct children and depth-2 children (nested module repos)
for dotgit in "$WORKSPACE"/*/.git "$WORKSPACE"/*/*/.git; do
	[ -e "$dotgit" ] || continue
	repo_dir=$(dirname "$dotgit")
	if [ "$repo_dir" = "$WORKSPACE" ]; then
		continue # already added above
	fi
	repos="$repos
$repo_dir"
done

GIT_SCAN_EXIT_CODE=0
repo_count=0
while IFS= read -r repo; do
	[ -n "$repo" ] || continue
	repo_count=$((repo_count + 1))
	echo "gitleaks git scan: $repo"
	"$GITLEAKS_BIN" git "$repo" --report-format json --report-path "$TMP_GIT/$repo_count.json"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		GIT_SCAN_EXIT_CODE=$rc
	fi
	# rewrite File paths to be workspace-relative (gitleaks reports them
	# repo-relative) so report locations stay consistent
	if [ -s "$TMP_GIT/$repo_count.json" ]; then
		rel=${repo#$WORKSPACE/}
		jq --arg p "$rel/" 'map(if (.File // "") | startswith($p) | not then .File = ($p + (.File // "")) else . end)' \
			"$TMP_GIT/$repo_count.json" > "$TMP_GIT/$repo_count.json.tmp" && mv "$TMP_GIT/$repo_count.json.tmp" "$TMP_GIT/$repo_count.json"
	fi
done <<EOF
$repos
EOF

# merge all per-repo git reports into one
if [ "$repo_count" -eq 0 ]; then
	echo "no git repositories found under $WORKSPACE, skipping git history scan"
	echo "[]" > "$REPORT_GIT1"
else
	git_jsons=$(find "$TMP_GIT" -name '*.json' -type f)
	if [ -n "$git_jsons" ]; then
		jq -s 'add // []' $git_jsons > "$REPORT_GIT1"
	else
		echo "[]" > "$REPORT_GIT1"
	fi
fi
rm -rf "$TMP_GIT"

set -e

# record the report paths for the aggregator (phase 6)
mkdir -p "$REPORT_DIR"
[ -s "$REPORT_GIT1" ] && echo "gitleaks-git|$REPORT_GIT1" >> "$RUN_MANIFEST"
[ -s "$REPORT_DIR1" ] && echo "gitleaks-dir|$REPORT_DIR1" >> "$RUN_MANIFEST"

if [ "$GIT_SCAN_EXIT_CODE" -eq 0 ] && [ "$DIR_SCAN_EXIT_CODE" -eq 0 ]; then
	echo "scan completed, no issue found"
	echo "gitleaks scan completed, report generated in $REPORT_DIR"
else
	echo "gitleaks issue found, git exit code: $GIT_SCAN_EXIT_CODE, dir exit code: $DIR_SCAN_EXIT_CODE"
fi

echo -e "............. summary of gitleaks .............."
GIT_LEAK_COUNT=$(jq length "$REPORT_GIT1")
DIR_LEAK_COUNT=$(jq length "$REPORT_DIR1")
echo -e "\n total secret found in current working directory is: $DIR_LEAK_COUNT & in git history of $repo_count repositories is: $GIT_LEAK_COUNT"

echo -e "\n GIT REPORT: $REPORT_GIT1"
echo -e "\n DIR REPORT: $REPORT_DIR1"

if [ "$GIT_LEAK_COUNT" -gt 0 ]; then
	echo "gitleaks found in these files: "
	jq -r '.[].File' "$REPORT_GIT1"

	echo "these are the Rules IDs"
	jq -r '.[].RuleID' "$REPORT_GIT1"

	echo -e "\n \n "
	jq -r '.[] | "\(.File) -> \(.RuleID)"' "$REPORT_GIT1"
fi

echo -e "\n \n "
