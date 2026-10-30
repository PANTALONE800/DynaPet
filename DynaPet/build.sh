#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# One authoritative build entry point; preserves the complete native Mac app.
make -C IPCDemo package "$@"
