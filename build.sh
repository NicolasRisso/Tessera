#!/bin/sh
# Build tessera into bin/. Needs `odin` on PATH (and a C linker it can drive).
set -eu
cd "$(dirname "$0")"
mkdir -p bin
odin build src -out:bin/tessera -o:speed -vet -strict-style "$@"
