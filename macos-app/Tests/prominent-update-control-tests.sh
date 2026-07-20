#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
views="$script_dir/../Sources/Views.swift"

python3 - "$views" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
try:
    header = source.split("  private var header: some View {", 1)[1].split(
        "  private var statusStrip: some View {", 1
    )[0]
    diagnostics = source.split("  private var diagnosticsCard: some View {", 1)[1].split(
        "struct MenuBarPanel: View", 1
    )[0]
    menu = source.split("struct MenuBarPanel: View", 1)[1].split(
        "private struct HelmCard", 1
    )[0]
except IndexError as error:
    raise SystemExit(f"could not locate update-control view sections: {error}")

button = 'Button("检查更新")'
if button not in header:
    raise SystemExit("the primary header does not expose the update button")
if button in diagnostics:
    raise SystemExit("the update button is still buried in the collapsed diagnostics card")
if button not in menu:
    raise SystemExit("the menu bar panel does not expose the update button")

print("PROMINENT_UPDATE_CONTROL_TESTS=PASS placement=header,menu-bar")
PY
