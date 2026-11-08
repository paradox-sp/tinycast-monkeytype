"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  Session, modes, modeLabel, quoteType, isMode, isQuoteMode, isTimeMode, score, completedBoundary,
} = require("../src/engine/typing-session.js");

function passage(text) {
  return { id: "example", text, source: "Example source" };
}

function session(text, mode = "quote-all") {
  return new Session(passage(text), mode);
}

test("all supported modes select the matching passage category", () => {
  const expected = [
    ["quote-all", "all"],
    ["quote-short", "short"],
    ["quote-medium", "medium"],
    ["quote-long", "long"],
    ["quote-extraLong", "extraLong"],
    ["time-15s", "extraLong"],
    ["time-30s", "extraLong"],
    ["time-45s", "extraLong"],
    ["time-60s", "extraLong"],
  ];
  assert.deepEqual(modes, expected.map(([mode]) => mode));
  for (const [mode, type] of expected) {
    assert.equal(isMode(mode), true);
    assert.equal(quoteType(mode), type);
    assert.equal(isQuoteMode(mode), type !== "extraLong" || mode === "quote-extraLong");
    assert.equal(isTimeMode(mode), mode.startsWith("time-"));
  }
});

test("mode validators do not accept prefixes, coercions or unsupported durations", () => {
  for (const invalid of [
    "quote", "quote-", "quote-extraLonger", "quote-ALL", "time-15", "time-015s",
    "time-20s", "time-60s-extra", " time-30s", "all", 15, null, undefined,
    { toString: () => "quote-all" },
  ]) {
    assert.equal(isMode(invalid), false);
    assert.equal(isQuoteMode(invalid), false);
    assert.equal(isTimeMode(invalid), false);
    assert.throws(() => modeLabel(invalid), RangeError);
    assert.throws(() => quoteType(invalid), RangeError);
    assert.throws(() => new Session(passage("abc"), invalid), RangeError);
  }
});

test("scoring counts current positional errors and includes errors in gross WPM", () => {
  assert.deepEqual(score("abc def", "axz dxf", 1000, 31000), {
    text: "abc def",
    durationMs: 30000,
    wpm: 3,
    accuracy: 4 / 7,
    correctCount: 4,
    incorrectCount: 3,
  });
  assert.deepEqual(score("abc", "", 0, 1000), {
    text: "abc", durationMs: 1000, wpm: 0, accuracy: 0, correctCount: 0, incorrectCount: 0,
  });
});

test("adjacent mismatch positions form exclusive ranges and disappear after correction", () => {
  const practice = session("abcdefg hi");
  practice.input("a", 0);
  practice.input("axzqef", 100);
  assert.deepEqual(practice.mistakes, [{ start: 1, end: 4 }]);
  practice.input("axzqex", 200);
  assert.deepEqual(practice.mistakes, [{ start: 1, end: 4 }, { start: 5, end: 6 }]);
  practice.input("axz", 300);
  assert.deepEqual(practice.mistakes, [{ start: 1, end: 3 }]);
  practice.input("ab", 400);
  assert.deepEqual(practice.mistakes, []);
});

test("corrected mistypes carry no historical accuracy penalty", () => {
  const practice = session("abc def");
  practice.input("a", 1000);
  practice.input("ax", 2000);
  practice.input("a", 3000);
  practice.input("ab", 4000);
  practice.input("abc ", 5000);
  practice.input("abc def", 31000);
  assert.equal(practice.start, 3000);
  assert.deepEqual(practice.result, {
    text: "abc def", source: "Example source", durationMs: 28000,
    wpm: 3, accuracy: 1, correctCount: 7, incorrectCount: 0,
  });
});

test("the target stays fixed, ordinary errors pass, spaces gate advancement and overrun is rejected", () => {
  const practice = session("ab cd");
  const original = practice.passage;
  assert.equal(practice.input("a", 100), true);
  assert.equal(practice.input("ab", 200), true);
  assert.equal(practice.input("abx", 300), false);
  assert.equal(practice.typed, "ab");
  assert.equal(practice.input("ab ", 400), true);
  assert.equal(practice.input("ab d", 500), true);
  assert.deepEqual(practice.mistakes, [{ start: 3, end: 4 }]);
  assert.equal(practice.input("ab def", 600), false);
  assert.equal(practice.typed, "ab d");
  assert.equal(practice.done, false);
  assert.equal(practice.passage, original);
  assert.equal(practice.passage.text, "ab cd");
});

test("early spaces at non-space positions remain ordinary accepted errors", () => {
  const practice = session("abc def");
  assert.equal(practice.input(" ", 0), true);
  assert.deepEqual(practice.mistakes, [{ start: 0, end: 1 }]);
  assert.equal(practice.backspaceAllowed(), true);
  assert.equal(practice.input(" b", 100), true);
  assert.equal(practice.input(" bx", 200), true);
  assert.equal(practice.input(" bx!", 300), false);
  assert.equal(practice.typed, " bx");
});

