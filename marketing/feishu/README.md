# GripPilot Feishu launch card

`grippilot-v0.11.0-card.json` is the reusable interactive-card payload for the
0.11.0 launch. Before sending, upload
`macos-app/Resources/GripPilot-Icon-1024.png` to Feishu and replace the single
`{{GRIPPILOT_ICON_IMAGE_KEY}}` placeholder with the returned image key.

The card links to the immutable v0.11.0 GitHub Release and the public source
repository. Recipient and sender identity are intentionally selected only at
send time so the same reviewed payload can be forwarded to a person or group.
