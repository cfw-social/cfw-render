#!/usr/bin/env bash
# cfw-render-preflight.sh — verify this host can actually finish a render.
#
# Run it before enabling the timer on a new box, and any time the toolchain
# might have moved. It claims nothing, calls no API, costs nothing.
#
#   bin/cfw-render-preflight.sh            # full report
#   bin/cfw-render-preflight.sh --quiet    # only failures
#
# Exit 0 = every required tool is present. Exit 1 = at least one is missing;
# the failure block names each one and the command that installs it.
#
# Why it exists: CFW-188 found hst with no ImageMagick at all, one
# `systemctl enable` away from claiming production orders it could not finish.
# See the TOOLCHAIN PREFLIGHT block in bin/cfw-render-lib.sh.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

cr_preflight "$@"
