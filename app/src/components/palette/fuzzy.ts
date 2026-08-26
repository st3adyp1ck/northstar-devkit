/**
 * Tiny fuzzy matcher for the command palette. Deliberately not a library:
 * the palette ranks a few hundred short strings (tool labels, project
 * names) on every keystroke, and the ranking rules the UI promises are
 * specific enough that a generic scorer would need as much tuning as this
 * whole file.
 *
 * Ranking tiers, strongest first:
 *   1000  the whole target IS the query            ("git" -> "Git")
 *    900  the query is a prefix of the target      ("doc" -> "Docker Nuke")
 *    800  the query starts a word inside it        ("nuke" -> "Docker Nuke")
 *    700  the query appears contiguously anywhere  ("ocker" -> "Docker Nuke")
 *   ~500  the query is a subsequence               ("dkn" -> "DocKer Nuke")
 *
 * Inside a tier, earlier matches and shorter targets win, and a subsequence
 * match earns back points for every character that landed on a word start
 * and loses points for every character it had to skip - so "dkn" ranks
 * "Docker Nuke" above "Disk Cleanup Now"-style accidental hits.
 */

export interface FuzzyResult {
  score: number;
  /** Indices in the target that matched, for highlighting. */
  positions: number[];
}

/** Characters that end a word for word-start purposes. */
const WORD_BREAK = /[\s\-_./\\:>|()[\]]/;

/**
 * True when `target[i]` begins a word: start of string, preceded by a
 * separator, or a lower->upper camelCase hump. Evaluated on the
 * original-cased string, since the camelCase test needs the real casing.
 */
function isWordStart(target: string, i: number): boolean {
  if (i <= 0) return true;
  const prev = target[i - 1];
  if (WORD_BREAK.test(prev)) return true;
  const cur = target[i];
  // lower (or digit) followed by upper = a camelCase boundary
  return prev === prev.toLowerCase() && prev !== prev.toUpperCase() && cur === cur.toUpperCase() && cur !== cur.toLowerCase();
}

/** Length beyond which a target stops being penalized further, so a long help string isn't unrankable. */
const LENGTH_CAP = 80;

/**
 * Scores `query` (already trimmed by the caller) against one target
 * string. Returns null when the query isn't even a subsequence of it.
 * An empty query matches everything with score 0.
 */
export function fuzzyMatch(query: string, target: string): FuzzyResult | null {
  if (!query) return { score: 0, positions: [] };
  if (!target) return null;

  const q = query.toLowerCase();
  const t = target.toLowerCase();

  const idx = t.indexOf(q);
  if (idx !== -1) {
    const positions: number[] = [];
    for (let k = 0; k < q.length; k++) positions.push(idx + k);
    let base: number;
    if (idx === 0) base = t.length === q.length ? 1000 : 900;
    else if (isWordStart(target, idx)) base = 800;
    else base = 700;
    return {
      score: base - Math.min(idx, 40) * 0.5 - Math.min(target.length, LENGTH_CAP) * 0.15,
      positions,
    };
  }

  // Greedy left-to-right subsequence. Greedy is enough here: targets are
  // short labels, and the word-start bonus below already recovers the
  // "acronym" case that greedy alone would score flat.
  const positions: number[] = [];
  let score = 500;
  let cursor = 0;
  let prevPos = -1;
  for (let k = 0; k < q.length; k++) {
    const found = t.indexOf(q[k], cursor);
    if (found === -1) return null;
    if (prevPos !== -1) score -= Math.min(found - prevPos - 1, 12) * 2;
    if (isWordStart(target, found)) score += 14;
    positions.push(found);
    prevPos = found;
    cursor = found + 1;
  }
  score -= Math.min(target.length, LENGTH_CAP) * 0.15;
  return { score, positions };
}

/**
 * Best score for an entry whose primary label is `primary`, falling back to
 * secondary text (help copy, folder path, hand-written keywords) at a flat
 * penalty so a title hit always outranks a description hit. Highlight
 * positions are only ever reported for the primary string - highlighting a
 * description the palette doesn't render would be pointless.
 */
export function scoreCandidate(query: string, primary: string, secondaries: readonly string[] = []): FuzzyResult | null {
  const direct = fuzzyMatch(query, primary);
  let score = direct ? direct.score : Number.NEGATIVE_INFINITY;

  for (const secondary of secondaries) {
    if (!secondary) continue;
    const match = fuzzyMatch(query, secondary);
    if (match) score = Math.max(score, match.score - 260);
  }

  if (score === Number.NEGATIVE_INFINITY) return null;
  return { score, positions: direct ? direct.positions : [] };
}

export interface HighlightSegment {
  text: string;
  match: boolean;
}

/** Splits `text` into alternating plain/matched runs for rendering <mark>s. */
export function highlightSegments(text: string, positions: readonly number[]): HighlightSegment[] {
  if (positions.length === 0) return [{ text, match: false }];
  const hit = new Set(positions);
  const segments: HighlightSegment[] = [];
  let start = 0;
  let current = hit.has(0);
  for (let i = 1; i <= text.length; i++) {
    const next = i < text.length && hit.has(i);
    if (i === text.length || next !== current) {
      segments.push({ text: text.slice(start, i), match: current });
      start = i;
      current = next;
    }
  }
  return segments;
}
