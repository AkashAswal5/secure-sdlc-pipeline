#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefined variables become errors
# -o pipefail detect failures inside pipelines

source config/env.sh

echo "starting SBOM generation for $WORKSPACE"

if [ ! -d "$WORKSPACE" ]; then
	echo "workspace not found: $WORKSPACE"
	exit 1
fi

# find trivy: PATH first, then tools-workspace binary (github release fallback)
if command -v trivy >/dev/null 2>&1; then
	TRIVY_BIN=$(command -v trivy)
elif [ -x "$TOOLS_WORKSPACE/bin/trivy" ]; then
	TRIVY_BIN="$TOOLS_WORKSPACE/bin/trivy"
else
	echo "trivy not found (SBOM generation reuses the trivy binary)"
	exit 1
fi

SBOM_DIR="$REPORT_DIR/sbom"
SBOM_CDX="$SBOM_DIR/sbom_${TIMESTAMP}.cyclonedx.json"
SBOM_SPDX="$SBOM_DIR/sbom_${TIMESTAMP}.spdx.json"
SBOM_MD="$SBOM_DIR/sbom_${TIMESTAMP}.md"
mkdir -p "$SBOM_DIR"

# SBOM generation needs no vulnerability database (--skip-db-update), so it
# never conflicts with a trivy vulnerability scan running in parallel and
# makes no remote requests beyond the package metadata itself
set +e
"$TRIVY_BIN" fs --format cyclonedx --output "$SBOM_CDX" --skip-db-update "$WORKSPACE"
CDX_EXIT=$?
"$TRIVY_BIN" fs --format spdx-json --output "$SBOM_SPDX" --skip-db-update "$WORKSPACE"
SPDX_EXIT=$?
set -e

if [ ! -s "$SBOM_CDX" ]; then
	echo "warning: cyclonedx SBOM generation produced no output"
fi

# ---- summary ----
COMPONENT_COUNT=$(jq '(.components // []) | length' "$SBOM_CDX" 2>/dev/null || echo 0)
# metadata.component is the root component; everything else is a dependency
ROOT_NAME=$(jq -r '.metadata.component.name // "unknown"' "$SBOM_CDX" 2>/dev/null || echo unknown)

{
	echo "# SBOM — $ROOT_NAME"
	echo
	echo "- **Generated:** $TIMESTAMP"
	echo "- **Components:** $COMPONENT_COUNT (+ 1 root)"
	echo "- **Formats:** CycloneDX (\`$(basename "$SBOM_CDX")\`), SPDX (\`$(basename "$SBOM_SPDX")\`) — in this directory"
	echo
	echo "## Components by type"
	echo
	echo "| Type | Count |"
	echo "| --- | --- |"
	jq -r '(.components // []) | group_by(.type) | map({type: .[0].type, count: length}) | sort_by(-.count)[] | "| \(.type) | \(.count) |"' \
		"$SBOM_CDX" 2>/dev/null || echo "| n/a | 0 |"
	echo
	echo "## Direct dependencies"
	echo
	echo "_From the CycloneDX report — full transitive detail is in the json files._"
	echo
	if [ "$COMPONENT_COUNT" -gt 0 ]; then
		echo "| Package | Version |"
		echo "| --- | --- |"
		jq -r '(.components // [])[0:50][] | "| \(.name // "?") | \(.version // "?") |"' "$SBOM_CDX" 2>/dev/null || true
	else
		echo "_No components detected (no lockfiles/manifests found in the workspace)._"
	fi
} > "$SBOM_MD"

echo "SBOM generated: $COMPONENT_COUNT components"
echo "  cyclonedx: $SBOM_CDX"
echo "  spdx:      $SBOM_SPDX"
echo "  summary:   $SBOM_MD"

# SBOM generation is an artifact, not a findings source: nothing is recorded
# in the run manifest and it never affects the gate verdict
if [ "$CDX_EXIT" -ne 0 ] || [ "$SPDX_EXIT" -ne 0 ]; then
	echo "warning: trivy exited non-zero during SBOM generation (cyclonedx=$CDX_EXIT, spdx=$SPDX_EXIT) - reports may be partial"
fi
