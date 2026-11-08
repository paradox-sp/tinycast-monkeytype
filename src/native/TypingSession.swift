import Foundation
import JavaScriptCore

struct Passage: Sendable {
    let id: Int
    let text: String
    let source: String
}

struct PracticeMode: Sendable {
    let id: String
    let title: String
    let quoteType: String
    var isTimed: Bool { id.hasPrefix("time-") }
}

struct PracticeResult: Sendable {
    let source: String
    let durationMs: Double
    let wpm: Int
    let accuracy: Double
    let correctCount: Int
    let incorrectCount: Int
}

enum TypingEngineError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

@MainActor
final class TypingEngine {
    private let context: JSContext
    private let api: JSValue
    let modes: [PracticeMode]

    init(engineURL: URL) throws {
        guard let context = JSContext() else {
            throw TypingEngineError.unavailable("The typing engine could not start.")
        }
        context.evaluateScript(try String(contentsOf: engineURL, encoding: .utf8))
        if let exception = context.exception {
            throw TypingEngineError.unavailable(exception.toString() ?? "The typing engine failed to load.")
        }
        guard let api = context.objectForKeyedSubscript("TypingPractice"), !api.isUndefined,
              let identifiers = api.forProperty("modes")?.toArray() as? [String], !identifiers.isEmpty else {
            throw TypingEngineError.unavailable("The typing engine resource is invalid.")
        }
        var modes: [PracticeMode] = []
        modes.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            guard let title = api.invokeMethod("modeLabel", withArguments: [identifier])?.toString(),
                  let quoteType = api.invokeMethod("quoteType", withArguments: [identifier])?.toString() else {
                throw TypingEngineError.unavailable("The typing engine has an invalid practice mode.")
            }
            modes.append(PracticeMode(id: identifier, title: title, quoteType: quoteType))
        }
        self.context = context
        self.api = api
        self.modes = modes
    }

    func makeSession(passage: Passage, mode: PracticeMode) throws -> TypingSession {
        context.exception = nil
        guard let value = api.forProperty("Session")?.construct(withArguments: [
            ["id": passage.id, "text": passage.text, "source": passage.source], mode.id
        ]), !value.isUndefined, !value.isNull else {
            throw TypingEngineError.unavailable(context.exception?.toString() ?? "The typing session could not start.")
        }
        try checkException()
        return try TypingSession(engine: self, value: value, passage: passage)
    }

    fileprivate func prepareCall() { context.exception = nil }

    fileprivate func checkException() throws {
        if let exception = context.exception {
            throw TypingEngineError.unavailable(exception.toString() ?? "The typing engine failed.")
        }
    }
}

@MainActor
final class TypingSession {
    private let engine: TypingEngine
    private let value: JSValue
    let passage: Passage
    private(set) var typed = ""
    private(set) var typedLength = 0
    private(set) var textRevision = 0
    private(set) var dirtyRange = NSRange(location: 0, length: 0)
    private(set) var mistakes: [NSRange] = []
    private(set) var hasStarted = false
    private(set) var liveWpm: Int?
    private(set) var progress = 0.0
    private(set) var remaining: Int?
    private(set) var done = false
    private(set) var result: PracticeResult?
    private(set) var backspaceAllowed = true

    fileprivate init(engine: TypingEngine, value: JSValue, passage: Passage) throws {
        self.engine = engine
        self.value = value
        self.passage = passage
        try refresh(readState(method: "snapshot", arguments: []))
    }

    @discardableResult
    func input(_ candidate: String, now: Double = Date().timeIntervalSince1970 * 1000) throws -> Bool {
        let state = try readState(method: "inputSnapshot", arguments: [candidate, now])
        guard let accepted = state["accepted"] as? NSNumber else {
            throw TypingEngineError.unavailable("The typing engine returned invalid input acceptance.")
        }
        try refresh(state)
        return accepted.boolValue
    }

    func tick(now: Double = Date().timeIntervalSince1970 * 1000) throws {
        try refresh(readState(method: "tickSnapshot", arguments: [now]))
    }

    private func readState(method: String, arguments: [Any]) throws -> [String: Any] {
        engine.prepareCall()
        let snapshot = value.invokeMethod(method, withArguments: arguments)
        try engine.checkException()
        let dictionary = snapshot?.toDictionary()
        try engine.checkException()
        guard let state = dictionary as? [String: Any] else {
            throw TypingEngineError.unavailable("The typing engine returned invalid session state.")
        }
        return state
    }

    private func refresh(_ state: [String: Any]) throws {
        guard let started = state["hasStarted"] as? NSNumber,
              let fraction = state["progress"] as? NSNumber,
              let finished = state["done"] as? NSNumber else {
            throw TypingEngineError.unavailable("The typing engine returned invalid clock state.")
        }
        if let input = state["input"] as? [String: Any] {
            guard let text = input["typed"] as? String,
                  let length = input["typedLength"] as? NSNumber,
                  let ranges = input["mistakes"] as? [[String: NSNumber]],
                  let gate = input["backspaceAllowed"] as? NSNumber,
                  length.intValue >= 0 else {
                throw TypingEngineError.unavailable("The typing engine returned invalid input state.")
            }
            let newLength = length.intValue
            mistakes.removeAll(keepingCapacity: true)
            mistakes.reserveCapacity(ranges.count)
            for range in ranges {
                guard let start = range["start"]?.intValue, let end = range["end"]?.intValue,
                      start >= 0, end >= start, end <= newLength else {
                    throw TypingEngineError.unavailable("The typing engine returned an invalid error range.")
                }
                mistakes.append(NSRange(location: start, length: end - start))
            }
            // Compare UTF-16 units, not Swift's canonically equivalent String equality.
            var firstChanged = 0
            for (old, new) in zip(typed.utf16, text.utf16) {
                if old != new { break }
                firstChanged += 1
            }
            let changedEnd = max(typedLength, newLength)
            if firstChanged < changedEnd {
                textRevision += 1
                dirtyRange = NSRange(location: firstChanged, length: changedEnd - firstChanged)
            }
            typed = text
            typedLength = newLength
            backspaceAllowed = gate.boolValue
        }
        hasStarted = started.boolValue
        liveWpm = (state["liveWpm"] as? NSNumber)?.intValue
        progress = fraction.doubleValue
        remaining = (state["remaining"] as? NSNumber)?.intValue
        done = finished.boolValue
        if done && result == nil {
            guard let raw = state["result"] as? [String: Any],
                  raw["text"] is String,
                  let source = raw["source"] as? String,
                  let duration = raw["durationMs"] as? NSNumber,
                  let wpm = raw["wpm"] as? NSNumber,
                  let accuracy = raw["accuracy"] as? NSNumber,
                  let correct = raw["correctCount"] as? NSNumber,
                  let incorrect = raw["incorrectCount"] as? NSNumber else {
                throw TypingEngineError.unavailable("The typing engine returned invalid results.")
            }
            result = PracticeResult(source: source, durationMs: duration.doubleValue,
                wpm: wpm.intValue, accuracy: accuracy.doubleValue,
                correctCount: correct.intValue, incorrectCount: incorrect.intValue)
        }
    }
}
