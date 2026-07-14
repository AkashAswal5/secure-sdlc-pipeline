#!/bin/bash

# git clone script --> this script will clone repo for which we are running this scan

REPO_URL="$1"
WORKSPACE="$2"

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

if [ $? -eq 0 ]
	echo "repo clone successfully....."
else  
	echo "Failed to clone repository."
	exit 1
fi


