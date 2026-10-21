#!/usr/bin/env bash
# Package module/ into release/PianoMax-<version>.zip
#
# The actual archive is written by build.mjs.  Compress-Archive and .NET's
# CreateFromDirectory both put Windows separators into entry names, and
# Android's unzip then extracts them as single files called "lib\apply.sh";
# that is why this does not use them.
set -euo pipefail
cd "$(dirname "$0")"
node build.mjs