test("completed-word boundary excludes the delimiter and does not require earlier words to be correct", () => {
  assert.equal(completedBoundary("bad good next", "xad "), 0);
  assert.equal(completedBoundary("bad good next", "xad good"), 0);
  assert.equal(completedBoundary("bad good next", "xad good "), 9);
  assert.equal(completedBoundary("a b next", "axb "), 4);
  assert.equal(completedBoundary("one two", "one"), 0);
  assert.equal(completedBoundary("one two", "one "), 4);
  assert.equal(completedBoundary("one two", "one two"), 4);
});

test("ordinary backspace locks a correctly completed word but not an incorrect word", () => {
  const practice = session("one two three");
  practice.input("o", 0);
  practice.input("one ", 100);
  assert.equal(practice.backspaceAllowed(), false);
  assert.equal(practice.progress, 4 / 13);
  practice.input("one t", 200);
  assert.equal(practice.backspaceAllowed(), true);
  practice.input("one txo ", 300);
  assert.equal(practice.backspaceAllowed(), true);
  assert.equal(practice.progress, 4 / 13);
  practice.input("one two ", 400);
  assert.equal(practice.backspaceAllowed(), false);
  assert.equal(practice.progress, 8 / 13);
});

test("a later correct word locks even when a previous word remains incorrect", () => {
  const practice = session("bad good next");
  practice.input("x", 0);
  practice.input("xad good ", 100);
  assert.equal(practice.backspaceAllowed(), false);
  assert.equal(practice.progress, 9 / 13);
  assert.deepEqual(practice.mistakes, [{ start: 0, end: 1 }]);
});

test("whole-prefix edits are not clamped by the ordinary backspace key gate", () => {
  const practice = session("one two");
  practice.input("o", 0);
  practice.input("one ", 100);
  assert.equal(practice.backspaceAllowed(), false);
  assert.equal(practice.input("on", 200), true);
  assert.equal(practice.typed, "on");
  assert.equal(practice.progress, 0);
});

test("start is assigned before a length-one rejection and resets on returning to length one", () => {
  const practice = session(" ab");
  assert.equal(practice.input("x", 1000), false);
  assert.equal(practice.typed, "");
  assert.equal(practice.start, 1000);
  assert.equal(practice.input(" ", 2000), true);
  practice.input(" a", 3000);
  practice.input(" ", 4000);
  assert.equal(practice.start, 4000);
  practice.input("", 5000);
  assert.equal(practice.start, 4000);
  practice.tick(6500);
  assert.equal(practice.elapsedSeconds, 2);
  assert.equal(practice.liveWpm, 0);
});

test("an untouched timer does not start or expire", () => {
  const practice = session("a long passage", "time-15s");
  practice.tick(999999);
  assert.equal(practice.start, null);
  assert.equal(practice.end, null);
  assert.equal(practice.liveWpm, null);
  assert.equal(practice.elapsedSeconds, 0);
  assert.equal(practice.progress, 0);
  assert.equal(practice.remaining, 15);
  assert.equal(practice.result, null);
});

test("each timed mode expires at its exact duration", () => {
  for (const [mode, seconds] of [
    ["time-15s", 15], ["time-30s", 30], ["time-45s", 45], ["time-60s", 60],
  ]) {
    const practice = session("abc def", mode);
    practice.input("a", 0);
    practice.tick(seconds * 1000 - 1);
    assert.equal(practice.done, false);
    assert.equal(practice.elapsedSeconds, seconds - 1);
    assert.equal(practice.remaining, 1);
    practice.tick(seconds * 1000);
    assert.equal(practice.done, true);
    assert.equal(practice.result.durationMs, seconds * 1000);
  }
});

test("timer floors elapsed seconds and ends at the actual delayed tick", () => {
  const practice = session("abc def ghij klmn", "time-15s");
  practice.input("a", 1000);
  practice.input("axc", 2000);
  practice.tick(15999);
  assert.equal(practice.elapsedSeconds, 14);
  assert.equal(practice.remaining, 1);
  assert.equal(practice.progress, 14 / 15);
  assert.equal(practice.done, false);
  practice.tick(16450);
  assert.equal(practice.end, 16450);
  assert.equal(practice.elapsedSeconds, 15);
  assert.equal(practice.remaining, 0);
  assert.equal(practice.progress, 1);
  assert.equal(practice.liveWpm, 2);
  assert.deepEqual(practice.result, {
    text: "abc def ghij klmn", source: "Example source", durationMs: 15450,
    wpm: 2, accuracy: 2 / 3, correctCount: 2, incorrectCount: 1,
  });
});

