#!/bin/sh
# Unit tests (odin test), then the end-to-end script when it exists.
# The ffmpeg tests need `ffmpeg` and `ffprobe` on PATH or TESSERA_FFMPEG.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
odin test src -out:bin/tessera-test -vet -strict-style -define:ODIN_TEST_FANCY=false
if [ -x tests/e2e.sh ]; then
	./build.sh
	tests/e2e.sh
fi
