# Formal release and updates

Helm 0.6 remains a local, ad-hoc-signed Demo. A formal release must not be
published until `macos-app/scripts/release-preflight.sh` reports
`RELEASE_PREFLIGHT=PASS` from a clean, reviewed commit.

## Release boundary

The first supported release should be an Apple-silicon `Helm.app` with a stable
bundle identifier and executable name. Renaming `Helm Demo.app` is an explicit
one-time boundary; update artifacts must keep the formal name afterward.

The local development installer stays separate from the formal release path.
It may use an ad-hoc signature, but no artifact from that path is eligible for
GitHub Releases or an update feed.

## Required gates

The preflight checks:

1. A clean Git tree whose `HEAD` exactly equals the full reviewed
   `HELM_RELEASE_SOURCE_COMMIT`; final verification requires the same clean
   commit again.
2. The formal `Helm.app` product/executable name.
3. A Developer ID Application identity.
4. An exact expected Team ID, Keychain identity selector, and Developer ID leaf
   certificate SHA-256 fingerprint—not merely any installed signing identity.
   Every value must occupy its real field inside one Keychain record; text in a
   label cannot impersonate a fingerprint.
5. `notarytool`, `stapler`, and a working keychain profile explicitly declared
   for the same Team ID.
6. The pinned Sparkle archive SHA-256, exact extracted framework contents,
   upstream code signature, arm64 slice, source/build linkage, HTTPS feed,
   EdDSA public key, and signed-feed requirement. `sign_update` and
   `generate_keys` are executed only from that verified archive; no external
   tools-directory override is accepted.
7. The tracked SDL version and official DMG SHA-256, an exact
   signature-normalized comparison from the read-only-mounted DMG to the vendor
   and final embedded framework, and an exact one-key entitlement allowlist.
   Audio input is enabled only on the main app. Every nested framework/helper
   must use the exact expected certificate, hardened runtime, and secure
   timestamp with no entitlements. The entire App Contents tree has an exact
   seven-object Mach-O inventory: the main executable plus SDL, Sparkle,
   standalone `Autoupdate`, Updater, Downloader, and Installer. Any unknown
   Mach-O is rejected regardless of directory.
   Dependency-tree comparison uses a deterministic manifest of relative path,
   object type, POSIX mode, symlink target, and regular-file SHA-256. It rejects
   ACLs, file flags, regular-file or symlink hard links, and every xattr except
   the strict 11-byte OS-generated `com.apple.provenance` encoding: the observed
   fixed `01 02 00` header plus one nonzero opaque 64-bit lineage ID. That
   bounded system metadata is explicitly outside content identity; another
   encoding fails closed until reviewed. Special filesystem objects are rejected
   from `lstat` type before ACL or xattr helpers can open them.
   Each `_CodeSignature` directory may contain only one regular, non-hardlinked
   `CodeResources`; only that file and embedded Mach-O signature blobs are
   normalized. Ownership and timestamps are intentionally not identity fields.
   A DMG detach, signature-normalization workspace removal, or other
   temporary-input cleanup failure changes the script result to
   `RELEASE_CLEANUP=BLOCKED` instead of being silently swallowed.
8. A valid SHA-256 in tracked
   `macos-app/Release/PreviousAppcast.sha256`, binding history to the reviewed
   signed genesis or immediately preceding immutable release.
9. An executable final-artifact verifier.

The script never prints a credential value. Store notarization credentials in
the Keychain with `xcrun notarytool store-credentials`, then pass only the
profile name to the process.

The pinned Sparkle 2.9.4 framework is already linked and embedded in development
builds, but its controller is not started without all production feed keys. The
Demo intentionally has no `SUFeedURL` or public key and never contacts a
placeholder feed.

## First two releases: manual and fail-closed

1. Review a clean commit, record its full hash in
   `HELM_RELEASE_SOURCE_COMMIT`, and create a release candidate tag. Do not
   change `HEAD` or any tracked/untracked source file between preflight and
   final verification.
2. Run the preflight locally on the trusted release Mac.
3. Build the Apple-silicon app with the pinned SDL and Sparkle versions.
4. Sign nested frameworks and helpers first, then the app with Developer ID,
   hardened runtime, timestamping, and `Helm.entitlements`. Do not use
   `--deep` as a substitute for correct signing order. Nested code must use the
   same exact leaf certificate as the app, a secure timestamp, and an empty
   entitlement set.
5. Verify signatures and Gatekeeper assessment before submission.
6. Archive with `ditto`, submit with `notarytool --wait`, inspect failures,
   staple the accepted ticket, and verify again.
7. Produce the final ZIP only after stapling, using
   `ditto -c -k --keepParent Helm.app Helm-version-macOS-arm64.zip`, and record
   its SHA-256 checksum. Do not add `--sequesterRsrc`: the verifier permits
   exactly one top-level `Helm.app`, rejects `__MACOSX` or any other payload,
   and rejects absolute, broken, or escaping symlinks.
