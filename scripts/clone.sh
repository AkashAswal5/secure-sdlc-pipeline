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

if [ -d "$REPO_URL" ]; then
	# local directory input:
	# - a local git repo -> clone it (keeps history for gitleaks)
	# - a plain folder   -> copy its contents (incl. dotfiles) into the workspace
	if [ -d "$REPO_URL/.git" ]; then
		echo "Cloning local repository..."
		git clone "$REPO_URL" "$WORKSPACE"
		if [ $? -eq 0 ]; then
			echo "repo clone successfully....."
		else
			echo "Failed to clone repository."
			exit 1
		fi
	else
		echo "Local folder detected, copying into workspace..."
		cp -R "$REPO_URL/." "$WORKSPACE/"
		if [ $? -eq 0 ]; then
			echo "source copied successfully....."
		else
			echo "Failed to copy source folder."
			exit 1
		fi
	fi
else
	# clone remote repo
	echo "Cloning  repository..."
	git clone "$REPO_URL" "$WORKSPACE"

	if [ $? -eq 0 ]; then
		echo "repo clone successfully....."
	else
		echo "Failed to clone repository."
		exit 1
	fi
fi


