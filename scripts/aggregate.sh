#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefine variable become error
# -o pipefail detect failure inside pipelines

source config/env.sh
source lib/aggregate.sh

UNIFIED_DIR="$REPORT_DIR/unified"
mkdir -p "$UNIFIED_DIR"

echo "aggregating reports from $REPORT_DIR"
if [ -s "$RUN_MANIFEST" ]; then
	echo "mode: run manifest ($(wc -l < "$RUN_MANIFEST" | tr -d ' ') recorded reports from this run)"
else
	echo "mode: no run manifest, using newest report per tool (legacy)"
fi

# ---- discover this run's report of each tool ----
SEMGREP_REPORT=$(manifest_lookup "semgrep")
GITLEAKS_GIT_REPORT=$(manifest_lookup "gitleaks-git")
GITLEAKS_DIR_REPORT=$(manifest_lookup "gitleaks-dir")
CHECKOV_REPORT=$(manifest_lookup "checkov")
OSV_REPORT=$(manifest_lookup "osv-scanner")
TRIVY_REPORT=$(manifest_lookup "trivy")

# ---- normalize every tool into the common finding shape ----
TMP_AGG=$(mktemp -d)
trap 'rm -rf "$TMP_AGG"' EXIT

normalize_semgrep "$SEMGREP_REPORT" > "$TMP_AGG/semgrep.json"
normalize_gitleaks "$GITLEAKS_GIT_REPORT" "$GITLEAKS_DIR_REPORT" > "$TMP_AGG/gitleaks.json"
normalize_checkov "$CHECKOV_REPORT" > "$TMP_AGG/checkov.json"
normalize_osv "$OSV_REPORT" > "$TMP_AGG/osv-scanner.json"
normalize_trivy "$TRIVY_REPORT" > "$TMP_AGG/trivy.json"

