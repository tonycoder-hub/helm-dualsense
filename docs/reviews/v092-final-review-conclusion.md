# Helm 0.9.2 build 17 final review conclusion

Date: 2026-07-17
Schema: `mira_review_conclusion.v1`

## Scope

The final review covered the build 17 stick-response filter, continuous scroll
accumulator and CoreGraphics/AppKit event fields, guarded global Unicode text
delivery, shortcut-editor layout, focused regression tests, and local in-place
installation identity. Reviewers received the final source files or an exact
code packet rather than a user-visible raw diff.

## External sources

| Source | Verdict | Counted | Notes |
| --- | --- | --- | --- |
| GPT dedicated subagent | `PASS_WITH_NOTES` | Yes | No blockers; confirmed bounded scroll debt and narrowed text-delivery TOCTOU. |
| Orange (`model_hub/es1_orange_o48`) | `PASS_WITH_NOTES` | Yes | No blockers; requested physical low-speed scrolling and long-text editor validation. |
| Seed (`alwaysday1`) | `PASS_WITH_NOTES` | Yes | No blockers; noted the generic-role external fallback and lack of an AX end-to-end test. |
| DeepSeek (`deepseek-v4-pro`) | `not executed` | No | Repeated initial-run/export timeouts or incomplete JSON; no readable final verdict was counted. |

## Aggregate

Verdict: `PASS_WITH_NOTES`
Blocking items: none
Quorum: met for a high-risk cross-application input change with three distinct,
valid sources. The unavailable DeepSeek channel was attempted through the
required two-step export flow and timed out or returned incomplete output.

## Shared non-blocking notes

- Point-delta consumers may quantize an extremely short scroll gesture by less
  than one point; sustained same-direction input repays the startup impulse and
  preserves long-run distance.
- Fixed-point and point scroll fields are alternative consumer views of the
  same event. Physical application behavior still requires user acceptance.
- Unicode fallback rechecks the frontmost/focused target and Secure Input just
  before global HID posting, but the final check and post cannot be atomic.
- A whole transcript is currently placed in one Unicode key event. Very long
  dictation still needs Chrome/Electron/native-editor testing before release.
- The adaptive layout compiled and its width policy is tested, but visual
  acceptance is pending because screen capture was unavailable to this process.

## Deployment evidence after review comments

- Installed version: `0.9.2 (17)`.
- App path: `~/Applications/Helm Demo.app`.
- Top-level app inode: `153676620`.
- Installed copies: one; retained backup bundles: zero.
- Strict code-signature verification passed and the local designated
  requirement remained unchanged.
- Post-relaunch diagnostic at `2026-07-17 15:16:48.097` reported
  `accessibility=1 microphone=3 speech=3`.

These identity and permission observations apply only to this Mac and the local
ad-hoc Demo identity; they do not establish Developer ID release behavior.
