#!/bin/sh
# Unit tests (odin test), then the end-to-end script when it exists.
# The ffmpeg tests need `ffmpeg` and `ffprobe` on PATH or TESSERA_FFMPEG.
# Memory tracking is off: tessera is a one-shot CLI that frees at exit, and
# the leak reports would bury real failures. No -vet here: with tracking off,
# core:testing itself has an unused import; build.sh vets the program.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
odin test src -out:bin/tessera-test -strict-style -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_TRACK_MEMORY=false
if [ -x tests/e2e.sh ]; then
	./build.sh
	tests/e2e.sh
fi
