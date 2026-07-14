#!/bin/bash

# git clone script --> this script will clone repo for which we are running this scan

source config/env.sh
# REPO_URL="$REPO_URL"
# WORKSPACE="$WORKSPACE"

# check if the workspace exist 
if [[  -d "$WORKSPACE" ]]; then
	echo "workspace exits. Cleaning up..."
	rm -rf "$WORKSPACE"
fi
# create a fresh workspace
	echo "Creating workspace"
	mkdir -p "$WORKSPACE"

# clone repo 
echo "Cloning  repository..."
git clone "$REPO_URL" "$WORKSPACE"

if [ $? -eq 0 ]; then
	echo "repo clone successfully....."
else
	echo "Failed to clone repository."
	exit 1
fi


