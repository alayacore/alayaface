# Guidelines for AI Agents

## Before Proposing Changes

1. **Check browser console for errors.** If `init()` crashes partway, some features work while others silently fail—the app looks operational but tracking is dead. Always verify infrastructure is running before debugging logic.

2. **Confirm the baseline.** Is the relevant event listener attached? Is the function being called? Don't assume—verify with console output or user observation.

3. **Find the minimal change.** Start from the working original. Change one thing at a time. If a single variable substitution fixes it, don't rewrite the surrounding logic.

## Code Principles

4. **One source of truth.** Don't duplicate a mechanism that already exists (e.g., JS-side scroll guard when Elm already has `atBottom`). Two parallel systems drift apart and confuse future readers.

5. **Reuse checked variables.** If a DOM lookup is validated non-null at the top of a function, reuse that variable later instead of querying the DOM again. A second lookup can fail unexpectedly (element removed, race condition).
