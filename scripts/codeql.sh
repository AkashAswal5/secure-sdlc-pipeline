#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefined variables become errors
# -o pipefail detect failures inside pipelines

source config/env.sh

echo "starting codeql scan on directory $WORKSPACE"

if [ ! -d "$WORKSPACE" ]; then
	echo "workspace not found: $WORKSPACE"
	exit 1
fi

REPORT_CODEQL_DIR="$REPORT_DIR/codeql"
CODEQL_SARIF="$REPORT_CODEQL_DIR/codeql_${TIMESTAMP}.sarif"
mkdir -p "$REPORT_CODEQL_DIR"

EMPTY_SARIF='{"$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json","version":"2.1.0","runs":[]}'

# detect the codeql-supported languages present in the workspace by file
# extension. codeql builds one database + one analysis per language.
# this runs BEFORE the binary check: a workspace with no supported languages
# needs no codeql installation at all
detect_languages() {
	local ext_list langs=""
	ext_list=$(find "$WORKSPACE" -type f -not -path '*/.git/*' 2>/dev/null \
		| awk -F. 'NF>1 {print tolower($NF)}' | sort -u)
	grep -qx 'py' <<<"$ext_list" && langs="$langs python"
	{ grep -Eqx 'js|jsx|mjs|cjs|ts|tsx' <<<"$ext_list" || [ -f "$WORKSPACE/package.json" ]; } && langs="$langs javascript"
	grep -qx 'java' <<<"$ext_list" && langs="$langs java"
	grep -qx 'go' <<<"$ext_list" && langs="$langs go"
	grep -Eqx 'c|cc|cpp|h|hpp' <<<"$ext_list" && langs="$langs cpp"
	grep -qx 'cs' <<<"$ext_list" && langs="$langs csharp"
	grep -qx 'rb' <<<"$ext_list" && langs="$langs ruby"
	grep -qx 'swift' <<<"$ext_list" && langs="$langs swift"
	grep -qx 'kt' <<<"$ext_list" && langs="$langs kotlin"
	echo "$langs"
}

LANGS=$(detect_languages || true)
if [ -z "$LANGS" ]; then
	echo "no codeql-supported languages detected in $WORKSPACE, skipping codeql scan"
	echo "$EMPTY_SARIF" > "$CODEQL_SARIF"
	echo "codeql|$CODEQL_SARIF" >> "$RUN_MANIFEST"
	exit 0
fi
echo "detected languages:$LANGS"

# find codeql: PATH first, then tools-workspace bundle dir
if command -v codeql >/dev/null 2>&1; then
	CODEQL_BIN=$(command -v codeql)
elif [ -x "$TOOLS_WORKSPACE/codeql/codeql" ]; then
	CODEQL_BIN="$TOOLS_WORKSPACE/codeql/codeql"
else
	echo "codeql not found (supported languages present: $LANGS)"
	exit 1
fi

TMP_CODEQL=$(mktemp -d)
trap 'rm -rf "$TMP_CODEQL"' EXIT

# codeql exits non-zero when queries find results or a database build fails,
# capture exit codes manually and continue with the other languages
analyzed=0
set +e
for lang in $LANGS; do
	db="$TMP_CODEQL/db_$lang"
	echo "codeql: creating $lang database"
	# interpreted languages extract without a build; for compiled ones a failed
	# build (no toolchain on this machine) is expected - warn and move on
	if ! "$CODEQL_BIN" database create "$db" --language="$lang" --source-root="$WORKSPACE" --overwrite >/dev/null 2>&1; then
		echo "warning: could not create $lang database (missing build toolchain or no scannable sources), skipping $lang"
		continue
	fi

	echo "codeql: analyzing $lang database"
	# security-and-quality suite from the bundle's query packs; override with
	# CODEQL_SUITE (e.g. CODEQL_SUITE=python-security-queries) for a lighter run
	suite="${CODEQL_SUITE:-${lang}-security-and-quality.qls}"
	if ! "$CODEQL_BIN" database analyze "$db" \
		"codeql/${lang}-queries:codeql-suites/${suite}" \
		--format=sarif-latest --output="$TMP_CODEQL/$lang.sarif" >/dev/null 2>&1; then
		echo "warning: codeql analysis failed for $lang, skipping $lang"
		continue
	fi
	analyzed=$((analyzed + 1))
done
set -e

# merge the per-language sarif runs into one report
lang_sarifs=$(find "$TMP_CODEQL" -name '*.sarif' -type f 2>/dev/null || true)
if [ -n "$lang_sarifs" ] && [ "$analyzed" -gt 0 ]; then
	jq -s 'reduce .[] as $file (
		{"$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json", version: "2.1.0", runs: []};
		.runs += ($file.runs // [])
	)' $lang_sarifs > "$CODEQL_SARIF"
else
	echo "warning: codeql produced no results (no language database could be built)"
	echo "$EMPTY_SARIF" > "$CODEQL_SARIF"
fi

# record the report path for the aggregator (phase 6)
if [ -s "$CODEQL_SARIF" ]; then
	mkdir -p "$REPORT_DIR"
	echo "codeql|$CODEQL_SARIF" >> "$RUN_MANIFEST"
fi

CODEQL_COUNT=$(jq '[.runs[]?.results[]?] | length' "$CODEQL_SARIF")
echo "codeql scan completed: $analyzed language(s) analyzed, $CODEQL_COUNT findings"
echo "CODEQL REPORT: $CODEQL_SARIF"
if [ "$CODEQL_COUNT" -gt 0 ]; then
	jq -r '.runs[]?.results[]? | "  \(.ruleId // "?")  \(.locations[0].physicalLocation.artifactLocation.uri // "?"):\(.locations[0].physicalLocation.region.startLine // 0)"' \
		"$CODEQL_SARIF" | sort | uniq -c | sort -rn | head -15
fi
