#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefine variable become error
# -o pipefail detect failure inside pipelines

source config/env.sh
source lib/aggregate.sh
source lib/sarif.sh

UNIFIED_DIR="$REPORT_DIR/unified"
mkdir -p "$UNIFIED_DIR"

# scan duration: pipeline.sh writes the run start epoch next to the manifest
RUN_START=$(cat "$REPORT_DIR/.run_start" 2>/dev/null || echo "")
if [ -n "$RUN_START" ] && [ "$RUN_START" -gt 0 ] 2>/dev/null; then
	DURATION=$(( $(date +%s) - RUN_START ))
else
	DURATION=0
fi

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

# make locations repo-relative for readable reports
relativize_locations < "$TMP_AGG/all_findings.json" > "$TMP_AGG/relativized.json"
mv "$TMP_AGG/relativized.json" "$TMP_AGG/all_findings.json"

# tag every finding with its top-level component (repo in multi-repo scans)
add_components < "$TMP_AGG/all_findings.json" > "$TMP_AGG/components.json"
mv "$TMP_AGG/components.json" "$TMP_AGG/all_findings.json"

# ---- phase 8: fingerprints, dedup, triage state ----

# stable fingerprints (tool + rule + file): power dedup, suppressions, baseline, sarif
add_fingerprints < "$TMP_AGG/all_findings.json" > "$TMP_AGG/fingerprinted.json"
mv "$TMP_AGG/fingerprinted.json" "$TMP_AGG/all_findings.json"

# collapse cross-scanner duplicates (same id at the same location) so summary
# counts are trustworthy - trivy and osv-scanner routinely report the same advisory
RAW_COUNT=$(jq 'length' "$TMP_AGG/all_findings.json")
dedup_findings < "$TMP_AGG/all_findings.json" > "$TMP_AGG/deduped.json"
mv "$TMP_AGG/deduped.json" "$TMP_AGG/all_findings.json"
DUPLICATES_REMOVED=$((RAW_COUNT - $(jq 'length' "$TMP_AGG/all_findings.json")))

# suppressions: {"suppressed": [{fingerprint, reason, expires}]}; expired entries re-alert
SUPPRESSIONS_JSON="[]"
if [ -f "$SUPPRESSIONS_FILE" ]; then
	if jq -e '(.suppressed | type) == "array"' "$SUPPRESSIONS_FILE" >/dev/null 2>&1; then
		SUPPRESSIONS_JSON=$(jq -c '.suppressed // []' "$SUPPRESSIONS_FILE")
	else
		echo "warning: $SUPPRESSIONS_FILE is malformed (expected {\"suppressed\": [...]}), ignoring suppressions"
	fi
fi
apply_suppressions "$SUPPRESSIONS_JSON" "$(date +%F)" < "$TMP_AGG/all_findings.json" > "$TMP_AGG/suppressed_marked.json"
mv "$TMP_AGG/suppressed_marked.json" "$TMP_AGG/all_findings.json"

# baseline: known findings do not fail the gate, only NEW ones do -
# the adoption path for brownfield repos
BASELINE_JSON="[]"
BASELINE_STATUS="none"
if [ -f "$BASELINE_FILE" ]; then
	if jq -e '(.fingerprints | type) == "array"' "$BASELINE_FILE" >/dev/null 2>&1; then
		BASELINE_JSON=$(jq -c '.fingerprints // []' "$BASELINE_FILE")
		BASELINE_STATUS="active"
	else
		echo "warning: $BASELINE_FILE is malformed (expected {\"fingerprints\": [...]}), ignoring baseline"
	fi
fi
apply_baseline "$BASELINE_JSON" < "$TMP_AGG/all_findings.json" > "$TMP_AGG/baselined.json"
mv "$TMP_AGG/baselined.json" "$TMP_AGG/all_findings.json"

# split active (gate-relevant) from suppressed; from here on all_findings.json
# holds ONLY the active findings, suppressed ones move to suppressed.json
jq '[.[] | select(.suppressed // false | not)]' "$TMP_AGG/all_findings.json" > "$TMP_AGG/active.json"
jq '[.[] | select(.suppressed // false)]' "$TMP_AGG/all_findings.json" > "$TMP_AGG/suppressed.json"
mv "$TMP_AGG/active.json" "$TMP_AGG/all_findings.json"

TOTAL_FINDINGS=$(jq 'length' "$TMP_AGG/all_findings.json")
KNOWN_COUNT=$(jq '[.[] | select(.known)] | length' "$TMP_AGG/all_findings.json")
SUPPRESSED_COUNT=$(jq 'length' "$TMP_AGG/suppressed.json")
NEW_FINDINGS=$((TOTAL_FINDINGS - KNOWN_COUNT))
VERDICT="PASS"
if [ "$NEW_FINDINGS" -gt 0 ]; then
	VERDICT="FAIL"