8. Generate an EdDSA-signed Sparkle appcast and verify it from a clean machine.
   Hash the exact prior signed appcast and confirm that digest already matches
   the tracked reviewed history anchor.
9. Upload the ZIP, checksum, and release notes to a GitHub Draft Release. Test
   installation and one upgrade from the previous version before publishing.
10. Run `verify-release-artifact.sh` against the final app, ZIP, appcast, and
    exact prior signed appcast preserved with the previous immutable release.
    It must report `RELEASE_ARTIFACT=PASS`; a caller-provided prior build number,
    documentation, or a successful upload cannot substitute for that gate.

The first release has no in-app predecessor to update. Starting with the next
release, upgrade testing must cover the last public version and a deliberately
interrupted download.

Before the first formal release, create an offline genesis appcast containing a
single `sparkle:version="0"` enclosure, sign the XML with the newly created
Sparkle Keychain account, verify it with `sign_update --verify`, and preserve it
in the reviewed release record. Put its SHA-256 into
`macos-app/Release/PreviousAppcast.sha256` in a separate reviewed commit before
building the first formal release. It is a monotonic-history trust anchor, not
a published update feed. For every later release, update that tracked digest in
a reviewed commit to the exact signed appcast archived with the immediately
preceding immutable GitHub Release. Never select an older valid feed, create a
replacement history file, override the anchor through an environment variable,
or fall back to a numeric build value. The committed `UNCONFIGURED` sentinel is
intentional and keeps formal release gates blocked until the key ceremony. Both
preflight and final verification read the anchor blob from the exact reviewed
Git commit, require the working path to be a tracked non-symlink regular file,
and reject a dirty tree or post-review replacement.

## Sparkle integration contract

- Sparkle is pinned to 2.9.4 with its distribution SHA-256 recorded in
  `macos-app/ThirdParty`. The preflight extracts the supplied official archive
  and byte-compares its framework with the build input. Final-artifact
  verification repeats that binding against the embedded framework after
  removing code-signature material from controlled temporary copies; any
  changed executable or resource still fails.
- The final verifier obtains `sign_update` and `generate_keys` from the same
  hash-verified archive extraction. A caller-controlled binary directory is not
  part of the trust model.
- Use `SPUStandardUpdaterController` and a visible, user-initiated “Check for
  Updates” action before enabling background checks.
- Set `SUFeedURL` to an HTTPS stable-channel appcast, add `SUPublicEDKey`, and
  require a signed feed with `SURequireSignedFeed`. Keep
  `SUEnableAutomaticChecks` false for the first two releases so checking remains
  an explicit user action.
- Feed and enclosure URLs use a deliberately narrow canonical HTTPS profile:
  printable ASCII only, lowercase validated DNS names or canonical IP literals,
  valid nonzero decimal ports, no credentials, fragments, whitespace, raw URI
  delimiters, or malformed percent escapes. Prefix-only values such as
  `https://` and ambiguous numeric hosts are rejected. Preflight and final
  verification expose separate URL gates so malformed values fail visibly.
- Appcast build and EdDSA attributes must use the canonical Sparkle namespace
  `http://www.andymatuschak.org/xml-namespaces/sparkle`. Conflicting attributes
  with the same local names in any other namespace are rejected.
- Keep the EdDSA private key in the release Mac's Keychain. Never commit it or
  place it in an untrusted pull-request workflow.
- Treat adaptive-trigger experiments and update delivery as separate trust
  domains; controller input must never influence feed URLs or release paths.

Final verification snapshots both dependency archives before use, rebinds the
embedded SDL and Sparkle trees to their hash-pinned official distributions,
checks that the main executable actually links both frameworks, and verifies
every required nested helper is signed by the expected Team with hardened
runtime, a secure timestamp, the exact expected certificate, and an empty
entitlement set. It also requires the complete expected Mach-O inventory. The
notarization ticket is stapled, the ZIP has exactly one safe app
and expands to the same signed CodeDirectory, the appcast and archive EdDSA
signatures verify with the Keychain key whose public half is embedded in Helm,
and `CFBundleVersion` is the current signed-feed maximum and strictly exceeds
the maximum derived from the same-key-verified prior signed appcast whose bytes
match the tracked reviewed SHA-256 anchor.

## Automation and rollback

CI is intentionally keyless: it can lint metadata and exercise the fail-closed
preflight contract, but it cannot sign, notarize, edit the appcast, or publish a
release. Automation may be expanded only after two successful manual releases.

Tags and published artifacts are immutable. If a release is faulty, preserve
it for audit, remove it from the active appcast, and ship a higher-version fixed
release. Do not silently replace a ZIP or publish a downgrade through the feed.
The next release's history-anchor commit must reference the signed appcast
archived with that immutable release, even when an older item is removed from
the active feed.

Primary references:

- [Apple Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Sparkle documentation](https://sparkle-project.org/documentation/)
- [Publishing a Sparkle update](https://sparkle-project.org/documentation/publishing/)
- [Programmatic Sparkle setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle 2.9.4](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4)
