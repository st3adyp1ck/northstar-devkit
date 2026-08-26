/**
 * Normalize an RPC result that should be an array. PowerShell unrolls
 * pipelines, so a sidecar method that returns a list historically serialized
 * a 1-element list as a bare object and an empty one as null. The server
 * side now re-wraps, but every consumer of a top-level-array result goes
 * through this anyway so no wire shape can break rendering or corrupt a
 * read-modify-write save.
 */
export function asArray<T>(value: T[] | T | null | undefined): T[] {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
}
