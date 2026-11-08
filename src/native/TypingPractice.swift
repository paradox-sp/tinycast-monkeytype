import AppKit
import CoreText
import QuartzCore


@MainActor
final class PracticeApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    enum ViewState { case loading, practice, error, results }
    private let smoke: Bool
    private let smokeHarness: NativeSmoke?
    private let provider = PassageProvider()
    private var engine: TypingEngine?
    private(set) var session: TypingSession?
    private(set) var selectedMode: PracticeMode?
    private var passageFont: NSFont?
    private var renderer: PassageRenderer?
    private(set) var state = ViewState.loading
    private var editorFocused = false
    private var resourceFailure = false
    private var requestID = 0
    private var loadTask: Task<Void, Never>?
    private var practiceTimer: Timer?
    private var toastTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var hostAppearanceObservation: HostAppearanceObserver?
    private(set) var hostAppearance = HostAppearance.system
    private var colorObservation: NSObjectProtocol?
    private var accessibilityObservation: NSObjectProtocol?
    private var hasActivated = false
    private var activationGeneration = 0
    private var suppressNextActivation = false
    private(set) var themeEventGeneration = 0
    private(set) var window: PracticeWindow?
    let glass = NSGlassEffectView()
    let root = FlippedView()
    private let headerTitle = NSTextField(labelWithString: "monkeytype-unoffical")
    private let backButton = NSButton()
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passageMask = PassageMask()
    let passageContent = FlippedView()
    let targetText = NSTextView()
    let editor = PassageEditor()
    let caret = CaretView()
    private let status = FlippedView()
    let statusTitle = NSTextField(labelWithString: "Loading quotes…")
    let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    let footer = FlippedView()
    private let footerLine = NSView()
    let progressRing = ProgressRing(frame: NSRect(x: 16, y: 18, width: 16, height: 16))
    let remainingLabel = NSTextField(labelWithString: "")
    let wpmLabel = NSTextField(labelWithString: "")
    private var displayedRemaining: Int?
    private var displayedWpm: Int?
    private var footerIsCurrent = false
    private let commandLabel = NSTextField(labelWithString: "⌨  monkeytype-unoffical")
    private let actionsButton = NSButton(title: "Actions  ⌘ K", target: nil, action: nil)
    let newButton = NSButton(title: "Start New Practice  ⌘ ↵", target: nil, action: nil)
    private let footerDivider = NSView()
    let results = FlippedView()
    private let resultCard = NSGlassEffectView()
    private let resultCardContent = FlippedView()
    let resultWpm = NSTextField(labelWithString: "0")
    private let resultSource = NSTextField(wrappingLabelWithString: "")
    private let resultAccuracy = NSTextField(labelWithString: "")
    private let resultTime = NSTextField(labelWithString: "")
    private let resultCorrect = NSTextField(labelWithString: "")
    private let resultIncorrect = NSTextField(labelWithString: "")
    private var secondaryLabels: [NSTextField] = []
    private var tertiaryLabels: [NSTextField] = []
    private let toastGlass = NSGlassEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var primary = NSColor.white
    private var secondary = NSColor.white.withAlphaComponent(0.6)
    private var tertiary = NSColor.white.withAlphaComponent(0.4)
    private var separator = NSColor.white.withAlphaComponent(0.1)
    private let modeKey = "typing-practice::last-used-mode"
    private let quoteKey = "typing-practice::last-used-quote-mode"
    private let timeKey = "typing-practice::last-used-time-mode"

    init(smoke: Bool) {
        self.smoke = smoke
        smokeHarness = smoke ? NativeSmoke() : nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createWindow()
        installMenu()
        observeAppearance()
        refreshAppearance()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            guard let resources = Bundle.main.resourceURL else {
                throw resourceError("The helper has no resource directory. Launch the built .app bundle.")
            }
            let fontURL = resources.appendingPathComponent("JetBrainsMono-Regular.ttf")
            guard FileManager.default.fileExists(atPath: fontURL.path) else {
                throw resourceError("The bundled JetBrains Mono font is missing. Rebuild and reinstall the extension.")
            }
            var fontError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError)
            if !registered {
                guard let error = fontError?.takeRetainedValue() else {
                    throw resourceError("The bundled JetBrains Mono font could not be registered.")
                }
                if CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                    throw resourceError("The bundled JetBrains Mono font could not be registered: \(error)")
                }
            }
            guard let font = NSFont(name: "JetBrainsMono-Regular", size: 24) else {
                throw resourceError("The bundled JetBrains Mono font could not be loaded.")
            }
            passageFont = font
            renderer = PassageRenderer(targetText: targetText, editor: editor, content: passageContent,
                caret: caret, paragraphStyle: paragraphStyle())
            engine = try TypingEngine(engineURL: resources.appendingPathComponent("typing-session.js"))
            configureModes()
            newPractice()
            smokeHarness?.start(application: self)
        } catch {
            resourceFailure = true
            showFailure(title: "Could not start typing practice", detail: error.localizedDescription)
            smokeHarness?.finish(passed: false, details: ["error": error.localizedDescription], application: self)
        }
    }

    nonisolated private func resourceError(_ message: String) -> NSError {
        NSError(domain: "TypingPractice", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func createWindow() {
        let panel = PracticeWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 474),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "monkeytype-unoffical"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.handleShortcut = { [weak self] event in self?.handleShortcut(event) ?? false }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        glass.frame = NSRect(x: 0, y: 0, width: 750, height: 474)
        glass.style = .regular
        glass.cornerRadius = 26
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 26
        glass.layer?.masksToBounds = true
        root.frame = glass.bounds
        glass.contentView = root
        panel.contentView = glass
        createHeader()
        createPassage()
        createStatus()
        createResults()
        createFooter()
        toastGlass.style = .regular
        toastGlass.cornerRadius = 10
        toastGlass.isHidden = true
        toastGlass.contentView = toastLabel
        toastLabel.alignment = .center
        toastLabel.font = .systemFont(ofSize: 12)
        root.addSubview(toastGlass)
        window = panel
        setView(.loading)
    }

    private func createHeader() {
        backButton.frame = NSRect(x: 12, y: 12, width: 28, height: 28)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(backAction(_:))
        backButton.toolTip = "Back (Esc)"
        root.addSubview(backButton)
        modePopup.frame = NSRect(x: 265, y: 10, width: 220, height: 32)
        modePopup.isBordered = false
        modePopup.font = .systemFont(ofSize: 14, weight: .medium)
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityLabel("Practice mode")
        root.addSubview(modePopup)
        headerTitle.frame = NSRect(x: 210, y: 17, width: 330, height: 22)
        headerTitle.alignment = .center
        headerTitle.font = .systemFont(ofSize: 14, weight: .medium)
        root.addSubview(headerTitle)
        for x in [60.0, 510.0] {
            root.addSubview(HeaderDragView(frame: NSRect(x: x, y: 0, width: 180, height: 52)))
        }
    }

    private func createPassage() {
        passageMask.frame = NSRect(x: 0, y: 52, width: 750, height: 370)
        passageMask.wantsLayer = true
        passageMask.layer?.masksToBounds = true
        let gradient = CAGradientLayer()
        gradient.frame = passageMask.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 0, y: 1)
        gradient.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.3).cgColor,
            NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.2).cgColor, NSColor.clear.cgColor]
        gradient.locations = [0, NSNumber(value: 113.0 / 370), NSNumber(value: 163.0 / 370),
            NSNumber(value: 243.0 / 370), NSNumber(value: 293.0 / 370), 1]
        passageMask.layer?.mask = gradient
        passageContent.frame = NSRect(x: 40, y: 143, width: 670, height: 400)
        for text in [targetText, editor] {
            text.frame = NSRect(x: 0, y: 0, width: 670, height: 400)
            text.drawsBackground = false
            text.isRichText = false
            text.importsGraphics = false
            text.textContainerInset = .zero
            text.textContainer?.lineFragmentPadding = 0
            text.textContainer?.containerSize = NSSize(width: 670, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.isHorizontallyResizable = false
            text.isVerticallyResizable = false
            text.layoutManager?.allowsNonContiguousLayout = false
            passageContent.addSubview(text)
        }
        targetText.isEditable = false
        targetText.isSelectable = false
        targetText.setAccessibilityElement(false)
        editor.delegate = self
        editor.isEditable = true
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.insertionPointColor = .clear
        editor.textColor = .clear
        editor.selectedTextAttributes = [.backgroundColor: NSColor.clear, .foregroundColor: NSColor.clear]
        editor.markedTextAttributes = [.foregroundColor: NSColor.clear]
        editor.unregisterDraggedTypes()
        passageMask.activateInput = { [weak self] in
            guard let self, self.state == .practice else { return }
            self.window?.makeFirstResponder(self.editor)
        }
        editor.setAccessibilityLabel("Type the passage")
        editor.canBackspace = { [weak self] in self?.session?.backspaceAllowed ?? false }
        editor.focusChanged = { [weak self] focused in
            self?.editorFocused = focused
            self?.updateCaretBlink()
        }
        editor.cancel = { [weak self] in self?.backAction(nil) }
        editor.compositionAnchor = { [weak self] in
            guard let self, let window = self.window else { return nil }
            return window.convertToScreen(self.caret.convert(self.caret.bounds, to: nil))
        }
        editor.compositionEnded = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.commitEditor() }
        }
        caret.wantsLayer = true
        caret.layer?.cornerRadius = 1
        caret.setAccessibilityElement(false)
        passageContent.addSubview(caret)
        passageMask.addSubview(passageContent)
        root.addSubview(passageMask)
    }

    private func createStatus() {
        status.frame = NSRect(x: 90, y: 150, width: 570, height: 180)
        spinner.frame = NSRect(x: 275, y: 0, width: 20, height: 20)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        status.addSubview(spinner)
        statusTitle.frame = NSRect(x: 0, y: 36, width: 570, height: 24)
        statusTitle.alignment = .center
        statusTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        status.addSubview(statusTitle)
        statusDetail.frame = NSRect(x: 20, y: 68, width: 530, height: 50)
        statusDetail.alignment = .center
        statusDetail.font = .systemFont(ofSize: 13)
        status.addSubview(statusDetail)
        retryButton.frame = NSRect(x: 220, y: 126, width: 130, height: 30)
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryAction(_:))
        status.addSubview(retryButton)
        secondaryLabels.append(statusDetail)
        root.addSubview(status)
    }

    private func createFooter() {
        footer.frame = NSRect(x: 0, y: 422, width: 750, height: 52)
        footerLine.frame = NSRect(x: 0, y: 0, width: 750, height: 1)
        footerLine.wantsLayer = true
        footer.addSubview(footerLine)
        footer.addSubview(progressRing)
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        wpmLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        footer.addSubview(remainingLabel)
        footer.addSubview(wpmLabel)
        commandLabel.frame = NSRect(x: 16, y: 17, width: 260, height: 20)
        commandLabel.font = .systemFont(ofSize: 12)
        footer.addSubview(commandLabel)
        actionsButton.frame = NSRect(x: 636, y: 12, width: 98, height: 28)
        actionsButton.isBordered = false
        actionsButton.font = .systemFont(ofSize: 12)
        actionsButton.target = self
        actionsButton.action = #selector(actionsAction(_:))
        actionsButton.setAccessibilityLabel("Practice actions")
        footer.addSubview(actionsButton)
        footerDivider.frame = NSRect(x: 624, y: 19, width: 1, height: 14)
        footerDivider.wantsLayer = true
        footer.addSubview(footerDivider)
        newButton.frame = NSRect(x: 432, y: 12, width: 180, height: 28)
        newButton.isBordered = false
        newButton.focusRingType = .none
        newButton.font = .systemFont(ofSize: 12, weight: .medium)
        newButton.target = self
        newButton.action = #selector(newAction(_:))
        footer.addSubview(newButton)
        secondaryLabels += [commandLabel, wpmLabel]
        root.addSubview(footer)
    }

    private func createResults() {
        results.frame = NSRect(x: 0, y: 52, width: 750, height: 370)
        resultCard.frame = NSRect(x: 135, y: 50, width: 480, height: 220)
        resultCard.style = .regular
        resultCard.cornerRadius = 18
        resultCardContent.frame = resultCard.bounds
        resultCard.contentView = resultCardContent
        results.addSubview(resultCard)
        addResultCaption("WPM", frame: NSRect(x: 32, y: 22, width: 180, height: 20))
        resultWpm.frame = NSRect(x: 28, y: 37, width: 195, height: 100)
        resultWpm.font = .systemFont(ofSize: 82, weight: .bold)
        resultCardContent.addSubview(resultWpm)
        addResultCaption("Source", frame: NSRect(x: 32, y: 144, width: 180, height: 18))
        resultSource.frame = NSRect(x: 32, y: 166, width: 190, height: 42)
        resultSource.font = .systemFont(ofSize: 13)
        resultCardContent.addSubview(resultSource)
        for (index, pair) in [("Accuracy", resultAccuracy), ("Time", resultTime),
            ("Correct", resultCorrect), ("Incorrect", resultIncorrect)].enumerated() {
            let x = index % 2 == 0 ? 260.0 : 370.0
            let y = index < 2 ? 52.0 : 128.0
            addResultCaption(pair.0, frame: NSRect(x: x, y: y, width: 100, height: 20))
            pair.1.frame = NSRect(x: x, y: y + 24, width: 102, height: 28)
            pair.1.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
            resultCardContent.addSubview(pair.1)
        }
        let attribution = NSTextField(labelWithString: "Quotes provided by")
        attribution.frame = NSRect(x: 270, y: 304, width: 115, height: 20)
        attribution.alignment = .right
        attribution.font = .systemFont(ofSize: 12)
        results.addSubview(attribution)
        let link = NSButton(title: "monkeytype", target: self, action: #selector(openAttribution(_:)))
        link.frame = NSRect(x: 386, y: 299, width: 94, height: 28)
        link.isBordered = false
        link.font = .systemFont(ofSize: 12, weight: .medium)
        results.addSubview(link)
        secondaryLabels += [resultSource, resultAccuracy, resultTime, resultCorrect, resultIncorrect]
        tertiaryLabels.append(attribution)
        root.addSubview(results)
    }

    private func addResultCaption(_ title: String, frame: NSRect) {
        let label = NSTextField(labelWithString: title)
        label.frame = frame
        label.font = .systemFont(ofSize: 13)
        resultCardContent.addSubview(label)
        tertiaryLabels.append(label)
    }

    private func configureModes() {
        guard let engine else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for timed in [false, true] {
            if timed { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: timed ? "Time" : "Quotes", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for mode in engine.modes where mode.isTimed == timed {
                let item = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
                item.representedObject = mode.id
                menu.addItem(item)
            }
        }
        modePopup.menu = menu
        let saved = smoke ? "quote-short" : UserDefaults.standard.string(forKey: modeKey) ?? "quote-all"
        selectedMode = engine.modes.first(where: { $0.id == saved }) ?? engine.modes.first(where: { $0.id == "quote-all" })
        selectModeItem()
    }

    private func selectModeItem() {
        guard let selectedMode, let item = modePopup.itemArray.first(where: { $0.representedObject as? String == selectedMode.id }) else { return }
        modePopup.select(item)
    }

    private func setView(_ next: ViewState) {
        state = next
        footerIsCurrent = false
        passageMask.isHidden = next != .practice
        status.isHidden = next != .loading && next != .error
        results.isHidden = next != .results
        headerTitle.isHidden = next != .results
        modePopup.isHidden = next == .results
        newButton.isHidden = next != .results
        progressRing.isHidden = next != .practice
        commandLabel.isHidden = next == .practice
        remainingLabel.isHidden = true
        wpmLabel.isHidden = true
        editor.isEditable = next == .practice
        modePopup.isEnabled = engine != nil
        updateCaretBlink()
    }

    private func newPractice() {
        guard let selectedMode, engine != nil else { return }
        requestID += 1
        let request = requestID
        loadTask?.cancel()
        stopTimer()
        session = nil
        setView(.loading)
        statusTitle.stringValue = "Loading quotes…"
        statusDetail.stringValue = ""
        retryButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        toastGlass.isHidden = true
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let passage = try await self.provider.randomPassage(for: selectedMode)
                guard !Task.isCancelled, request == self.requestID else { return }
                try self.startPassage(passage)
                self.loadTask = nil
            } catch {
                guard !Task.isCancelled, request == self.requestID else { return }
                self.loadTask = nil
                self.showFailure(title: "Failed to load quotes", detail: "Please check your internet connection")
                self.showToast("Failed to fetch quotes")
                FileHandle.standardError.write(Data("monkeytype-unoffical: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    func startPassage(_ passage: Passage) throws {
        guard let engine, let selectedMode else { throw resourceError("The typing engine is unavailable.") }
        stopTimer()
        session = try engine.makeSession(passage: passage, mode: selectedMode)
        spinner.stopAnimation(nil)
        setView(.practice)
        renderText()
        renderProgress()
        window?.makeFirstResponder(editor)
    }

    func restartPractice(showToast: Bool = true) {
        guard let session else { return }
        requestID += 1
        loadTask?.cancel()
        loadTask = nil
        do {
            try startPassage(session.passage)
            if showToast { self.showToast("Practice restarted") }
        } catch { showFailure(title: "Typing practice failed", detail: error.localizedDescription) }
    }

    private func showFailure(title: String, detail: String) {
        stopTimer()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        retryButton.title = resourceFailure ? "Close" : "Try Again"
        retryButton.isHidden = false
        setView(.error)
    }

    private func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 40
        paragraph.maximumLineHeight = 40
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (passageFont?.maximumAdvancement.width ?? 14.4) * 4
        return paragraph
    }

    private func renderText(acceptedInput: Bool = false) {
        guard let session, let passageFont, let renderer else { return }
        renderer.render(session: session, font: passageFont, primary: primary,
            secondary: secondary, acceptedInput: acceptedInput)
        updateCaretBlink()
    }

    private func updateCaretBlink() {
        caret.isHidden = state != .practice || !editorFocused
        caret.layer?.removeAnimation(forKey: "typing-caret")
        guard !caret.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.75, 1]
        blink.duration = 1
        blink.repeatCount = .infinity
        caret.layer?.add(blink, forKey: "typing-caret")
    }

    func textDidChange(_ notification: Notification) { commitEditor() }

    private func commitEditor() {
        guard state == .practice, renderer?.isUpdating != true, !editor.hasMarkedText(), let session else { return }
        let text = editor.string as NSString
        let position = min(editor.selectedRange().location, text.length)
        let candidate = text.substring(to: position)
        do {
            let accepted = try session.input(candidate)
            renderText(acceptedInput: accepted)
            renderProgress()
            startTimer()
            if session.done { showResults() }
        } catch { showFailure(title: "Typing practice failed", detail: error.localizedDescription) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard renderer?.isUpdating != true, !editor.hasMarkedText(), let session else { return }
        let selection = editor.selectedRange()
        let revision = session.textRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .practice, !self.editor.hasMarkedText(),
                  self.session === session, session.textRevision == revision,
                  self.editor.selectedRange() == selection else { return }
            let expected = NSRange(location: session.typedLength, length: 0)
            if self.editor.selectedRange() != expected { self.editor.setSelectedRange(expected) }
        }
    }

    private func renderProgress() {
        guard state == .practice, let session else { return }
        progressRing.progress = min(1, max(0, session.progress))
        let remainingChanged = !footerIsCurrent || displayedRemaining != session.remaining
        let wpmChanged = !footerIsCurrent || displayedWpm != session.liveWpm
        if remainingChanged {
            remainingLabel.isHidden = session.remaining == nil
            if let remaining = session.remaining {
                remainingLabel.stringValue = "\(remaining)s left"
                remainingLabel.sizeToFit()
                remainingLabel.frame.origin = NSPoint(x: 40, y: 18)
            }
        }
        if wpmChanged {
            wpmLabel.isHidden = session.liveWpm == nil
            if let wpm = session.liveWpm {
                wpmLabel.stringValue = "\(wpm == 0 ? "--" : String(wpm)) WPM"
                wpmLabel.sizeToFit()
            }
        }
        if session.liveWpm != nil, remainingChanged || wpmChanged {
            let x = session.remaining == nil ? 40 : remainingLabel.frame.maxX + 8
            wpmLabel.frame.origin = NSPoint(x: x, y: 18)
        }
        displayedRemaining = session.remaining
        displayedWpm = session.liveWpm
        footerIsCurrent = true
    }

    private func startTimer() {
        guard practiceTimer == nil, session?.hasStarted == true, session?.done == false else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        practiceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard state == .practice, let session else { return }
        do {
            try session.tick()
            renderProgress()
            if session.done { showResults() }
        } catch { showFailure(title: "Typing practice failed", detail: error.localizedDescription) }
    }

    private func stopTimer() {
        practiceTimer?.invalidate()
        practiceTimer = nil
    }

    private func showResults() {
        guard let result = session?.result else { return }
        stopTimer()
        resultWpm.stringValue = result.wpm.formatted()
        let scoreText = resultWpm.stringValue as NSString
        let maximumWidth = resultWpm.bounds.width - 4
        var scoreFont = NSFont.systemFont(ofSize: 82, weight: .bold)
        let naturalWidth = scoreText.size(withAttributes: [.font: scoreFont]).width
        var pointSize = floor(82 * min(1, maximumWidth / max(1, naturalWidth)))
        scoreFont = .systemFont(ofSize: pointSize, weight: .bold)
        while pointSize > 1 && scoreText.size(withAttributes: [.font: scoreFont]).width > maximumWidth {
            pointSize -= 1
            scoreFont = .systemFont(ofSize: pointSize, weight: .bold)
        }
        resultWpm.font = scoreFont
        resultSource.stringValue = result.source
        resultAccuracy.stringValue = "\(Int((result.accuracy * 100).rounded()))%"
        let seconds = max(0, Int(result.durationMs / 1000))
        resultTime.stringValue = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        resultCorrect.stringValue = result.correctCount.formatted()
        resultIncorrect.stringValue = result.incorrectCount.formatted()
        setView(.results)
        window?.makeFirstResponder(newButton)
    }

    private func showToast(_ message: String) {
        toastTimer?.invalidate()
        toastLabel.stringValue = message
        toastLabel.sizeToFit()
        let width = toastLabel.frame.width + 32
        toastGlass.frame = NSRect(x: (750 - width) / 2, y: 370, width: width, height: 32)
        toastLabel.frame = NSRect(x: 16, y: 7, width: width - 32, height: 18)
        toastGlass.isHidden = false
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toastGlass.isHidden = true }
        }
        toastTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func modeChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let mode = engine?.modes.first(where: { $0.id == id }) else { selectModeItem(); return }
        selectedMode = mode
        if !smoke {
            UserDefaults.standard.set(id, forKey: modeKey)
            UserDefaults.standard.set(id, forKey: mode.isTimed ? timeKey : quoteKey)
        }
        newPractice()
    }

    @objc private func familyAction(_ sender: Any?) {
        guard state != .results, let selectedMode, let engine else { return }
        let key = selectedMode.isTimed ? quoteKey : timeKey
        let fallback = selectedMode.isTimed ? "quote-all" : "time-30s"
        let remembered = smoke ? fallback : UserDefaults.standard.string(forKey: key) ?? fallback
        let mode = engine.modes.first(where: { $0.id == remembered && $0.isTimed != selectedMode.isTimed }) ??
            engine.modes.first(where: { $0.id == fallback })
        guard let mode else { return }
        self.selectedMode = mode
        selectModeItem()
        modeChanged(modePopup)
    }

    @objc private func backAction(_ sender: Any?) {
        if state == .results { restartPractice(showToast: false) }
        else { window?.close() }
    }

    @objc private func retryAction(_ sender: Any?) {
        if resourceFailure { window?.close() }
        else { newPractice() }
    }

    @objc func restartAction(_ sender: Any?) { restartPractice() }
    @objc private func newAction(_ sender: Any?) { newPractice() }

    @objc private func openAttribution(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://monkeytype.com/")!)
    }

    @objc private func actionsAction(_ sender: Any?) {
        let menu = NSMenu(title: "Practice actions")
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "monkeytype-unoffical", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let restart = menu.addItem(withTitle: "Restart Practice", action: #selector(restartAction(_:)), keyEquivalent: "r")
        restart.target = self
        restart.isEnabled = session != nil
        let new = menu.addItem(withTitle: "Start New Practice", action: #selector(newAction(_:)), keyEquivalent: state == .results ? "\r" : "n")
        new.target = self
        new.isEnabled = engine != nil
        if state != .results {
            menu.addItem(.separator())
            let family = menu.addItem(withTitle: selectedMode?.isTimed == true ? "Switch to Quote Mode" : "Switch to Time Mode",
                action: #selector(familyAction(_:)), keyEquivalent: "m")
            family.target = self
            family.isEnabled = engine != nil
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height + 8), in: actionsButton)
        if state == .practice { window?.makeFirstResponder(editor) }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { backAction(nil); return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": restartPractice()
        case "n" where state != .results: newPractice()
        case "m" where state != .results: familyAction(nil)
        case "p" where state != .results: modePopup.performClick(nil)
        case "k": actionsAction(nil)
        case "\r", "\u{3}":
            guard state == .results else { return false }
            newPractice()
        default: return false
        }
        return true
    }

    var currentScheme: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    private func observeAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshAppearance() }
        }
        colorObservation = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAppearance() }
        }
        accessibilityObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCaretBlink() }
        }
    }

    private func refreshAppearance() {
        let dark = currentScheme == "dark"
        primary = dark ? .white : .black
        secondary = primary.withAlphaComponent(0.6)
        tertiary = primary.withAlphaComponent(dark ? 0.4 : 0.42)
        separator = primary.withAlphaComponent(dark ? 0.1 : 0.12)
        footerLine.layer?.backgroundColor = separator.cgColor
        footerDivider.layer?.backgroundColor = separator.cgColor
        for label in secondaryLabels { label.textColor = secondary }
        for label in tertiaryLabels { label.textColor = tertiary }
        for label in [headerTitle, statusTitle, resultWpm, remainingLabel, toastLabel] { label.textColor = primary }
        for button in [backButton, actionsButton, newButton] { button.contentTintColor = primary }
        progressRing.foreground = secondary
        progressRing.track = separator
        caret.layer?.backgroundColor = primary.cgColor
        renderer?.invalidateColors()
        if session != nil { renderText() }
    }

    private func launchHost(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "monkeytype-unoffical", components.host == "open",
              components.user == nil, components.password == nil, components.port == nil,
              components.percentEncodedPath.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "host", let domain = items[0].value,
              HostAppearanceObserver.supportedHosts.contains(domain) || domain == smokeHarness?.hostDomain else { return nil }
        return domain
    }

    private func followHost(_ domain: String) throws {
        guard hostAppearanceObservation?.domain != domain else { return }
        let observer = HostAppearanceObserver(domain: domain) { [weak self] selection in
            guard let self else { return }
            self.hostAppearance = selection
            NSApp.appearance = selection.nativeAppearance
            self.refreshAppearance()
        }
        try observer.start()
        hostAppearanceObservation?.stop()
        hostAppearanceObservation = observer
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let domain = launchHost(from: url) else { continue }
            do {
                try followHost(domain)
            } catch {
                showToast(error.localizedDescription)
                continue
            }
            themeEventGeneration += 1
            activationGeneration += 1
            suppressNextActivation = !application.isActive
            window?.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            smokeHarness?.didReceiveURL()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        defer {
            hasActivated = true
            suppressNextActivation = false
        }
        guard hasActivated, !suppressNextActivation else { return }
        activationGeneration += 1
        let generation = activationGeneration
        // A URL event can follow activation in this same run loop; it cancels this restart.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activationGeneration == generation, self.state == .practice else { return }
            self.restartPractice(showToast: false)
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit monkeytype-unoffical", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = applicationMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    func windowWillClose(_ notification: Notification) {
        if let smokeHarness, !smokeHarness.finished {
            smokeHarness.finish(passed: false, details: ["error": "Window closed before smoke completed."], application: self)
        }
        else { NSApp.terminate(nil) }
    }

    func tearDown() {
        loadTask?.cancel()
        stopTimer()
        toastTimer?.invalidate()
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        hostAppearanceObservation?.stop()
        hostAppearanceObservation = nil
        smokeHarness?.cleanUp()
        if let colorObservation { NotificationCenter.default.removeObserver(colorObservation) }
        colorObservation = nil
        if let accessibilityObservation { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObservation) }
        accessibilityObservation = nil
    }

    func applicationWillTerminate(_ notification: Notification) { tearDown() }

}

@main
private enum TypingPractice {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PracticeApplication(smoke: CommandLine.arguments.contains("--smoke"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
