/**
 * Applies a persisted rail-tab order to the set of trays this build ships.
 *
 * The saved order is a user arrangement from SOME version of the app, so
 * neither side is authoritative alone: ids the build no longer has are
 * dropped silently, and trays the saved order has never heard of (added in
 * a later build - MCP was the first) are appended in the code's own order
 * rather than vanishing. An empty or absent order is "code default", which
 * is also what makes the preference's `@()` default inert.
 *
 * Pure and generic over anything with an `id`, so the same call orders the
 * tab defs and the pane defs without either knowing about settings.
 */
export function orderTrays<T extends { id: string }>(trays: readonly T[], savedOrder: readonly string[]): T[] {
  if (savedOrder.length === 0) return [...trays];
  const byId = new Map(trays.map((t) => [t.id, t]));
  const ordered: T[] = [];
  const seen = new Set<string>();
  for (const id of savedOrder) {
    // A duplicate id in a hand-edited settings file must not duplicate a tray.
    if (seen.has(id)) continue;
    seen.add(id);
    const tray = byId.get(id);
    if (tray) ordered.push(tray);
  }
  for (const tray of trays) {
    if (!seen.has(tray.id)) ordered.push(tray);
  }
  return ordered;
}

/** The order as it should be persisted after moving `id` to `toIndex`. */
export function moveTrayId(currentOrder: readonly string[], id: string, toIndex: number): string[] {
  const without = currentOrder.filter((x) => x !== id);
  const clamped = Math.max(0, Math.min(without.length, toIndex));
  without.splice(clamped, 0, id);
  return without;
}
