#!/bin/bash

source config/env.sh

install_tools_workspace() {
if [ ! -d "$TOOLS_WORKSPACE" ]; then
  mkdir -p "$TOOLS_WORKSPACE"
else
  echo " $TOOLS_WORKSPACE exist"
fi
}

check_report_dir() {
if [ ! -d "$1" ] ; then
 mkdir -p "$1"
else
  echo "$1 exist"
fi 
}

# install python3 if it is not there
install_python3() {
if ! command -v python3 >/dev/null; then
  echo "python3 is not there install it......."
  sudo "$PACKAGE_MANAGER" python-pip
fi
}

create_virtual_environment() {
if [ ! -d "$VENV_DIR" ] ; then
  echo "Creating Virtual environment"
  python3 -m venv "$VENV_DIR"
fi
}

install_semgrep() {
if ! command -v semgrep >/dev/null 2>&1; then
  pip install semgrep
fi
}


