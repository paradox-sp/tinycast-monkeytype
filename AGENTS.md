# Repository Guidelines

## Project Overview

`monkeytype-unoffical` is a Tinycast `no-view` extension launching a standalone native macOS typing-practice window with quotes, timed sessions, live statistics, and results. Tinycast does not expose a custom extension view inside its palette; do not modify the host or introduce an undocumented WebKit transparency dependency.

## Architecture & Data Flow

Tinycast resolves `environment.assetsPath` → the command awaits macOS Launch Services through the existing subprocess bridge → the bundled AppKit helper loads a native passage provider and a JavaScriptCore typing engine → native text input, feedback, footer statistics, and results.

The JavaScript engine is trusted bundled code, not a browser or a remote script. Passages are data from Monkeytype’s public English corpus; they are never executed. A validated macOS URL event identifies the launching Tinycast channel; the helper follows that host’s actual appearance preference.

## Key Directories

- `src/extension/`: CommonJS Tinycast launcher; host API and Node shims remain external.
- `src/native/`: AppKit UI/lifecycle, JavaScriptCore adapter, passage provider, and native smoke.
- `src/engine/`: deterministic JavaScript session implementation shared by JavaScriptCore and Node tests.
- `assets/fonts/`: official JetBrains Mono TTF and required OFL license.
- `scripts/`: dependency-free Node build/packaging.
- `tests/`: deterministic `node:test` engine regressions.
- `docs/`: usage, architecture, and development instructions.
- `dist/`: generated installable extension; `release/`: generated universal ZIPs. Never hand-edit or commit build outputs, including the root launcher and `assets/monkeytype-unoffical.app`.

## Development Commands

```sh
npm run build     # compile/sign native helper and package dist/
npm run release   # compile both architectures and ZIP the installable dist/ folder
npm run dev       # open built helper without Tinycast
npm test          # engine regressions
npm run smoke     # actual AppKit window; requires build, GUI, internet
```

No dependency installation or lint command is needed for local development. Reinstall `dist/` through Tinycast’s Add from folder after rebuilding. Tinycast’s GitHub installer runs the build script and installs the checkout root, so the build must also generate the root command and helper app. Quit the older helper before reopening an updated build.

## Code Conventions & Common Patterns

- Swift UI and session ownership stay `@MainActor`; network fetch/JSON decoding leave the main actor. Use AppKit and public Liquid Glass APIs, not web-rendered controls or private KVC settings. The main surface is plain regular `NSGlassEffectView`, matching Tinycast 0.12.8; do not add a full-window black/white scrim.
- `TypingSession.swift` adapts one bulk JavaScriptCore snapshot per input/tick and caches display state. Keep scoring/input rules in `src/engine/typing-session.js`; inject timestamps for deterministic checks. Its derived-state cache must invalidate on typed or target changes without exposing mutable cached ranges/results.
- Native indices, `textRevision`, and `dirtyRange` use literal UTF-16 units, not Swift’s canonically equivalent string equality. `PassageRenderer.swift` colours only dirty spans, preserving a full repaint for passage/theme changes or skipped revisions.
- Keep only committed input/preedit in the transparent native editor, not the untyped target: ghost combining marks make AppKit snap the caret backwards. Preserve marked text; `PassageEditor.firstRect` anchors IME to the visible caret. Ordinary accepted edits need no text rewrite; rejected/session edits use a scalar-safe minimal replacement.
- Cache footer values and redraw progress only on change. Results keep keyboard focus/activation on the custom new-practice button without its focus ring; do not disable focus or global accessibility settings to remove that outline.
- The provider uses a private ephemeral URLSession with no disk cache or credentials. Cache the collection in memory; reject stale/cancelled passage loads. Show failures and manual retry, never fabricated passages.
- Preserve target-letter errors, the ASCII-space gate, correctly completed-word backspace lock, current-buffer accuracy, gross-character WPM, and early timed completion at passage end.
- Restart keeps the passage. New practice selects randomly without a uniqueness guarantee. Quote/timed families remember their own mode.
- WPM uses five characters per word and JavaScript rounding. Intentional safeguards: first multi-unit input starts timing; nonpositive duration scores 0 WPM.
- Follow Tinycast’s System/Light/Dark policy, not `environment.appearance`’s resolved snapshot. `HostAppearance.swift` reads only the `appearance` key from allowlisted host domains through public macOS preferences APIs. Observe filesystem changes without polling; never write host settings. System clears the app appearance override. Theme changes must preserve input. Preserve the helper’s existing preference domain and mode keys.
- Do not bundle proprietary third-party code or artwork or depend on private host IPC. Keep font licensing with packaged resources.

## Important Files

`package.json` declares the extension; `scripts/build.mjs` packages its launcher, native executable, engine, and font. `src/native/TypingPractice.swift` owns the window, modes/actions, footer/results, and host lifecycle. `PassageRenderer.swift` owns incremental text/caret layout; `NativeViews.swift` supplies AppKit input/views; `NativeSmoke.swift` owns native QA lifecycle and scenarios. `TypingSession.swift` owns the JavaScriptCore boundary, `HostAppearance.swift` follows host appearance, and `PassageProvider.swift` owns quote acquisition.

`.github/workflows/release.yml` publishes universal ZIPs on pushed `v*` tags matching `package.json`. It runs engine tests and extracted-package signature/architecture checks, not the GUI smoke. Publishing uses the built-in GitHub token; builds remain ad-hoc signed.

`README.md` stays a minimal quick start. Details belong in `docs/usage.md`, `docs/architecture.md`, and `docs/development.md`.

## Runtime/Tooling Preferences

Build on macOS 26+ with Swift 6.2+ command-line tools and Node.js 22+ / npm. No full Xcode, Bun, third-party runtime, or browser dependency. Tinycast runs the command in its JavaScriptCore runtime; the helper owns a separate JavaScriptCore context for the session engine. Development builds target the current architecture; releases combine arm64/x86_64 before signing. Both are ad-hoc signed, not notarized; do not claim warning-free public downloads. Prebuilt installations require no Node/Swift tools.

## Testing & QA

Use `node:test` for consumer-visible engine boundaries, not wording or source assertions. No coverage threshold is configured. Native smoke covers actual edits, Unicode/combining/IME composition, space/backspace boundaries, caret/line following, countdown-width changes, themes, restart/results and keyboard new practice. Inspect the result capture to verify the unwanted outline is absent; do not replace visual proof with a control-property assertion.

Packaging changes need a clean-source build using Tinycast’s package-manager arguments, catalog installation from the generated root and extracted `dist/`, architecture/signature checks, and a smoke run of the installed helper. A local catalog check does not prove GitHub downloads or the host’s GUI installer; verify those against the published URL before release.

Verify live Light/Dark/System preference changes from another process, including an unset preference, without relaunching or losing input. Smoke uses composited own-window captures and removes its isolated preference domain; never alter real Tinycast settings for a test. Material changes need a controlled backdrop and the installed release’s glass recipe, not unreleased upstream styles or cached-view snapshots. The stored host key is a compatibility boundary, not a full theme SDK; review it when Tinycast changes.
