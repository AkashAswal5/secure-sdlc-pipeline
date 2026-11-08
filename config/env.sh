#!/bin/bash

# REPO_URL
# WORKSPACE / REPORT_DIR can be overridden via environment variables,
# e.g. REPORT_DIR="$HOME/Desktop/report/GCS" ./pipeline.sh <repo>
WORKSPACE="${WORKSPACE:-/tmp/workspace}"
REPORT_DIR="${REPORT_DIR:-/tmp/reports}"
# run manifest: scan scripts append "<tool>|<report-path>" lines here,
# the aggregator reads it so it only uses reports from the current pipeline run
RUN_MANIFEST="$REPORT_DIR/.run_manifest"
# tools-workspace can be overridden (e.g. the Docker image pins tools into /opt/tools)
TOOLS_WORKSPACE="${TOOLS_WORKSPACE:-/tmp/cyber_tools/semgrep-workspace}"
VENV_DIR="$TOOLS_WORKSPACE/myenv"
# PACKAGE_MANAGER is set by lib/pm.sh (prompt / auto-detect / --pm override)
TIMESTAMP=$(date +"20%y_%m_%d_%H:%M:%S")
SEMGREP_BIN="$VENV_DIR/bin/semgrep"
SEMGREP_RULES_CONFIG="auto"

# ---- triage state (phase 8) ----
# suppression list, shape: {"suppressed": [{fingerprint, reason, expires}]}
# fingerprint format: "<tool> | <rule-id> | <file>" (see add_fingerprints in lib/aggregate.sh)
SUPPRESSIONS_FILE="${SUPPRESSIONS_FILE:-config/suppressions.json}"
# baseline: {"created": ..., "repo": ..., "fingerprints": [...]} written by --baseline;
# later runs only fail the gate on findings not in the baseline.
# default lives in REPORT_DIR (volatile on macOS /tmp) - set BASELINE_FILE to a
# persistent path (e.g. a committed baseline.json in CI) for real use
BASELINE_FILE="${BASELINE_FILE:-$REPORT_DIR/baseline.json}"