test("late expiry clamps progress and remaining, but retains actual result duration", () => {
  const practice = session("abc def", "time-15s");
  practice.input("a", 0);
  practice.tick(19000);
  assert.equal(practice.elapsedSeconds, 19);
  assert.equal(practice.progress, 1);
  assert.equal(practice.remaining, 0);
  assert.equal(practice.result.durationMs, 19000);
});

test("quote mode has no timer limit and progresses only at completed words", () => {
  const practice = session("one two");
  assert.equal(practice.remaining, null);
  practice.input("o", 0);
  practice.input("one", 100);
  practice.tick(200000);
  assert.equal(practice.done, false);
  assert.equal(practice.elapsedSeconds, 200);
  assert.equal(practice.progress, 0);
  practice.input("one ", 200100);
  assert.equal(practice.progress, 4 / 7);
  practice.input("one two", 201000);
  assert.equal(practice.done, true);
  assert.equal(practice.progress, 4 / 7);
  assert.equal(practice.result.durationMs, 201000);
});

test("target length completes quote and timed practice even with errors", () => {
  for (const mode of ["quote-all", "time-15s"]) {
    const practice = session("abc", mode);
    practice.input("a", 1000);
    practice.tick(2000);
    practice.input("axc", 2500);
    assert.equal(practice.done, true);
    assert.equal(practice.end, 2500);
    assert.equal(practice.elapsedSeconds, 1);
    assert.deepEqual(practice.result, {
      text: "abc", source: "Example source", durationMs: 1500,
      wpm: 24, accuracy: 2 / 3, correctCount: 2, incorrectCount: 1,
    });
    if (mode === "time-15s") {
      assert.equal(practice.remaining, 14);
      assert.equal(practice.progress, 1 / 15);
    }
  }
});

test("completion freezes input, start, end and tick-driven values", () => {
  const practice = session("abc", "time-15s");
  practice.input("a", 1000);
  practice.tick(2000);
  practice.input("abc", 3000);
  const result = practice.result;
  assert.equal(practice.input("x", 4000), false);
  practice.tick(90000);
  assert.equal(practice.typed, "abc");
  assert.equal(practice.start, 1000);
  assert.equal(practice.end, 3000);
  assert.equal(practice.elapsedSeconds, 1);
  assert.equal(practice.liveWpm, 12);
  assert.deepEqual(practice.result, result);
});

test("first accepted multi-unit insertion starts a clock without fabricating elapsed time", () => {
  const practice = session("abcd", "time-15s");
  assert.equal(practice.input("abcde", 1000), false);
  assert.equal(practice.start, null);
  assert.equal(practice.input("ab", 2000), true);
  assert.equal(practice.start, 2000);
  practice.input("abcd", 3000);
  assert.equal(practice.result.durationMs, 1000);
  assert.equal(practice.result.wpm, 48);
});

test("a full-target first insertion and single-unit target return finite zero-duration results", () => {
  for (const text of ["a", "ab", "😀"]) {
    const practice = session(text);
    practice.input(text, 1000);
    assert.equal(practice.start, 1000);
    assert.equal(practice.done, true);
    assert.equal(practice.result.durationMs, 0);
    assert.equal(practice.result.wpm, 0);
    assert.equal(practice.result.accuracy, 1);
    assert.equal(practice.result.correctCount, text.length);
  }
});

test("zero or unavailable scoring duration never leaks NaN or infinity", () => {
  for (const [start, end] of [[1, 1], [2, 1], [null, 100], [0, null], [NaN, 100], [0, Infinity]]) {
    const result = score("abc", "axc", start, end);
    assert.equal(result.durationMs, 0);
    assert.equal(result.wpm, 0);
    assert.equal(result.accuracy, 2 / 3);
  }
});

test("restarting by a new Session preserves passage and mode but clears all practice state", () => {
  const first = session("one two", "time-30s");
  first.input("o", 0);
  first.tick(1000);
  first.input("one txo", 2000);
  const restarted = new Session(first.passage, first.mode);
  assert.equal(restarted.passage, first.passage);
  assert.equal(restarted.mode, first.mode);
  assert.equal(restarted.typed, "");
  assert.equal(restarted.start, null);
  assert.equal(restarted.end, null);
  assert.equal(restarted.elapsedSeconds, 0);
  assert.equal(restarted.liveWpm, null);
  assert.equal(restarted.remaining, 30);
  assert.equal(restarted.progress, 0);
  assert.deepEqual(restarted.mistakes, []);
  assert.equal(restarted.result, null);
  restarted.input("o", 5000);
  assert.equal(restarted.start, 5000);
  assert.equal(first.start, 0);
  assert.equal(first.done, true);
});

