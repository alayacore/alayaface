#!/usr/bin/env node
/*
 * Can the browser actually parse src-elm/*.css — and can it still, after the
 * next edit?
 *
 * WHY THIS EXISTS (2026-09). style.css opened with a normal block comment,
 * then nine lines of prose commented with a double slash (the line-comment
 * form every language here uses and CSS does not), and then the `:root` rule
 * holding the whole design-token block. A stylesheet has no line comments:
 * the tokenizer reads those lines as the PRELUDE of the next rule, finds no
 * valid selector when it reaches the `{`, and drops the block whole under the
 * CSS error-recovery rules. The victim was every `var(--accent)`,
 * `var(--surface-*)`, `var(--r-*)` … — 133 declarations that resolved to
 * nothing, app-wide, from the first commit. No console error, no failed
 * request, no red test: the file simply stopped saying things. The symptom the
 * user reported was one line of it — `.list-row.list-row-selected` asks for
 * `background: var(--accent); color: white` and got white text with no fill,
 * i.e. an invisible selection (white on white in light mode).
 *
 * The same file held two more of the family: blocks whose selector line a
 * "drop orphaned CSS" commit had deleted, leaving the declarations dangling
 * (`.fp-page-item-name`, `.pm-btn`). Also silent.
 *
 * WHAT IS CHECKED — the four ways a stylesheet loses rules without complaining:
 *   1. a double-slash line comment outside a comment or string: eats the next
 *      rule (the incident above);
 *   2. a block whose prelude contains a semicolon: declarations with no
 *      selector, parsed as one garbage selector and dropped;
 *   3. braces or comments that do not balance: after the fault the rest of the
 *      file is a different document than the one you think you wrote;
 *   4. `var(--x)` with no `--x` declared anywhere: the token block can die
 *      again for a reason 1–3 do not cover, and this catches the symptom too.
 *
 * NOT checked: whether a rule is semantically right, or overridden later.
 *
 * Zero dependencies and no browser on purpose: this guards the same files
 * elm-test runs on, so it belongs in the `elm` CI job, and a check needing
 * system Chrome would only ever run in the e2e job (or on one machine). The
 * rules it encodes are the tokenizer's, not an approximation of them.
 */

import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Declared outside the stylesheet: `.app` gets `--content-width` from an
// inline <style> that Elm writes (App/View.elm), and `.session-panel`
// redefines it per window. A CSS-only scan cannot see the first. If Elm ever
// stopped setting it, content would widen to the whole window — visible, not
// silent — so allowing it here costs nothing.
const EXTERNAL_TOKENS = new Set(['--content-width']);

// The tokens whose loss was the whole bug. If this file's :root block goes
// away again for a reason check 1 misses, this names it.
const CORE_TOKENS = ['--accent', '--surface-card', '--fg-default', '--r-md', '--shadow-card'];

const files = readdirSync(path.join(repo, 'src-elm'))
  .filter((f) => f.endsWith('.css'))
  .sort()
  .map((f) => path.join('src-elm', f));

let fail = 0;
const err = (file, line, msg) => {
  console.log(`✗ ${file}:${line}: ${msg}`);
  fail = 1;
};

