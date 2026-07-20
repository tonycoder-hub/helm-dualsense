#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
app_model="$script_dir/../Sources/AppModel.swift"

python3 - "$app_model" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
try:
    unicode_delivery = source.split("  private func deliverUnicodeChunks(", 1)[1].split(
        "  private func finishInterruptedUnicodeDelivery(", 1
    )[0]
    restart = source.split("  private func restartAlwaysOnIfReady()", 1)[1].split(
        "  private func updatePushToTalkSource(", 1
    )[0]
except IndexError as error:
    raise SystemExit(f"could not locate voice-mode implementation sections: {error}")

if ".confirmedDelivery" in unicode_delivery:
    raise SystemExit("Unicode/HID posting is incorrectly treated as confirmed insertion")
if unicode_delivery.count(".unconfirmedDelivery") < 2:
    raise SystemExit("every completed Unicode/HID path must pause always-on as unconfirmed")
if unicode_delivery.count("completedUnconfirmedText") < 2:
    raise SystemExit("every completed Unicode/HID path must retain the full retry text")
if restart.count("isRecordingMapping") < 2:
    raise SystemExit("always-on restart is not guarded before and inside its delayed callback")

print("VOICE_INPUT_MODE_CONTRACT_TESTS=PASS unicode=unconfirmed mapping-restart=guarded")
PY
