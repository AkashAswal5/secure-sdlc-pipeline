#!/bin/bash

source config/env.sh
source lib/pm.sh

REPO_URL=""
PM_ARG=""
IMAGE_ARG=""

# parse args: ./pipeline.sh <git-repo-url> [--pm <pacman|brew|apt|dnf|apk>]
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
        *)
            REPO_URL="$1"
            shift
            ;;
    esac
done

if [ -z "$REPO_URL" ]; then # -z check if user provide string or not
    # run if above condition is true
   echo "Usage: ./pipeline.sh <git-repo-url> [--pm <pacman|brew|apt|dnf|apk>] [--image <container-image>]"
   exit 1
fi

echo "running ./pipeline.sh $REPO_URL"
export REPO_URL # `export REPO_URL` makes it available to child processes like clone.sh.

# ask user for package manager (auto-picks if only one installed, honors --pm / PACKAGE_MANAGER)
select_package_manager "$PM_ARG"

bash scripts/clone.sh "$REPO_URL" "$WORKSPACE" || { echo "failed to clone $REPO_URL, aborting pipeline"; exit 1; }

# semgrep
bash install/install_semgrep.sh
bash scripts/semgrep.sh "$WORKSPACE"

# gitleaks
bash install/install_gitleaks.sh
bash scripts/gitleaks.sh "$WORKSPACE"

# checkov
bash install/install_checkov.sh
bash scripts/checkov.sh "$WORKSPACE"

# osv-scanner
bash install/install_osv_scanner.sh
bash scripts/osv_scanner.sh "$WORKSPACE"

# trivy (image mode when --image given, else filesystem scan of the repo)
if [ -n "$IMAGE_ARG" ]; then
    export SCAN_IMAGE="$IMAGE_ARG"
fi
bash install/install_trivy.sh
bash scripts/trivy.sh "$WORKSPACE"

# remove repo after all work done
# rm -rf "/tmp/workspace/"