test("positional state follows same-length replacements, deletions and changed passage text", () => {
  const quote = passage("one two more");
  const practice = new Session(quote, "quote-all");
  practice.input("one txo ", 1000);
  assert.deepEqual(practice.mistakes, [{ start: 5, end: 6 }]);
  assert.equal(practice.progress, 4 / 12);
  assert.equal(practice.backspaceAllowed(), true);

  practice.input("xne two ", 2000);
  assert.deepEqual(practice.mistakes, [{ start: 0, end: 1 }]);
  assert.equal(practice.progress, 8 / 12);
  assert.equal(practice.backspaceAllowed(), false);

  quote.text = "xne txo more";
  assert.deepEqual(practice.mistakes, [{ start: 5, end: 6 }]);
  assert.equal(practice.progress, 4 / 12);
  assert.equal(practice.backspaceAllowed(), true);

  practice.input("xne ", 3000);
  assert.deepEqual(practice.mistakes, []);
  assert.equal(practice.progress, 4 / 12);
  assert.equal(practice.backspaceAllowed(), false);
  practice.input("", 4000);
  assert.deepEqual(practice.mistakes, []);
  assert.equal(practice.progress, 0);
  assert.equal(practice.backspaceAllowed(), true);
});

test("returned mistake arrays and ranges cannot change later error state", () => {
  const practice = session("abcd next");
  practice.input("axz", 1000);
  const mistakes = practice.mistakes;
  mistakes[0].start = 0;
  mistakes[0].end = 99;
  mistakes.push({ start: 4, end: 20 });
  assert.deepEqual(practice.mistakes, [{ start: 1, end: 3 }]);
  mistakes.length = 0;
  assert.deepEqual(practice.mistakes, [{ start: 1, end: 3 }]);

  practice.input("abc", 2000);
  assert.deepEqual(practice.mistakes, []);
  assert.equal(practice.backspaceAllowed(), true);
});

test("returned results stay isolated while later passage changes remain visible", () => {
  const quote = passage("abc");
  const practice = new Session(quote, "quote-all");
  practice.input("a", 1000);
  practice.input("axc", 2000);
  Object.assign(practice.result, {
    text: "changed", source: "changed", durationMs: 0, wpm: 0,
    accuracy: 0, correctCount: 0, incorrectCount: 99,
  });
  assert.deepEqual(practice.result, {
    text: "abc", source: "Example source", durationMs: 1000,
    wpm: 36, accuracy: 2 / 3, correctCount: 2, incorrectCount: 1,
  });

  quote.text = "axc";
  quote.source = "Changed source";
  assert.deepEqual(practice.result, {
    text: "axc", source: "Changed source", durationMs: 1000,
    wpm: 36, accuracy: 1, correctCount: 3, incorrectCount: 0,
  });
});

test("emoji and canonically equivalent edits retain exact UTF-16 errors and word locks", () => {
  const practice = session("😀 e\u0301 next");
  practice.input("😁 e\u0301 ", 1000);
  assert.deepEqual(practice.mistakes, [{ start: 1, end: 2 }]);
  assert.equal(practice.progress, 6 / 10);
  assert.equal(practice.backspaceAllowed(), false);

  practice.input("😀 é ", 2000);
  assert.deepEqual(practice.mistakes, [{ start: 3, end: 5 }]);
  assert.equal(practice.progress, 3 / 10);
  assert.equal(practice.backspaceAllowed(), true);

  practice.input("😀 e\u0301 ", 3000);
  assert.deepEqual(practice.mistakes, []);
  assert.equal(practice.progress, 6 / 10);
  assert.equal(practice.backspaceAllowed(), false);
  practice.input("😀 e\u0301 next", 4000);
  assert.equal(practice.result.correctCount, 10);
  assert.equal(practice.result.incorrectCount, 0);
  assert.equal(practice.result.accuracy, 1);
});

test("bulk state updates keep rejected and unchanged length-one clock resets", () => {
  const practice = session(" ab cd", "time-15s");
  const rejected = practice.inputSnapshot("x", 1000);
  assert.equal(rejected.accepted, false);
  assert.equal(rejected.hasStarted, true);
  assert.equal(practice.tickSnapshot(2000).remaining, 14);
  assert.equal(practice.inputSnapshot(" ", 3000).accepted, true);
  assert.equal(practice.inputSnapshot(" ", 5000).accepted, true);

  const beforeExpiry = practice.tickSnapshot(19000);
  assert.equal(beforeExpiry.done, false);
  assert.equal(beforeExpiry.remaining, 1);
  assert.equal(beforeExpiry.progress, 14 / 15);
  const expired = practice.tickSnapshot(20500);
  assert.equal(expired.done, true);
  assert.deepEqual(expired.result, {
    text: " ab cd", source: "Example source", durationMs: 15500,
    wpm: 1, accuracy: 1, correctCount: 1, incorrectCount: 0,
  });
});