for (const rel of files) {
  const src = readFileSync(path.join(repo, rel), 'utf8');

  const problems = [];
  let line = 1;
  let comment = false; // inside a block comment
  let commentStart = 0;
  let quote = null; // the quote that opened the current string
  let strStart = 0;
  let depth = 0;
  let stmt = ''; // text of the current statement / selector prelude
  let stmtLine = 1;
  let semiInPrelude = false; // a `;` seen since the last { or } at this depth
  let rules = 0;
  const declared = new Set();
  const used = new Map(); // var() name → first line that used it

  // Read the statement just finished. Matching happens HERE and not per
  // character: `var(--accent)` scanned one character at a time yields
  // `--a`, `--ac`, … and every name would be wrong.
  const flush = () => {
    const decl = /(--[a-zA-Z0-9_-]+)\s*:/.exec(stmt);
    if (decl) declared.add(decl[1]);
    for (const m of stmt.matchAll(/var\(\s*(--[a-zA-Z0-9_-]+)/g)) {
      if (!used.has(m[1])) used.set(m[1], stmtLine);
    }
    stmt = '';
  };

  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    const next = src[i + 1];
    if (c === '\n') line++;

    if (comment) {
      if (c === '*' && next === '/') { comment = false; i++; }
      continue;
    }
    if (quote) {
      // A string holds everything but its own quote and a newline. This is
      // what makes the double-slash check safe on the `url("data:…http://…")`
      // arrows in this file: those slashes are inside a token.
      if (c === '\\') { i++; continue; }
      if (c === quote) quote = null;
      else if (c === '\n') {
        problems.push([strStart, 'unterminated string — CSS strings do not span lines']);
        quote = null;
      }
      continue;
    }

    if (c === '/' && next === '*') { comment = true; commentStart = line; continue; }
    if (c === '/' && next === '/') {
      problems.push([line, 'double-slash line comment: not CSS. The parser reads it as the start '
        + 'of a rule and drops that rule whole — this file did it once and lost its :root '
        + 'token block. Put the prose inside a block comment instead.']);
      const eol = src.indexOf('\n', i);
      i = (eol === -1 ? src.length : eol) - 1; // report the block once
      continue;
    }
    if (c === '"' || c === "'") { quote = c; strStart = line; continue; }

    if (c === '{') {
      if (semiInPrelude) {
        problems.push([stmtLine, 'declarations with no selector: the previous block ended and '
          + 'these lines were never given one, so the parser reads them as a garbage selector '
          + 'and drops the whole block']);
      }
      flush();
      if (depth === 0) rules++;
      depth++;
      semiInPrelude = false;
      stmtLine = line;
      continue;
    }
    if (c === '}') {
      const stray = stmt.trim().length > 0;
      flush();
      if (depth === 0) {
        // A `}` with no open block. Two shapes, one cause: text at top level
        // that the parser cannot read as a selector.
        problems.push([stmtLine, semiInPrelude || stray
          ? 'declarations with no selector: the previous block ended and these lines were never '
            + 'given one, so the parser reads them as a garbage selector and drops the whole '
            + 'thing (a "drop orphaned CSS" edit that deleted the selector line, not the body)'
          : 'closing brace with nothing open — after this the rest of the file is a different '
            + 'document than the one you think you wrote']);
      } else {
        depth--;
      }
      semiInPrelude = false;
      stmtLine = line;
      continue;
    }
    if (c === ';') {
      flush();
      semiInPrelude = true;
      stmtLine = line;
      continue;
    }

    if (!stmt) stmtLine = line;
    stmt += c;
  }

  flush();
  if (comment) problems.push([commentStart, 'block comment opened here and never closed']);
  if (depth !== 0) problems.push([line, `${depth} block(s) still open at end of file`]);
  for (const [at, msg] of problems) err(rel, at, msg);

  for (const [tok, at] of used) {
    if (!declared.has(tok) && !EXTERNAL_TOKENS.has(tok)) {
      err(rel, at, `var(${tok}) is never declared — the declaration using it is dropped in `
        + 'silence (a custom property has no value unless one is written, and no fallback here)');
    }
  }

  // A check that can only go up is broken the day it stops matching: a moved
  // file, a renamed block, and everything "passes". Assert the scanner really
  // sees rules, and that the token block this file lost once is still there.
  if (rules === 0) {
    err(rel, 1, 'invariant check broken: no rules found — fix this script, do not delete it');
  }
  if (rel === 'src-elm/style.css') {
    for (const tok of CORE_TOKENS) {
      if (!declared.has(tok)) {
        err(rel, 1, `design token ${tok} is not declared — the :root token block is the single `
          + 'source of the Phase 7 palette, and it is the rule this file once lost silently');
      }
    }
    console.log(`  ${rel}: ${rules} top-level rules, ${declared.size} custom properties, `
      + `${used.size} var() names`);
  }
}

if (fail) {
  console.log('\nCSS parse check FAILED. A rule the browser cannot parse reports nothing: it is\n'
    + 'dropped and the properties inside it simply never apply. See the header of\n'
    + 'scripts/check-css-parse.mjs for the incident this guards.');
  process.exit(1);
}
console.log(`✓ CSS parses — ${files.join(', ')}: no line comments, no selector-less blocks, `
  + 'braces and comments balanced, every var(--token) declared');
