# Releasing AuraFlow

1. Commit the complete source and tests, update the version and build number in `script/build_and_run.sh`, `scripts/build_release.sh`, and `scripts/build_screensaver.sh`, and update `README.md` and `CHANGELOG.md`.
2. Push the branch and open a pull request against `main`. All required CI jobs must pass on the final commit.
3. Build universal archives with `BUILD_UNIVERSAL=1 REQUIRE_UNIVERSAL=1 REQUIRE_CODESIGN=0 CODESIGN_IDENTITY='' FFMPEG_RUNTIME_BUNDLING=0 ./build_app.sh`. Supply standalone FFmpeg tools instead if bundling them.
4. Verify nested signatures with `codesign --verify --deep --strict dist/AuraFlow.app`, both architectures with `lipo -archs` for the app and every bundled helper, effects library and screen saver, the bundle version, and disk image integrity with `hdiutil verify dist/AuraFlow.dmg`. Unpack the ZIP and mount the DMG read-only to check their copies too. Generate `SHA256SUMS` for both archives. These ad-hoc signatures do not provide Apple notarization.
5. Merge the reviewed pull request (or push directly when explicitly requested by the owner), create and push a new annotated `vMAJOR.MINOR.PATCH` tag on the checked commit, then publish release notes with the checked DMG, ZIP, and checksums. Mark the release as **Latest** and verify `releases/latest` resolves to the new tag. Do not move an existing version tag.

The optional **Release** workflow is started manually on a version tag once Developer ID credentials are configured. It repeats CI, signs and notarizes the universal app, validates stapled tickets, checks Intel and Apple Silicon artifacts, and publishes DMG/ZIP/SHA256SUMS. Its signing requirements do not apply to the explicitly selected manual ad-hoc distribution path.

When local disk space is limited, manually dispatch **Build release archives** on
the intended branch or tag. It builds universal ad-hoc archives without signing
secrets, checks nested versions and architectures, and verifies ZIP/DMG copies on
Apple Silicon and Intel runners. Download its `release-archives` artifact and
check `BUILD-METADATA.txt` against the exact commit that passed the **Tests**
workflow. It does not publish anything: only tag and upload those archives after
both workflows pass for that commit. The separate notarized **Release** workflow
retains its Developer ID requirements.

For focused layout triage on macOS 15, manually dispatch **UI regression checks**.
It runs the same isolated window suites via `scripts/test_macos_app.sh --ui-only`.
This diagnostic workflow supplements the complete **Tests** run required for release.

When the owner explicitly requests replacing files in an existing release, keep
the marketing version, release ID, download filenames, and version tag unchanged.
Increment only the build number in all three build scripts, describe the refresh
in README/changelog and the release notes, and run both workflows on the exact
new source commit. Back up the existing assets before replacing all four files
with `gh release upload --clobber`. Verify the release API digests against the
downloaded archives and confirm that Latest still resolves to the same release.
Link the refreshed archives' exact source commit and validation runs in the
release notes and `BUILD-METADATA.txt`: GitHub's automatic source archives still
refer to the original version tag.

Both archive workflows now launch relocated ZIP and DMG copies on Intel and
Apple Silicon runners. Apple Silicon also runs the Intel slice through Rosetta 2.
The checks verify the loaded resource bundle is inside `Contents/Resources`,
reject missing or damaged resources with a useful reinstall message, and confirm
the GUI survives startup. Local equivalent after building universal archives:

```sh
python3 scripts/packaged_app_smoke.py dist/AuraFlow.app --arch arm64 --arch x86_64 --launch
```

`--launch` opens and closes only a temporary test copy; use a dedicated session
when running it unattended. Without that flag, validation exits before creating
wallpaper controllers and does not change playback or preferences.

The deployment-target job checks macOS 13 compatibility. Hosted smoke checks use currently supported GitHub runner images; they do not substitute for testing on a physical Mac running macOS 13.

## GitHub Actions secrets

Configure these under repository **Settings → Secrets and variables → Actions**. Never commit the certificate, passwords, or secret values.

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 export of the Developer ID Application certificate and its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the exported P12 |
| `APPLE_DEVELOPER_ID_APPLICATION` | Exact Developer ID Application signing identity |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that account |
| `APPLE_TEAM_ID` | Apple Developer team identifier |

An Apple Development certificate cannot replace Developer ID Application for the optional notarized distribution path. Missing credentials block that workflow, not the manual ad-hoc release path above.

For local packaging checks without public distribution, use `REQUIRE_CODESIGN=0 CODESIGN_IDENTITY='' ./build_app.sh`. Such artifacts are local validation builds and must not be described as notarized releases.

Optional bundled `ffmpeg` and `ffprobe` must be standalone portable binaries and contain both architectures for universal releases. Copying a Homebrew executable without its Cellar libraries is rejected. Use `AURAFLOW_FFMPEG_BIN` and `AURAFLOW_FFPROBE_BIN` to provide portable tools, or `FFMPEG_RUNTIME_BUNDLING=0` to retain the existing system-tool dependency for video preprocessing. Normal wallpaper playback does not need FFmpeg.
