# Releasing AuraFlow

1. Commit the complete source and tests, update the version in both build scripts, and update `CHANGELOG.md`.
2. Push the branch and open a pull request against `main`. All required CI jobs must pass on the final commit.
3. Merge the reviewed pull request and create an annotated `vMAJOR.MINOR.PATCH` tag on that commit.
4. Push the tag. The Release workflow repeats CI on the tagged source, builds a universal app, signs and notarizes it, validates the stapled tickets, and smoke-checks the artifacts on Apple Silicon and Intel runners.
5. GitHub publishes the DMG, ZIP, and `SHA256SUMS` only after every release job succeeds. Failed signing or notarization never falls back to an ad-hoc public release.

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

An Apple Development certificate cannot replace Developer ID Application for this distribution path. Missing credentials block publication; CI and a draft release can still be prepared.

For local packaging checks without public distribution, use `REQUIRE_CODESIGN=0 CODESIGN_IDENTITY='' ./build_app.sh`. Such artifacts are local validation builds and must not be described as notarized releases.

Optional bundled `ffmpeg` and `ffprobe` must be standalone portable binaries and contain both architectures for universal releases. Copying a Homebrew executable without its Cellar libraries is rejected. Use `AURAFLOW_FFMPEG_BIN` and `AURAFLOW_FFPROBE_BIN` to provide portable tools, or `FFMPEG_RUNTIME_BUNDLING=0` to retain the existing system-tool dependency for video preprocessing. Normal wallpaper playback does not need FFmpeg.
