# Helm 0.9.2 local permission-retention evidence

Date: 2026-07-17
Scope: the local `Helm Demo.app` identity on the target Mac only

## What was tested

Helm was updated in place from build 11 to builds 12 through 17. Every update
replaced only the app bundle's `Contents` directory, then relaunched and verified
the installed copy. The tests intentionally changed the code-directory hash
while preserving the installation path, top-level app-directory inode, bundle
identifier, and designated requirement.

## Before update: build 11

- Version: `0.9.1 (11)`
- App path: `~/Applications/Helm Demo.app`
- App-directory inode: `153676620`
- CDHash: `7f5efe59fe4f2344d1454d93181c54624b6e6746`
- Designated requirement:
  `identifier "io.github.tonycoder-hub.helm" and info[HelmLocalUpdateIdentity] = "io.github.tonycoder-hub.helm.local-v1"`
- Relaunch diagnostic at `2026-07-17 13:44:57.695`:
  `permission_snapshot accessibility=1 microphone=3 speech=3`

## After update: build 12

- Version: `0.9.1 (12)`
- App path: `~/Applications/Helm Demo.app`
- App-directory inode: `153676620`
- CDHash: `49553fbc39f2567013bdf11aec1977abd2d63c37`
- Designated requirement: unchanged from build 11
- Relaunch diagnostic at `2026-07-17 13:45:55.589`:
  `permission_snapshot accessibility=1 microphone=3 speech=3`

## Subsequent updates: builds 13 through 17

All five subsequent updates kept app-directory inode `153676620` and the same
designated requirement.

| Build | CDHash | Relaunch diagnostic |
| --- | --- | --- |
| `0.9.1 (13)` | `7191ae3ed2facaeb898b9d24be2119c52c0dec6a` | `2026-07-17 14:07:22.807` — `accessibility=1 microphone=3 speech=3` |
| `0.9.1 (14)` | `a6a28aa9390000ed8d283208931c8b29fac47d47` | `2026-07-17 14:09:22.269` — `accessibility=1 microphone=3 speech=3` |
| `0.9.1 (15)` | `a8b0a58c39a4619a82b26f37755e7028d73481f9` | `2026-07-17 14:20:31.466` — `accessibility=1 microphone=3 speech=3` |
| `0.9.2 (16)` | `7dfab5fd0668a03d268c5b22847e79345f9f448f` | `2026-07-17 14:57:20.622` — `accessibility=1 microphone=3 speech=3` |
| `0.9.2 (17)` | `745e85359bc806912fb7943693a4b2ce8bb34533` | `2026-07-17 15:16:48.097` — `accessibility=1 microphone=3 speech=3` |

The diagnostic values report Accessibility, Microphone, and Speech as
authorized. Its message payload records only authorization states and does not
include device names, audio, recognized text, focus targets, or process
identifiers. macOS unified logging still attaches normal system metadata such as
the emitting process and timestamp.

## Verification completed

- Pure Swift control, mapping, focus, text-insertion, audio-selection, cadence,
  and permission-diagnostic tests passed.
- The isolated SDL virtual-gamepad integration test passed 256 alternating
  left-stick/right-stick analog reads and trigger normalization checks.
- The in-place installation and local-identity regression tests passed.
- The installed app passed strict code-signature verification.
- The installation contains one current app and no retained backup bundle.

## Conclusion and limit

This proves that six real in-place updates from build 11 through build 17
retained all three privacy authorizations on this Mac under Helm's current local
ad-hoc identity. It does not establish permission retention on another Mac or
for a future Developer ID-signed release, whose identity and update path require
separate validation.

External review of the final build is recorded separately from this measurement
log. The permission-retention claim remains restricted to this Mac and local
Demo identity.
