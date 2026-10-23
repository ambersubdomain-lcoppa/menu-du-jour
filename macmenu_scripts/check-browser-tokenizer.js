#!/usr/bin/env node
//
// Parity check for the word tokenizer embedded in BrowserCaseScript.swift.
//
// The change-case JS has to define "word" exactly the way MenuDuJourCore does,
// or ⇧F3 behaves differently in a browser text field than everywhere else —
// which is how REVIEW.md 2026-07-28 F4 happened: the caret expansion stopped at
// apostrophes while CaseCycle.wordCharRanges absorbs letter-flanked ones, so
// "dell'acqua" cycled to "dell'Acqua" instead of "Dell'acqua".
//
// `swift test` cannot reach this code: it is a string literal in the MacMenu
// target, run inside a browser over Apple Events. So the script extracts the
// real literal from the Swift source — never a copy, which would drift — and
// runs it against a stub <input>. The expectations mirror the Core tests in
// Tests/MenuDuJourCoreTests/CaseCycleTests.swift (testWordRangeApostropheWord,
// testWordRangeTrailingApostropheExcluded, testTransformApostropheWordIsOneWord).
//
//   node macmenu_scripts/check-browser-tokenizer.js
//
// Exits non-zero on the first mismatch. Requires node; it is a development
// check, not part of the build.

const fs = require('fs');
const path = require('path');

const source = path.join(__dirname, '..', 'Sources', 'MacMenu', 'BrowserCaseScript.swift');
const swift = fs.readFileSync(source, 'utf8');

const literal = swift.match(/private static let javascript = """\n([\s\S]*?)\n {4}"""/);
if (!literal) {
  console.error(`could not find the javascript literal in ${source}`);
  process.exit(2);
}
// In a Swift multiline literal a doubled backslash is one backslash at runtime.
const js = literal[1].replace(/\\\\/g, '\\');

// Drive the form-field branch: a stub <input> whose execCommand declines, so
// the script takes its own el.value path and we can read the result back.
function cycleInField(value, caret) {
  const el = {
    tagName: 'INPUT',
    value,
    selectionStart: caret,
    selectionEnd: caret,
    setSelectionRange(start, end) {
      this.selectionStart = start;
      this.selectionEnd = end;
    },
    dispatchEvent() {},
  };
  global.document = { activeElement: el, execCommand: () => false };
  global.Event = function Event() {};
  const status = eval(js);
  return { status, value: el.value };
}

// [ value, caret, expected value after one ⇧F3 ]
const cases = [
  // F4 itself: the caret's side of the apostrophe must not change the word.
  ["dell'acqua", 7, "Dell'acqua"],
  ["dell'acqua", 5, "Dell'acqua"],
  ["dell'acqua", 4, "Dell'acqua"],
  ["dell'acqua", 2, "Dell'acqua"],
  ["Dell'acqua", 2, "DELL'ACQUA"],
  ["don't", 1, "Don't"],
  ["l’eau", 3, "L’eau"],
  // A trailing apostrophe is NOT part of the word (Core: letter-flanked only).
  ["boys' bikes", 2, "Boys' bikes"],
  // Nor is one flanked by a digit.
  ["abc1'def", 1, "Abc1'def"],
  // Ordinary words still cycle lower -> Title -> UPPER -> lower.
  ["hello world", 2, "Hello world"],
  ["Hello world", 2, "HELLO world"],
  ["HELLO", 2, "hello"],
];

let failures = 0;
for (const [value, caret, expected] of cases) {
  const got = cycleInField(value, caret);
  const ok = got.value === expected;
  if (!ok) failures++;
  console.log(
    `${ok ? 'ok  ' : 'FAIL'}  ${JSON.stringify(value)} caret=${caret} -> ` +
    `${JSON.stringify(got.value)}${ok ? '' : `  (want ${JSON.stringify(expected)})`}`
  );
}

console.log(`\n${cases.length - failures}/${cases.length} passed`);
process.exit(failures ? 1 : 0);
