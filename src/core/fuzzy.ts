// ─── Fuzzy Match ─────────────────────────────────────────────────────
//
// Ported from alayacore's internal/adapters/terminal/fuzzy.go.
// Checks if all characters in the search term appear in order
// (but not necessarily consecutively) in the target string.

/** Check if search characters appear in order within target (both lowercase). */
export function fuzzyMatch(search: string, target: string): boolean {
  if (search === "") return true;
  if (search.length > target.length) return false;

  let si = 0;
  for (let ti = 0; ti < target.length && si < search.length; ti++) {
    if (search[si] === target[ti]) {
      si++;
    }
  }
  return si === search.length;
}

/** Higher-score fuzzy match: returns score (higher = better) or 0 if no match. */
export function fuzzyScore(search: string, target: string): number {
  if (search === "") return 100;
  if (search.length > target.length) return 0;

  let si = 0;
  let score = 0;
  let consecutive = 0;

  for (let ti = 0; ti < target.length && si < search.length; ti++) {
    if (search[si] === target[ti]) {
      si++;
      consecutive++;
      // Bonus for consecutive matches and word boundaries
      if (consecutive > 1) {
        score += 10 * consecutive;
      } else {
        score += 1;
      }
      // Bonus for matches after word separators
      if (ti > 0 && (target[ti - 1] === '-' || target[ti - 1] === '_' || target[ti - 1] === '/' || target[ti - 1] === ' ')) {
        score += 5;
      }
    } else {
      consecutive = 0;
    }
  }

  return si === search.length ? score : 0;
}
