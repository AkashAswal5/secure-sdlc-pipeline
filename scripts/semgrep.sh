#!/bin/bash

source config/env.sh
# install semgrep 
	# set directory for install semgrep

mkdir -p /tmp/semgrep-workspace
cd /tmp/semgrep-workspace || exit 1 
sudo pacman -S python-pip

# install in any device make it compatible, like independent of pacman, yay , apt,

# install dependencies
 sudo pacman -S --needed python-pip python-virtualenv

python3 -m venv myenv
source myenv/bin/activate


pip install --upgrade pip
pip install semgrep

semgrep --version

## make semgrep unv
# run semgrep on workspace


# filter out the result


# present result in various format, like json, txt, 

# save result 

