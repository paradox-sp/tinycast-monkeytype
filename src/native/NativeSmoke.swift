import AppKit
import QuartzCore
import ScreenCaptureKit
import Darwin

@MainActor
final class NativeSmoke {
    let hostDomain = "app.tinycast.typing-practice.smoke.\(UUID().uuidString)"
    private(set) var finished = false
    private var cleanedUp = false
    private var urlContinuation: CheckedContinuation<Void, Never>?
    private var deadline: Timer?
    private var runTask: Task<Void, Never>?
    private var assertions: [[String: Any]] = []
    private var images: [String: String] = [:]

    func start(application: PracticeApplication) {
        let timer = Timer(timeInterval: 45, repeats: false) { [weak self, weak application] _ in
            Task { @MainActor [weak self, weak application] in
                guard let self, let application else { return }
                self.finish(passed: false, details: ["error": "Native smoke timed out waiting for input, URL event, or quote provider."], application: application)
            }
        }
        deadline = timer
        RunLoop.main.add(timer, forMode: .common)
        runTask = Task { @MainActor [weak self, weak application] in
            guard let self, let application else { return }
            await self.run(application)
        }
    }

    func didReceiveURL() {
        urlContinuation?.resume()
        urlContinuation = nil
    }

    func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        deadline?.invalidate()
        deadline = nil
        runTask?.cancel()
        runTask = nil
        didReceiveURL()
        UserDefaults.standard.removePersistentDomain(forName: hostDomain)
        CFPreferencesAppSynchronize(hostDomain as CFString)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(hostDomain).plist")
        try? FileManager.default.removeItem(at: file)
    }

    func finish(passed: Bool, details: [String: Any], application: PracticeApplication) {
        guard !finished else { return }
        finished = true
        application.tearDown()
        var report = details
        report["status"] = passed ? "PASS" : "FAIL"
        report["test"] = "Native AppKit typing practice"
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
            ?? Data("{\"status\":\"FAIL\",\"error\":\"Could not serialize smoke result\"}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        Darwin.exit(passed ? 0 : 1)
    }

    nonisolated private func failure(_ message: String) -> NSError {
        NSError(domain: "TypingPracticeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func check(_ condition: Bool, _ name: String, _ observed: Any) throws {
        assertions.append(["name": name, "passed": condition, "observed": observed])
        if !condition { throw failure(name) }
    }

    private func captureImage(_ application: PracticeApplication, named name: String) async throws -> String {
        guard let window = application.window else { throw failure("Native smoke has no window to capture.") }
        application.glass.layoutSubtreeIfNeeded()
        application.glass.displayIfNeeded()
        CATransaction.flush()
        // AppKit animates appearance changes; sample after that compositor transition.
        try await Task.sleep(for: .milliseconds(350))
        let data = try await captureOwnWindow(number: window.windowNumber,
            width: Int(application.glass.bounds.width * window.backingScaleFactor),
            height: Int(application.glass.bounds.height * window.backingScaleFactor))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("monkeytype-native-\(getpid())-\(name).png")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    nonisolated private func captureOwnWindow(number: Int, width: Int, height: Int) async throws -> Data {
        // This API is restricted to our own windows and requires no Screen Recording grant.
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else {
            throw failure("Native smoke could not find its own composited window.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw failure("Native smoke could not encode its window capture.")
        }
        return data
    }

    private func waitForPractice(_ application: PracticeApplication) async throws {
        let deadline = Date().addingTimeInterval(30)
        while application.state == .loading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard application.state == .practice, application.session != nil else {
            throw failure("Quote provider did not enable native input: \(application.statusTitle.stringValue) \(application.statusDetail.stringValue)")
        }
    }

    private func selectMode(_ id: String, in application: PracticeApplication) throws {
        guard let item = application.modePopup.itemArray.first(where: { $0.representedObject as? String == id }) else {
            throw failure("Smoke could not find mode \(id).")
        }
        application.modePopup.select(item)
        NSApp.sendAction(#selector(PracticeApplication.modeChanged(_:)), to: application, from: application.modePopup)
    }

    private func writeAppearance(_ value: String?) async throws {
        // A separate process exercises cfprefsd/cache invalidation, not a same-process mock.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/defaults")
            process.arguments = value.map { ["write", hostDomain, "appearance", "-string", $0] }
                ?? ["delete", hostDomain, "appearance"]
            process.terminationHandler = { completed in
                if completed.terminationStatus == 0 { continuation.resume() }
                else {
                    continuation.resume(throwing: NSError(domain: "TypingPracticeSmoke", code: Int(completed.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Could not update the disposable appearance preference."]))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private func waitForHostAppearance(_ selection: HostAppearance, in application: PracticeApplication) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if application.hostAppearance == selection &&
                (selection == .system ? NSApp.appearance == nil : application.currentScheme == selection.rawValue) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw failure("Native appearance did not follow Tinycast’s \(selection.rawValue) preference.")
    }

    private func keyEvent(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                          in application: PracticeApplication) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: application.window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
            throw failure("Could not construct native keyboard event.")
        }
        return event
    }

    private func exerciseUnicodeInput(_ application: PracticeApplication) async throws {
        let passage = Passage(id: -1, text: "A😀 e\u{301} 日本 fin", source: "Native input regression")
        try application.startPassage(passage)
        guard let session = application.session else { throw failure("Native Unicode session disappeared.") }
        let editor = application.editor
        editor.insertText("A😀", replacementRange: NSRange(location: 0, length: 0))
        try check(session.typed == "A😀" && editor.selectedRange() == NSRange(location: 3, length: 0) &&
            editor.string == "A😀" && application.targetText.string == passage.text,
            "native surrogate-pair insertion preserves target and UTF-16 caret", editor.string)
        editor.insertText("x", replacementRange: editor.selectedRange())
        try check(session.typed == "A😀" && editor.string == "A😀" && application.targetText.string == passage.text &&
            editor.selectedRange() == NSRange(location: 3, length: 0),
            "rejected native edit restores committed input and caret", editor.string)
        editor.insertText(" ", replacementRange: editor.selectedRange())
        editor.insertText("e", replacementRange: editor.selectedRange())
        editor.insertText("\u{301}", replacementRange: editor.selectedRange())
        let combinedPrefix = "A😀 e\u{301}"
        try check(Array(session.typed.utf16) == Array(combinedPrefix.utf16) &&
            Array(editor.string.utf16) == Array(combinedPrefix.utf16) && application.targetText.string == passage.text &&
            editor.selectedRange() == NSRange(location: combinedPrefix.utf16.count, length: 0),
            "separate native combining-mark insertion preserves decomposed text", session.typed)
        editor.insertText("x", replacementRange: NSRange(location: 4, length: 2))
        let mistakeInk = application.targetText.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        try check(session.typed == "A😀 x" && !session.mistakes.isEmpty && mistakeInk == .systemRed,
            "native replacement paints a real typing error", session.typed)
        editor.insertText("e\u{301}", replacementRange: NSRange(location: 4, length: 1))
        let correctedInk = application.targetText.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        let primary: NSColor = application.currentScheme == "dark" ? .white : .black
        try check(Array(session.typed.utf16) == Array(combinedPrefix.utf16) && session.mistakes.isEmpty &&
            correctedInk == primary && Array(editor.string.utf16) == Array(combinedPrefix.utf16) &&
            application.targetText.string == passage.text && editor.selectedRange().location == combinedPrefix.utf16.count,
            "native correction clears stale error ink without changing the target", session.typed)
        editor.insertText(" ", replacementRange: editor.selectedRange())
        let beforeComposition = session.typed
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        try check(editor.hasMarkedText() && session.typed == beforeComposition,
            "native IME preedit stays outside committed scoring", session.typed)
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(editor.hasMarkedText() && session.typed == beforeComposition &&
            (editor.string as NSString).substring(with: editor.markedRange()) == "日本",
            "native IME candidate replacement preserves active composition", editor.string)
        editor.unmarkText()
        let committed = beforeComposition + "日本"
        let deadline = Date().addingTimeInterval(1)
        while session.typed != committed, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(!editor.hasMarkedText() && session.typed == committed && editor.string == committed &&
            application.targetText.string == passage.text &&
            editor.selectedRange() == NSRange(location: committed.utf16.count, length: 0) && session.mistakes.isEmpty,
            "native IME commit reconciles once without duplicating target characters", editor.string)
        editor.insertText("an oversized native edit", replacementRange: editor.selectedRange())
        try check(session.typed == committed && editor.string == committed && application.targetText.string == passage.text &&
            editor.selectedRange() == NSRange(location: committed.utf16.count, length: 0),
            "oversized native insertion is rejected after composition", editor.string)
    }

    private func exerciseTimedFooter(_ application: PracticeApplication) async throws {
        try application.startPassage(Passage(id: -2, text: "a b c", source: "Native countdown regression"))
        guard let session = application.session else { throw failure("Native timed session disappeared.") }
        application.editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        let deadline = Date().addingTimeInterval(9)
        while (session.remaining ?? 0) > 10, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try check(session.remaining == 10 && !application.remainingLabel.isHidden && !application.wpmLabel.isHidden,
            "native timer updates the live countdown and WPM", application.remainingLabel.stringValue)
        let countdownWidth = application.remainingLabel.frame.width
        let wpmX = application.wpmLabel.frame.minX
        let wpm = session.liveWpm
        while (session.remaining ?? 0) > 9, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let widthChange = application.remainingLabel.frame.width - countdownWidth
        let positionChange = application.wpmLabel.frame.minX - wpmX
        try check(session.remaining == 9 && session.liveWpm == wpm && widthChange < 0 &&
            abs(positionChange - widthChange) < 1,
            "unchanged live WPM follows a narrowing countdown label",
            ["countdown": application.remainingLabel.stringValue, "widthChange": widthChange, "positionChange": positionChange])
    }

    private func run(_ application: PracticeApplication) async {
        do {
            try await waitForPractice(application)
            try selectMode("time-15s", in: application)
            try await waitForPractice(application)
            if let timed = application.session {
                let initialOrigin = application.passageContent.frame.minY
                let initialCaret = application.caret.convert(application.caret.bounds, to: application.root)
                let target = timed.passage.text as NSString
                let prefix = target.substring(to: min(250, target.length - 1))
                application.editor.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
                let visibleCaret = application.caret.convert(application.caret.bounds, to: application.root)
                try check(timed.typed == prefix && application.passageContent.frame.minY < initialOrigin &&
                    abs(visibleCaret.minY - initialCaret.minY) < 1,
                    "long native passages follow the caret without editor scrolling", application.passageContent.frame.minY)
            }
            try await exerciseTimedFooter(application)
            try selectMode("quote-short", in: application)
            try await waitForPractice(application)
            guard let providerPassage = application.session?.passage else { throw failure("Native quote session disappeared.") }
            try await exerciseUnicodeInput(application)
            try application.startPassage(providerPassage)
            if let target = application.session?.passage.text, let space = target.firstIndex(of: " ") {
                let word = String(target[..<space])
                application.editor.insertText(word, replacementRange: NSRange(location: 0, length: 0))
                application.editor.insertText("x", replacementRange: application.editor.selectedRange())
                try check(application.session?.typed == word, "native input gates target spaces", application.session?.typed ?? "")
                application.editor.insertText(" ", replacementRange: application.editor.selectedRange())
                application.editor.keyDown(with: try keyEvent("\u{8}", code: 51, in: application))
                try check(application.session?.typed == word + " ", "native backspace locks completed correct words", application.session?.typed ?? "")
                application.restartPractice(showToast: false)
            }
            guard let session = application.session else { throw failure("Native session disappeared.") }
            let passage = session.passage
            let words = passage.text.split(separator: " ", omittingEmptySubsequences: false)
            let prefix = String(passage.text.prefix(max(3, (words.first?.count ?? 1) + 2)))
            application.editor.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
            try check(session.typed == prefix && application.editor.selectedRange().location == prefix.utf16.count,
                "NSTextView commits the typed prefix", session.typed)
            try check(session.progress > 0 && session.progress < 1 && !application.caret.isHidden,
                "native partial progress and visible caret", session.progress)
            let initialScheme = application.currentScheme
            let initialGeneration = application.themeEventGeneration
            for raw in ["https://open?host=com.tinycast.app", "monkeytype-unoffical://other?host=com.tinycast.app",
                "monkeytype-unoffical://open/path?host=com.tinycast.app", "monkeytype-unoffical://user@open?host=com.tinycast.app",
                "monkeytype-unoffical://open:123?host=com.tinycast.app", "monkeytype-unoffical://open?host=com.tinycast.app#fragment",
                "monkeytype-unoffical://open", "monkeytype-unoffical://open?host=com.apple.finder",
                "monkeytype-unoffical://open?host=app.tinycast.typing-practice.smoke.forbidden",
                "monkeytype-unoffical://open?host=", "monkeytype-unoffical://open?appearance=dark",
                "monkeytype-unoffical://open?host=com.tinycast.app&host=com.tinycast.app.dev",
                "monkeytype-unoffical://open?host=com.tinycast.app&unexpected=true"] {
                application.application(NSApp, open: [URL(string: raw)!])
                try check(application.themeEventGeneration == initialGeneration && application.currentScheme == initialScheme &&
                    application.session === session && session.typed == prefix,
                    "malformed launch URL leaves appearance and session unchanged", raw)
            }
            try await writeAppearance("dark")
            let generation = application.themeEventGeneration
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.allowsRunningApplicationSubstitution = false
            let url = URL(string: "monkeytype-unoffical://open?host=\(hostDomain)")!
            let processID: pid_t = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application { continuation.resume(returning: application.processIdentifier) }
                    else { continuation.resume(throwing: NSError(domain: "TypingPracticeSmoke", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Launch Services did not return a running helper."])) }
                }
            }
            try check(processID == getpid(), "URL handoff reuses the same helper process", processID)
            if application.themeEventGeneration == generation {
                await withCheckedContinuation { urlContinuation = $0 }
            }
            try await waitForHostAppearance(.dark, in: application)
            try check(application.themeEventGeneration == generation + 1 && session.typed == prefix,
                "host binding applies the selected appearance without resetting practice", application.currentScheme)
            images["dark"] = try await captureImage(application, named: "dark")
            var appearances = ["dark"]
            for selection: HostAppearance in [.light, .system, .dark] {
                try await writeAppearance(selection.rawValue)
                try await waitForHostAppearance(selection, in: application)
                let scheme = application.currentScheme
                let expectedPrimary: NSColor = scheme == "dark" ? .white : .black
                let actualInk = application.targetText.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                try check(application.themeEventGeneration == generation + 1 && actualInk == expectedPrimary,
                    "live host preference repaints native controls without relaunch", selection.rawValue)
                try check(application.session === session && session.typed == prefix &&
                    application.editor.selectedRange() == NSRange(location: prefix.utf16.count, length: 0) &&
                    application.selectedMode?.id == "quote-short" && application.state == .practice,
                    "live theme change preserves input, caret, mode, and session", selection.rawValue)
                appearances.append(selection.rawValue)
                images[selection.rawValue] = try await captureImage(application, named: selection.rawValue)
            }
            try await writeAppearance(nil)
            try await waitForHostAppearance(.system, in: application)
            try check(NSApp.appearance == nil && application.session === session && session.typed == prefix,
                "an unset host preference restores live macOS appearance without resetting practice", application.currentScheme)
            let wpmDeadline = Date().addingTimeInterval(3)
            while session.liveWpm == nil, Date() < wpmDeadline { try await Task.sleep(for: .milliseconds(50)) }
            let wpmFrame = application.wpmLabel.frame
            try check(!application.wpmLabel.isHidden && wpmFrame.minX < application.footer.bounds.midX && wpmFrame.minY >= 0 &&
                wpmFrame.maxY <= application.footer.bounds.height,
                "live WPM remains in the bottom-left native footer", application.wpmLabel.stringValue)
            images["practice"] = try await captureImage(application, named: "practice")
            let typedBeforePaste = session.typed
            application.editor.paste(nil)
            try check(session.typed == typedBeforePaste, "native input rejects paste", session.typed)
            NSApp.sendAction(#selector(PracticeApplication.restartAction(_:)), to: application, from: nil)
            guard let restarted = application.session else { throw failure("Restart removed the native session.") }
            try check(restarted.passage.text == passage.text && restarted.passage.id == passage.id &&
                restarted.typed.isEmpty && application.editor.selectedRange().location == 0 && application.progressRing.progress == 0 && application.wpmLabel.isHidden,
                "restart retains passage and resets input and live footer", restarted.passage.id)
            application.editor.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
            try await Task.sleep(for: .milliseconds(200))
            let rest = (passage.text as NSString).substring(from: restarted.typedLength)
            application.editor.insertText(rest, replacementRange: NSRange(location: restarted.typedLength, length: 0))
            guard let result = restarted.result else { throw failure("Completing the passage did not produce results.") }
            try check(application.state == .results && !application.results.isHidden && application.wpmLabel.isHidden,
                "completion shows native results and hides live footer", result.wpm)
            try check(result.correctCount == passage.text.utf16.count && result.incorrectCount == 0 &&
                result.accuracy == 1 && result.wpm > 0,
                "native completion retains engine scoring", ["correct": result.correctCount, "incorrect": result.incorrectCount, "wpm": result.wpm])
            let scoreWidth = (application.resultWpm.stringValue as NSString).size(withAttributes: [.font: application.resultWpm.font!]).width
            try check(scoreWidth <= application.resultWpm.bounds.width - 4,
                "large WPM values fit the native results column", ["textWidth": scoreWidth, "columnWidth": application.resultWpm.bounds.width])
            try check(application.window?.firstResponder === application.newButton,
                "results retain keyboard focus on the new-practice action", application.newButton.title)
            images["results"] = try await captureImage(application, named: "results")
            let newPractice = try keyEvent("\r", code: 36, modifiers: .command, in: application)
            let handled = application.window?.performKeyEquivalent(with: newPractice) == true
            try check(handled && application.state == .loading && application.session == nil,
                "Command-Return starts a new practice from focused results", handled)
            try await waitForPractice(application)
            try check(application.session !== restarted && application.session?.typed.isEmpty == true &&
                application.window?.firstResponder === application.editor && !application.caret.isHidden,
                "keyboard new practice loads a fresh session and restores native typing focus", application.selectedMode?.id ?? "")
            finish(passed: true, details: ["assertions": assertions, "appearances": appearances, "images": images,
                "passageLength": passage.text.utf16.count, "results": ["correct": result.correctCount,
                    "incorrect": result.incorrectCount, "accuracy": result.accuracy * 100, "wpm": result.wpm]], application: application)
        } catch {
            if let image = try? await captureImage(application, named: "failure") { images["failure"] = image }
            finish(passed: false, details: ["assertions": assertions, "images": images, "error": error.localizedDescription], application: application)
        }
    }
}
