(function (root) {
  "use strict";

  const quoteModes = Object.freeze([
    "quote-all", "quote-short", "quote-medium", "quote-long", "quote-extraLong",
  ]);
  const timeModes = Object.freeze(["time-15s", "time-30s", "time-45s", "time-60s"]);
  const modes = Object.freeze([...quoteModes, ...timeModes]);
  const labels = Object.freeze([
    "All Quotes", "Short Quotes", "Medium Quotes", "Long Quotes", "Extra Long Quotes",
    "15 Seconds", "30 Seconds", "45 Seconds", "60 Seconds",
  ]);

  function isQuoteMode(mode) {
    return quoteModes.includes(mode);
  }

  function isTimeMode(mode) {
    return timeModes.includes(mode);
  }

  function isMode(mode) {
    return modes.includes(mode);
  }

  function assertMode(mode) {
    if (!isMode(mode)) throw new RangeError(`Unknown typing practice mode: ${mode}`);
  }

  function modeLabel(mode) {
    assertMode(mode);
    return labels[modes.indexOf(mode)];
  }

  function quoteType(mode) {
    assertMode(mode);
    return isQuoteMode(mode) ? mode.slice(6) : "extraLong";
  }

  function deriveInput(target, typed) {
    const mistakes = [];
    let incorrectCount = 0;
    let boundary = 0;
    let correctWord = true;
    for (let index = 0; index < typed.length; index += 1) {
      const matches = target[index] === typed[index];
      if (!matches) {
        incorrectCount += 1;
        const previous = mistakes[mistakes.length - 1];
        if (previous && previous.end === index) previous.end += 1;
        else mistakes.push({ start: index, end: index + 1 });
      }
      if (target[index] === " ") {
        if (correctWord) boundary = index + 1;
        correctWord = true;
      } else if (!matches) {
        correctWord = false;
      }
    }
    return {
      target, typed, mistakes, incorrectCount, boundary,
      backspaceAllowed: !(typed.endsWith(" ") && typed.length <= boundary),
    };
  }

  function completedBoundary(target, typed) {
    let boundary = 0;
    let correctWord = true;
    for (let index = 0; index < Math.min(target.length, typed.length); index += 1) {
      if (target[index] === " ") {
        // The delimiter itself is deliberately excluded from the word check.
        if (correctWord) boundary = index + 1;
        correctWord = true;
      } else if (target[index] !== typed[index]) {
        correctWord = false;
      }
    }
    return boundary;
  }

  function duration(start, end) {
    // A missing clock or same-timestamp completion must not produce infinite WPM.
    if (!Number.isFinite(start) || !Number.isFinite(end)) return 0;
    const elapsed = end - start;
    return Number.isFinite(elapsed) ? Math.max(0, elapsed) : 0;
  }

  function wordsPerMinute(length, durationMs) {
    return durationMs > 0 ? Math.round(length / (durationMs / 60000) / 5) : 0;
  }

  function score(target, typed, start, end) {
    let incorrectCount = 0;
    for (let index = 0; index < typed.length; index += 1) {
      if (target[index] !== typed[index]) incorrectCount += 1;
    }
    return scoreWithErrors(target, typed.length, incorrectCount, start, end);
  }

  function scoreWithErrors(target, typedLength, incorrectCount, start, end) {
    const correctCount = typedLength - incorrectCount;
    const durationMs = duration(start, end);
    return {
      text: target,
      durationMs,
      wpm: wordsPerMinute(typedLength, durationMs),
      accuracy: typedLength ? correctCount / typedLength : 0,
      correctCount,
      incorrectCount,
    };
  }

  class Session {
    #cachedInput = null;

    #inputState() {
      const target = this.passage.text;
      if (!this.#cachedInput ||
          this.#cachedInput.target !== target || this.#cachedInput.typed !== this.typed) {
        this.#cachedInput = deriveInput(target, this.typed);
      }
      return this.#cachedInput;
    }

    constructor(passage, mode) {
      assertMode(mode);
      this.passage = passage;
      this.mode = mode;
      this.typed = "";
      this.start = null;
      this.end = null;
      this.elapsedSeconds = 0;
      this.liveWpm = null;
      this.durationSeconds = isTimeMode(mode) ? Number(mode.slice(5, -1)) : null;
    }

    input(candidate, now = Date.now()) {
      if (this.done) return false;
      // Reset the clock on every length-one candidate, before acceptance checks.
      if (candidate.length === 1) this.start = now;
      const target = this.passage.text;
      if (candidate.length > target.length) return false;
      const last = candidate.length - 1;
      if (target[last] === " " && candidate[last] !== " ") return false;

      // IME/batched first insertion can skip length one. Start only after acceptance.
      if (this.start === null && candidate.length > 0) this.start = now;
      this.typed = candidate;
      if (candidate.length === target.length && this.start !== null) this.end = now;
      return true;
    }

    tick(now = Date.now()) {
      if (this.done || this.start === null) return;
      const durationMs = duration(this.start, now);
      this.elapsedSeconds = Math.floor(durationMs / 1000);
      this.liveWpm = wordsPerMinute(this.typed.length, durationMs);
      if (this.durationSeconds !== null && this.elapsedSeconds >= this.durationSeconds) {
        this.end = now;
      }
    }

    backspaceAllowed() {
      return this.#inputState().backspaceAllowed;
    }

    get done() {
      return this.end !== null;
    }

    get mistakes() {
      return this.#inputState().mistakes.map(({ start, end }) => ({ start, end }));
    }

    get progress() {
      if (this.durationSeconds !== null) {
        return Math.min(1, this.elapsedSeconds / this.durationSeconds);
      }
      return this.passage.text.length
        ? this.#inputState().boundary / this.passage.text.length
        : 0;
    }

    get remaining() {
      return this.durationSeconds === null ? null : Math.max(0, this.durationSeconds - this.elapsedSeconds);
    }

    get result() {
      if (!this.done) return null;
      const state = this.#inputState();
      return {
        ...scoreWithErrors(state.target, state.typed.length, state.incorrectCount, this.start, this.end),
        source: this.passage.source,
      };
    }

    // Native callers transfer a single plain object, including text only after an edit.
    snapshot(includeInput = true, accepted = null) {
      return {
        accepted,
        hasStarted: this.start !== null,
        liveWpm: this.liveWpm,
        progress: this.progress,
        remaining: this.remaining,
        done: this.done,
        result: this.result,
        input: includeInput ? {
          typed: this.typed,
          typedLength: this.typed.length,
          mistakes: this.mistakes,
          backspaceAllowed: this.backspaceAllowed(),
        } : null,
      };
    }

    inputSnapshot(candidate, now = Date.now()) {
      const previous = this.typed;
      const accepted = this.input(candidate, now);
      return this.snapshot(this.typed !== previous, accepted);
    }

    tickSnapshot(now = Date.now()) {
      this.tick(now);
      return this.snapshot(false);
    }
  }

  const api = Object.freeze({
    Session, modes, modeLabel, quoteType, isMode, isQuoteMode, isTimeMode, score, completedBoundary,
  });
  root.TypingPractice = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