fi

# write a fresh baseline when requested (./pipeline.sh <repo> --baseline)
if [ "${CREATE_BASELINE:-0}" = "1" ]; then
	mkdir -p "$(dirname "$BASELINE_FILE")"
	jq --arg ts "$TIMESTAMP" --arg repo "${REPO_URL:-unknown}" \
		'{created: $ts, repo: $repo, fingerprints: (map(.fingerprint) | unique)}' \
		"$TMP_AGG/all_findings.json" > "$BASELINE_FILE"
	echo "baseline written: $BASELINE_FILE ($TOTAL_FINDINGS active finding fingerprints)"
	BASELINE_STATUS="written"
fi

# ---- SARIF 2.1.0 output: upload to github code scanning for PR annotations ----
SARIF_DIR="$REPORT_DIR/sarif"
mkdir -p "$SARIF_DIR"
for tool in semgrep gitleaks checkov osv-scanner trivy; do
	jq --arg t "$tool" '[.[] | select(.tool == $t)]' "$TMP_AGG/all_findings.json" > "$TMP_AGG/sarif_$tool.json"
	findings_to_sarif "$tool" "$TMP_AGG/sarif_$tool.json" "$SARIF_DIR/$tool.sarif"
done

# scanner versions for report metadata (auditable reports)
TOOL_VERSIONS=$(collect_tool_versions)

# ---- build the unified json report ----
UNIFIED_JSON="$UNIFIED_DIR/unified_report_${TIMESTAMP}.json"

