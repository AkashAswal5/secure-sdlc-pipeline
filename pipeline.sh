#!/bin/bash

source config/env.sh
source lib/pm.sh

REPO_URL=""
PM_ARG=""
IMAGE_ARG=""
CREATE_BASELINE=0
SERIAL=0

# parse args: ./pipeline.sh <git-repo-url> [--pm <pacman|brew|apt|dnf|apk>] [--image <container-image>] [--baseline] [--serial]
while [ $# -gt 0 ]; do
    case "$1" in
        --pm)
            if [ -z "${2:-}" ]; then
                echo "--pm requires a package manager name (pacman|brew|apt|dnf|apk)"
                exit 1
            fi
            PM_ARG="$2"
            shift 2
            ;;
        --image)
            if [ -z "${2:-}" ]; then
                echo "--image requires a container image name (e.g. nginx:1.25)"
                exit 1
            fi
            IMAGE_ARG="$2"
            shift 2
            ;;
        --baseline)
            # write the current active findings as the new baseline after this run
            CREATE_BASELINE=1
            shift
            ;;
        --serial)
            # run the scan scripts one after another instead of in parallel (debugging)
            SERIAL=1
            shift
            ;;
        *)
            REPO_URL="$1"
            shift
            ;;
    esac
done

if [ -z "$REPO_URL" ]; then # -z check if user provide string or not
    # run if above condition is true
   echo "Usage: ./pipeline.sh <git-repo-url-or-local-dir> [--pm <pacman|brew|apt|dnf|apk>] [--image <container-image>] [--baseline] [--serial]"
   exit 1
fi

echo "running ./pipeline.sh $REPO_URL"
export REPO_URL # `export REPO_URL` makes it available to child processes like clone.sh.
export CREATE_BASELINE

# ask user for package manager (auto-picks if only one installed, honors --pm / PACKAGE_MANAGER)
select_package_manager "$PM_ARG"

# start a fresh run manifest: scan scripts record their report paths in it,
# the aggregator (phase 6) then only uses reports from this pipeline run
mkdir -p "$REPORT_DIR"
: > "$RUN_MANIFEST"
# record the run start time so the aggregator can report scan duration
date +%s > "$REPORT_DIR/.run_start"

bash scripts/clone.sh "$REPO_URL" "$WORKSPACE" || { echo "failed to clone $REPO_URL, aborting pipeline"; exit 1; }

# tool installs stay sequential (package managers are not concurrency-safe),
# but the scans themselves are independent - run them in parallel
bash install/install_semgrep.sh
bash install/install_gitleaks.sh
bash install/install_checkov.sh
bash install/install_osv_scanner.sh

# trivy (image mode when --image given, else filesystem scan of the repo)
if [ -n "$IMAGE_ARG" ]; then
    export SCAN_IMAGE="$IMAGE_ARG"
fi
bash install/install_trivy.sh

# scan scripts: semgrep.sh gitleaks.sh checkov.sh osv_scanner.sh trivy.sh
SCAN_SCRIPTS="semgrep gitleaks checkov osv_scanner trivy"

if [ "$SERIAL" -eq 1 ]; then
    echo "running scans serially (--serial)"
    for s in $SCAN_SCRIPTS; do
        bash "scripts/$s.sh" "$WORKSPACE" || echo "warning: scan script $s.sh failed"
    done
else
    # concurrent appends to the run manifest are safe: each line is short and
    # written in a single O_APPEND write
    echo "running scans in parallel"
    pids=""
    for s in $SCAN_SCRIPTS; do
        bash "scripts/$s.sh" "$WORKSPACE" &
        pids="$pids $!"
    done
    for pid in $pids; do
        if ! wait "$pid"; then
            echo "warning: a scan script failed (see output above), continuing with the tools that did run"
        fi
    done
fi

# report aggregation (phase 6): unified json + markdown report
# exits 1 when any tool found issues, this gates the whole pipeline
bash scripts/aggregate.sh
PIPELINE_EXIT_CODE=$?

# remove repo after all work done
# rm -rf "/tmp/workspace/"

exit $PIPELINE_EXIT_CODE
