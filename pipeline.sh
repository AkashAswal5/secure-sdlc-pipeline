#!/bin/bash

source config/env.sh
REPO_URL="$1"
export REPO_URL # `export REPO_URL` makes it available to child processes like clone.sh.

if [ -z "$REPO_URL" ]; then # -z check if user provide string or not
    # run if above condition is true
   echo "Usage: ./pipeline.sh <git-repo-url>"
    exit 1
fi

echo "running ./pipeline.sh $REPO_URL"

bash scripts/clone.sh "$REPO_URL" "$WORKSPACE"

# semgrep
bash install/install_semgrep.sh
bash scripts/semgrep.sh "$WORKSPACE"

# gitleaks
bash install/install_gitleaks.sh
bash scripts/gitleaks.sh "$WORKSPACE"

# checkov
bash install/install_checkov.sh
bash scripts/checkov.sh "$WORKSPACE"

# remove repo after all work done
# rm -rf "/tmp/workspace/"

