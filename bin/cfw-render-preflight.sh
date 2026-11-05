#!/usr/bin/env bash
# cfw-render-preflight.sh — verify this host can actually finish a render.
#
# Run it before enabling the timer on a new box, and any time the toolchain
# might have moved. It claims nothing, calls no API, costs nothing.
#
#   bin/cfw-render-preflight.sh            # full report
#   bin/cfw-render-preflight.sh --quiet    # only failures
#   bin/cfw-render-preflight.sh --bundle   # bundled tools and pinned Chromium only
#   bin/cfw-render-preflight.sh --bundle --quiet
#
# Exit 0 = every required tool is present. Exit 1 = at least one is missing;
# the failure block names each one and the command that installs it.
#
# `--bundle` is for an unpacked toolchain bundle (CI after build.sh, and the
# desktop install). It reads this tree's config/playwright-pin.json and the
# browsers shipped beside bin/. It does not need the claude CLI, a Director
# command, or the HOME Playwright cache. The default (no --bundle) is the
# full worker check.
#
# Why it exists: CFW-188 found hst with no ImageMagick at all, one
# `systemctl enable` away from claiming production orders it could not finish.
# See the TOOLCHAIN PREFLIGHT block in bin/cfw-render-lib.sh.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/cfw-render-lib.sh"

cr_preflight "$@"