# build one {tool: {status, findings}} json fragment per tool
# counts include deduped findings the tool co-reported (.scanners membership)
tool_status_json() {
	local t="$1" report_var status
	local count
	count=$(jq --arg t "$t" '[.[] | select(.tool == $t or ((.scanners // []) | index($t) != null))] | length' "$TMP_AGG/all_findings.json")
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
	--arg workspace "${WORKSPACE:-unknown}" \
	--arg timestamp "$TIMESTAMP" \
	--arg pm "${PACKAGE_MANAGER:-unknown}" \
	--arg verdict "$VERDICT" \
	--arg baseline "$BASELINE_STATUS" \
	--arg baseline_file "$BASELINE_FILE" \
	--arg suppressions_file "$SUPPRESSIONS_FILE" \
	--argjson versions "$TOOL_VERSIONS" \
	--argjson duration "$DURATION" \
	--argjson total "$TOTAL_FINDINGS" \
	--argjson known "$KNOWN_COUNT" \
	--argjson new "$NEW_FINDINGS" \
	--argjson suppressed_count "$SUPPRESSED_COUNT" \
	--argjson duplicates "$DUPLICATES_REMOVED" \
	--argjson tools "$TOOLS_JSON" \
	--slurpfile findings "$TMP_AGG/all_findings.json" \
	--slurpfile suppressed "$TMP_AGG/suppressed.json" '
	{
		metadata: {
			repo_url: $repo_url,
			workspace: $workspace,
			timestamp: $timestamp,
			duration_sec: $duration,
			package_manager: $pm,
			tool_versions: $versions,
			baseline: {status: $baseline, file: $baseline_file},
			suppressions_file: $suppressions_file
		},
		summary: {
			verdict: $verdict,
			total_findings: $total,
			known_findings: $known,
			new_findings: $new,
			suppressed_findings: $suppressed_count,
			duplicates_removed: $duplicates,
			severity: (reduce $findings[0][] as $f (
				{Critical: 0, High: 0, Medium: 0, Low: 0, Unknown: 0};
				.[$f.severity] = (.[$f.severity] + 1)
			)),
			categories: (reduce $findings[0][] as $f (
				{secrets: 0, dependency: 0, api: 0, code: 0, infrastructure: 0};
				.[$f.category] = (.[$f.category] + 1)
			)),
			components: (reduce $findings[0][] as $f (
				{};
				.[$f.component] = ((.[$f.component] // 0) + 1)
			)),
			tools: $tools
		},
		findings: ($findings[0] // []),
		suppressed_findings: ($suppressed[0] // [])
	}' > "$UNIFIED_JSON"

# ---- build the unified markdown report (executive style) ----
UNIFIED_MD="$UNIFIED_DIR/unified_report_${TIMESTAMP}.md"

{
	echo "# Unified Security Report"
	echo
	echo "- **Repo:** $(jq -r '.metadata.repo_url' "$UNIFIED_JSON")"
	echo "- **Date:** $(jq -r '.metadata.timestamp' "$UNIFIED_JSON")"
	echo "- **Package manager:** $(jq -r '.metadata.package_manager' "$UNIFIED_JSON")"
	if [ "$DURATION" -gt 0 ]; then
		echo "- **Scan duration:** $((DURATION / 60))m $((DURATION % 60))s"
	fi
	echo "- **Verdict:** **$VERDICT** ($NEW_FINDINGS new findings, $KNOWN_COUNT known, $SUPPRESSED_COUNT suppressed, $DUPLICATES_REMOVED duplicates removed)"
	echo
	echo "## Triage"
	echo
	echo "_Suppressed and baseline-known findings do not fail the gate — only new findings do._"
	echo
	echo "| State | Findings |"
	echo "| --- | --- |"
	echo "| New (fail the gate) | $NEW_FINDINGS |"
	echo "| Known (in baseline) | $KNOWN_COUNT |"
	echo "| Suppressed | $SUPPRESSED_COUNT |"
	if [ "$DUPLICATES_REMOVED" -gt 0 ]; then
		echo "| Duplicate reports removed | $DUPLICATES_REMOVED |"
	fi
	echo
	if [ "$SUPPRESSED_COUNT" -gt 0 ]; then
		echo "### Suppressed findings"
		echo
		echo "| Fingerprint | Reason |"
		echo "| --- | --- |"
		jq -r '.[] | "| \(.fingerprint) | \(.suppression_reason) |"' "$TMP_AGG/suppressed.json"
		echo
	fi
	echo "## Categories"
	echo
	echo "| Category | Findings |"
	echo "| --- | --- |"
	for cat in secrets dependency api code infrastructure; do
		jq -rn --arg c "$cat" \
			--argjson n "$(jq --arg c "$cat" '[.[] | select(.category == $c)] | length' "$TMP_AGG/all_findings.json")" \
			'"| \($c) | \($n) |"'
	done
	echo
	echo "## Severity"
	echo
	echo "| Critical | High | Medium | Low | Unknown |"
	echo "| --- | --- | --- | --- | --- |"
	jq -r '.summary.severity | "| \(.Critical) | \(.High) | \(.Medium) | \(.Low) | \(.Unknown) |"' "$UNIFIED_JSON"
	echo
	echo "## Findings by component"
	echo
	echo "_Top-level directories (the repos in a multi-repo scan) — focus remediation where counts are highest._"
	echo
	echo "| Component | Findings |"
	echo "| --- | --- |"
	jq -r 'group_by(.component)
		| map({component: .[0].component, count: length})
		| sort_by(-.count) | .[0:25][]
		| "| \(.component) | \(.count) |"' "$TMP_AGG/all_findings.json"
	echo
	echo "## Top offenders"
	echo
	echo "_Locations with the most findings — fix these first._"
	echo
	echo "| Location | Findings |"
	echo "| --- | --- |"
	jq -r 'group_by(.location)
		| map({location: .[0].location, count: length})
		| sort_by(-.count) | .[0:10][]
		| "| \(.location) | \(.count) |"' "$TMP_AGG/all_findings.json"
	echo
	echo "## Critical findings"
	echo
	CRIT_COUNT=$(jq '[.[] | select(.severity == "Critical")] | length' "$TMP_AGG/all_findings.json")
	if [ "$CRIT_COUNT" -eq 0 ]; then
		echo "_None._"
	else
		jq -r '.[] | select(.severity == "Critical")
			| (.title | if length > 80 then .[:77] + "..." else . end) as $t
			| "- **\(.id)** — \(.location) (\($t))"' "$TMP_AGG/all_findings.json"
	fi
	echo
	echo "## Tools"
	echo
	echo "| Tool | Status | Findings |"
	echo "| --- | --- | --- |"
	for t in semgrep gitleaks checkov osv-scanner trivy; do
		jq -r --arg t "$t" '.summary.tools[$t] | "| \($t) | \(.status) | \(.findings) |"' "$UNIFIED_JSON"
	done
	echo
	echo "## Detailed findings"
	echo
	echo "_Every finding (full IDs, full descriptions) is in the category report files:_"
	echo
	for cat in secrets dependency api code infrastructure; do
		echo "- $(category_title "$cat"): \`${cat}_findings_${TIMESTAMP}.json\` / \`.md\`"
	done
} > "$UNIFIED_MD"

# ---- per-category report files (api / code / secrets / dependency / infrastructure) ----
for cat in secrets dependency api code infrastructure; do
	cat_json="$UNIFIED_DIR/${cat}_findings_${TIMESTAMP}.json"
	cat_md="$UNIFIED_DIR/${cat}_findings_${TIMESTAMP}.md"
	jq --arg c "$cat" '[.[] | select(.category == $c)] | {category: $c, count: length, findings: .}' \
		"$TMP_AGG/all_findings.json" > "$cat_json"
	cat_count=$(jq --arg c "$cat" '[.[] | select(.category == $c)] | length' "$TMP_AGG/all_findings.json")
	{
		echo "# $(category_title "$cat")"
		echo
		echo "$cat_count findings"
		echo
		if [ "$cat_count" -eq 0 ]; then
			echo "_No findings in this category._"
		elif [ "$cat" = "secrets" ]; then
			echo "Secret values are masked (first 8 chars) - full values stay in the raw gitleaks json report:"
			echo
			echo "| Severity | Rule | Location | Secret preview | Source |"
			echo "| --- | --- | --- | --- | --- |"
			jq -r --arg c "$cat" '.[] | select(.category == $c)
				| (.secret_preview // "—") as $prev
				| ((.source // "?")
					+ (if (.commit // "") != "" then " (commit " + .commit + ")" else "" end)
					+ (if (.author // "") != "" then " by " + .author else "" end)) as $src
				| "| \(.severity) | \(.id) | \(.location) | \($prev) | \($src) |"
				| gsub("[\n\r\t]"; " ")' "$TMP_AGG/all_findings.json"
		elif [ "$cat" = "dependency" ]; then
			echo "Grouped by package (advisory IDs counted as reported by each scanner —"
			echo "the same vulnerability may appear under a CVE id from one scanner and a"
			echo "GHSA id from another; full detail is in the json report):"
			echo
			echo "| Package | Advisories | Worst severity | Scanners |"
			echo "| --- | --- | --- | --- |"
			jq -r 'def sev_rank: {"Critical": 0, "High": 1, "Medium": 2, "Low": 3, "Unknown": 4}[.];
				[.[] | select(.category == "dependency")]
				| group_by(.location)
				| map({
					pkg: .[0].location,
					count: length,
					worst: (map(.severity) | sort_by(sev_rank) | .[0]),
					scanners: (map(.tool) | unique | sort | join(", "))
				})
				| sort_by(-.count)[]
				| "| \(.pkg) | \(.count) | \(.worst) | \(.scanners) |"' "$TMP_AGG/all_findings.json"
		else
			echo "| Severity | Tool | Rule | Location | Description |"
			echo "| --- | --- | --- | --- | --- |"
			jq -r --arg c "$cat" '.[] | select(.category == $c)
				| (.id | if test("\\.") then split(".") | .[-2:] | join(".") else . end) as $id
				| (.title | if length > 90 then .[:87] + "..." else . end) as $desc
				| "| \(.severity) | \(.tool) | \($id) | \(.location) | \($desc) |"
				| gsub("[\n\r\t]"; " ")' "$TMP_AGG/all_findings.json"
		fi
	} > "$cat_md"
done

# ---- console summary + gate ----
echo -e "............. unified report .............."
echo "verdict: $VERDICT ($NEW_FINDINGS new / $KNOWN_COUNT known / $SUPPRESSED_COUNT suppressed, $DUPLICATES_REMOVED duplicates removed)"
jq -r '.summary.tools | to_entries[] | "  \(.key): \(.value.status) - \(.value.findings) findings"' "$UNIFIED_JSON"
jq -r '.summary.severity | "  severity: critical=\(.Critical) high=\(.High) medium=\(.Medium) low=\(.Low) unknown=\(.Unknown)"' "$UNIFIED_JSON"
jq -r '.summary.categories | to_entries[] | "  category \(.key): \(.value) findings"' "$UNIFIED_JSON"
jq -r '.summary.components | to_entries | sort_by(-.value) | .[0:5][] | "  component \(.key): \(.value) findings"' "$UNIFIED_JSON"
jq -r '.metadata.tool_versions | to_entries[] | "  scanner \(.key): \(.value)"' "$UNIFIED_JSON"
echo "category reports in $UNIFIED_DIR:"
for cat in secrets dependency api code infrastructure; do
	echo "  $cat: $UNIFIED_DIR/${cat}_findings_${TIMESTAMP}.json / .md"
done
echo "sarif (code scanning / PR annotations): $SARIF_DIR/<tool>.sarif"
echo "unified json: $UNIFIED_JSON"
echo "unified markdown: $UNIFIED_MD"

if [ "$VERDICT" = "FAIL" ]; then
	echo "pipeline gate: FAIL - $NEW_FINDINGS new findings detected (fix them, suppress them with a reason, or refresh the baseline with --baseline)"
	exit 1
fi

echo "pipeline gate: PASS - no new findings"
exit 0
