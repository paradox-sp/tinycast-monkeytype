# Development and Installation

## Requirements

- Running: macOS 26+, Tinycast, and internet access to load passages.
- Building locally or installing from GitHub: Swift 6.2+ command-line tools (`xcode-select --install` if missing), Node.js 22+, and npm. No npm dependencies or full Xcode requirement.
- Prebuilt release folders need no Node.js or Swift installation.
- Tinycast is not needed to run the helper directly.

Tinycast executes the launcher in its JavaScriptCore runtime. The helper uses native AppKit controls and its own JavaScriptCore context for the bundled typing engine; it has no browser or WebKit dependency.

## Build and run

From the project root:

```sh
npm run build
npm run dev
```

The build creates `dist/package.json`, `dist/start-typing-practice.js`, and `dist/assets/monkeytype-unoffical.app`. It also generates `start-typing-practice.js` and `assets/monkeytype-unoffical.app` at the repository root for Tinycast’s GitHub installer. All are ignored build outputs; edit the sources in `src/`, not these files. A failed compilation leaves the previous build intact.

Development builds target this Mac’s architecture and are ad-hoc signed. Quit an already running helper with ⌘Q and reopen after rebuilding.

## Install in Tinycast

Enable extensions in **Settings → Extensions**, then choose either method:

- **GitHub:** Use **Install from GitHub** with the repository URL, or a GitHub `/tree/<tag>` URL to pin a release. Tinycast downloads sources, installs dependencies, runs the build script, and installs the generated root command and assets. Build tools must be installed and discoverable by Tinycast; select npm/configure its extension search paths if necessary. No generated binaries need committing.
- **Folder:** Choose **Install → Add from folder** and select **`dist/`** from a local build or an extracted release ZIP—not the helper `.app`. This installs an already built package.

Tinycast copies the manifest, command, and assets. Quit the helper and reinstall after updates; folder-installed extensions do not auto-update. If an older extension named `typing-practice` exists, remove it to avoid duplicate launcher entries. The helper’s preference domain remains unchanged.

The GitHub layout follows [Tinycast 0.12.8’s installer](https://github.com/abue-ammar/tinycast/blob/v0.12.8/Tinycast/Features/Extensions/Service/ExtensionInstaller.swift): custom builds are installed from the checkout root, not automatically discovered inside `dist/`. See [Tinycast’s installation guide](https://tinycast.dev/docs/extensions/installing/) for host setup.

## Prepare a public release

1. Publish this repository on GitHub with Actions enabled. Commit and push the source, `.github/workflows/release.yml`, and the desired version in `package.json`.
2. Run the local native smoke before tagging (`npm run build` then `npm run smoke`).
3. Tag that commit with `v` followed by the exact package version, then push the tag. For version `1.0.0`:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

The **Release** workflow runs on pushed `v*` tags using the `macos-26` runner and Node.js 22. It rejects a tag/version mismatch, runs `npm test`, invokes `npm run release`, and checks the extracted ZIP’s signature and both CPU architectures. Only then does it create a GitHub Release with generated notes and attach `monkeytype-unoffical-<version>-macos-universal.zip`. Tags containing a prerelease suffix, such as `v1.1.0-beta.1`, create prereleases.

The workflow uses GitHub’s built-in token with `contents: write`; no personal access token or custom secrets are needed. Repository/organization policy must allow Actions to publish releases. It does not overwrite existing releases: use a new version/tag for a new release. The hosted workflow does not run the interactive native smoke.

Users extract the release ZIP and add its enclosed `dist/` folder in Tinycast, or install from the source repository URL. Test both paths on a clean Mac before announcing a release.

No local archive creation or manual upload is required. `npm run release` remains the shared packaging command for CI or optional local checks: it compiles arm64/x86_64, combines them with `lipo`, signs the app, and ZIPs `dist/` with executable permissions. There is no npm publishing step; `private: true` does not prevent GitHub installation.

**Signing limit:** Current ZIPs are ad-hoc signed, not Developer ID signed or notarized. macOS may block browser-downloaded builds. For warning-free public distribution, Developer ID signing, appropriate hardened-runtime/JIT entitlements, notarization, and stapling must happen before the final ZIP is created; this build script does not perform them. Until then, direct blocked users to a local/GitHub source build—never disable Gatekeeper or strip quarantine. Re-running `npm run release` replaces any manually signed package with a new ad-hoc build.

## Verification

```sh
npm test          # deterministic node:test engine regressions
npm run build
npm run smoke     # real AppKit window, live quotes; opens and closes automatically
```

No lint command or coverage threshold is configured. Native smoke requires a graphical macOS login and internet access and does not change saved modes. It exercises actual native input, surrogate pairs, decomposed combining marks, IME candidate replacement/commit, rejected and corrected edits, caret/line following, word locks, paste prevention, countdown/WPM layout, restart/results, and keyboard new practice.

The smoke harness lives in `src/native/NativeSmoke.swift`. A real macOS URL binds the same running helper to a disposable preference domain; a separate `defaults` process changes Light/Dark/System and removes the key. It checks live rendering and preserved input, then removes its test domain. Real Tinycast preferences are never modified.

Engine regressions cover mode validation, scoring, corrections, timing boundaries, UTF-16 input, restart isolation, cache invalidation, and mutable-return isolation.

The smoke reports PNG paths from ScreenCaptureKit’s permission-free `SCShareableContent.currentProcess` own-window capture. Other applications and the desktop backdrop are excluded, so these images alone do not establish backdrop parity.

For UI changes, exercise actual native text input and inspect the window, not just model forwarding. Verify live preference changes without losing input, and that System removes any pinned appearance. For material changes, compare against the installed Tinycast release over the same backdrop; do not import unreleased tint/scrim layers. Automated native checks do not exercise Tinycast’s GUI installer, an actual macOS-wide appearance toggle, or every physical keyboard/IME interaction.

See [architecture.md](architecture.md#reference-and-fidelity-limits) for integration and licensing limits.

## Performance checks

Measure release (`-O`) builds with long passages; do not infer whole-app latency from engine-only timings. A controlled 8,192-unit prefix probe produced these mean CPU costs:

| Probe | Before (ms/input) | After (ms/input) |
| --- | ---: | ---: |
| Swift/JavaScriptCore input and state refresh | 0.606 | 0.314 |
| Native TextKit append/backspace plus rendering | 2.140 | 0.779 |

The TextKit comparison used the same optimized engine for both renderers and a 9,500-character target, isolating renderer changes. It excludes WindowServer/GPU presentation, networking, and physical IME interaction; timings are observations on this Mac, not CI thresholds. Recheck Unicode, rejected edits, and composition alongside any further hot-path change.