jq -s 'add // []' "$TMP_AGG"/*.json > "$TMP_AGG/all_findings.json"

# attach a category to every finding (secrets / dependency / api / code / infrastructure)
categorize_findings < "$TMP_AGG/all_findings.json" > "$TMP_AGG/categorized.json"
mv "$TMP_AGG/categorized.json" "$TMP_AGG/all_findings.json"

TOTAL_FINDINGS=$(jq 'length' "$TMP_AGG/all_findings.json")
VERDICT="PASS"
if [ "$TOTAL_FINDINGS" -gt 0 ]; then
	VERDICT="FAIL"
fi

# ---- build the unified json report ----
UNIFIED_JSON="$UNIFIED_DIR/unified_report_${TIMESTAMP}.json"

# build one {tool: {status, findings}} json fragment per tool
tool_status_json() {
	local t="$1" report_var status
	local count
	count=$(jq --arg t "$t" '[.[] | select(.tool == $t)] | length' "$TMP_AGG/all_findings.json")
	case "$t" in
	semgrep) report_var="$SEMGREP_REPORT" ;;
	gitleaks) report_var="$GITLEAKS_GIT_REPORT$GITLEAKS_DIR_REPORT" ;;
	checkov) report_var="$CHECKOV_REPORT" ;;
	osv-scanner) report_var="$OSV_REPORT" ;;
	trivy) report_var="$TRIVY_REPORT" ;;
	esac
	status="ran"
	if [ -z "$report_var" ]; then
		status="not_run"
	fi
	jq -nc --arg t "$t" --arg s "$status" --argjson c "$count" '{($t): {status: $s, findings: $c}}'
}

TOOLS_JSON=$(for t in semgrep gitleaks checkov osv-scanner trivy; do tool_status_json "$t"; done | jq -sc 'add')

jq -n \
	--arg repo_url "${REPO_URL:-unknown}" \
	--arg timestamp "$TIMESTAMP" \
	--arg pm "${PACKAGE_MANAGER:-unknown}" \
	--arg verdict "$VERDICT" \
	--argjson total "$TOTAL_FINDINGS" \
	--argjson tools "$TOOLS_JSON" \
	--slurpfile findings "$TMP_AGG/all_findings.json" '
	{
		metadata: {
			repo_url: $repo_url,
			timestamp: $timestamp,
			package_manager: $pm
		},
		summary: {
			verdict: $verdict,
			total_findings: $total,
			severity: (reduce $findings[0][] as $f (
				{Critical: 0, High: 0, Medium: 0, Low: 0, Unknown: 0};
				.[$f.severity] = (.[$f.severity] + 1)
			)),
			categories: (reduce $findings[0][] as $f (
				{secrets: 0, dependency: 0, api: 0, code: 0, infrastructure: 0};
				.[$f.category] = (.[$f.category] + 1)
			)),
			tools: $tools
		},
		findings: ($findings[0] // [])
	}' > "$UNIFIED_JSON"

# ---- build the unified markdown report ----
UNIFIED_MD="$UNIFIED_DIR/unified_report_${TIMESTAMP}.md"

{
	echo "# Unified Security Report"
	echo
	echo "- **Repo:** $(jq -r '.metadata.repo_url' "$UNIFIED_JSON")"
	echo "- **Date:** $(jq -r '.metadata.timestamp' "$UNIFIED_JSON")"
	echo "- **Package manager:** $(jq -r '.metadata.package_manager' "$UNIFIED_JSON")"
	echo "- **Verdict:** **$VERDICT** ($TOTAL_FINDINGS findings)"
	echo
	echo "## Severity rollup"
	echo
	echo "| Critical | High | Medium | Low | Unknown |"
	echo "| --- | --- | --- | --- | --- |"
	jq -r '.summary.severity | "| \(.Critical) | \(.High) | \(.Medium) | \(.Low) | \(.Unknown) |"' "$UNIFIED_JSON"
	echo
	echo "## Tools"
	echo
	echo "| Tool | Status | Findings |"
	echo "| --- | --- | --- |"
	for t in semgrep gitleaks checkov osv-scanner trivy; do
		jq -r --arg t "$t" '.summary.tools[$t] | "| \($t) | \(.status) | \(.findings) |"' "$UNIFIED_JSON"
	done
	echo
	echo "## Findings"
	for t in semgrep gitleaks checkov osv-scanner trivy; do
		count=$(jq -r --arg t "$t" '.summary.tools[$t].findings' "$UNIFIED_JSON")
		if [ "$count" = "0" ] || [ "$count" = "null" ]; then
			continue
		fi
		echo
		echo "### $t ($count)"
		echo
		echo "| Severity | ID | Location | Description |"
		echo "| --- | --- | --- | --- |"
		jq -r --arg t "$t" \
			'.findings[] | select(.tool == $t) |
			"| \(.severity) | \(.id) | \(.location) | \(.title) |" |
			gsub("[\n\r\t]"; " ")' "$UNIFIED_JSON"
	done
} > "$UNIFIED_MD"

# ---- per-category report files (api / code / secrets / dependency / infrastructure) ----
for cat in secrets dependency api code infrastructure; do
	cat_json="$UNIFIED_DIR/${cat}_findings_${TIMESTAMP}.json"
	cat_md="$UNIFIED_DIR/${cat}_findings_${TIMESTAMP}.md"
	jq --arg c "$cat" '[.[] | select(.category == $c)] | {category: $c, count: length, findings: .}' \
		"$TMP_AGG/all_findings.json" > "$cat_json"
	{
		echo "# $(category_title "$cat")"
		echo
		echo "$(jq --arg c "$cat" '[.[] | select(.category == $c)] | length' "$TMP_AGG/all_findings.json") findings"
		echo
		echo "| Severity | Tool | ID | Location | Description |"
		echo "| --- | --- | --- | --- | --- |"
		jq -r --arg c "$cat" \
			'.[] | select(.category == $c) |
			"| \(.severity) | \(.tool) | \(.id) | \(.location) | \(.title) |" |
			gsub("[\n\r\t]"; " ")' "$TMP_AGG/all_findings.json"
	} > "$cat_md"
done

# ---- console summary + gate ----
echo -e "............. unified report .............."
echo "verdict: $VERDICT ($TOTAL_FINDINGS findings)"
jq -r '.summary.tools | to_entries[] | "  \(.key): \(.value.status) - \(.value.findings) findings"' "$UNIFIED_JSON"
jq -r '.summary.severity | "  severity: critical=\(.Critical) high=\(.High) medium=\(.Medium) low=\(.Low) unknown=\(.Unknown)"' "$UNIFIED_JSON"
jq -r '.summary.categories | to_entries[] | "  category \(.key): \(.value) findings"' "$UNIFIED_JSON"
echo "category reports in $UNIFIED_DIR:"
for cat in secrets dependency api code infrastructure; do
	echo "  $cat: $UNIFIED_DIR/${cat}_findings_${TIMESTAMP}.json / .md"
done
echo "unified json: $UNIFIED_JSON"
echo "unified markdown: $UNIFIED_MD"

if [ "$VERDICT" = "FAIL" ]; then
	echo "pipeline gate: FAIL - findings detected"
	exit 1
fi

echo "pipeline gate: PASS - no findings"
exit 0
