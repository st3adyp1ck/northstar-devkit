import { useQuery, type UseQueryResult } from "@tanstack/react-query";
import { rpcCall } from "../lib/ipc";
import { useVisibility } from "./useVisibility";

/**
 * Derived, panel-friendly view of a polled query's health.
 *
 * react-query's own flags are correct but easy to misread, and every panel
 * got it wrong the same way: they guarded on `isLoading && !data` and
 * rendered an empty/"n/a" state otherwise. In v5, once the initial fetch
 * fails (main.tsx sets retry: 1) `status` flips to "error", so `isLoading`
 * is false AND `data` is undefined - the "still loading" guard goes false
 * and the panel confidently renders "nothing here". With the sidecar down
 * that read as a healthy idle machine: four "n/a" gauges, "0 running", MCP
 * "not installed". The UI was lying.
 *
 * These four booleans make the honest states impossible to miss:
 *  - `pending`  - first load in flight, nothing to show YET  ("loading…")
 *  - `failed`   - last attempt failed and nothing ever loaded ("can't reach it")
 *  - `stale`    - data on screen, but the latest refresh failed (last known values)
 *  - `errorMessage` - what to actually tell the user
 *
 * Polling keeps running through an error (refetchInterval is unaffected by
 * query status), so every panel self-heals the moment the sidecar returns.
 */
export interface PolledRpcStatus {
  /** First load still in flight with nothing rendered yet. Replaces the old `isLoading && !data` idiom. */
  pending: boolean;
  /** The most recent attempt failed AND no data has ever arrived - the panel has nothing true to show. */
  failed: boolean;
  /** Data is on screen but the latest refresh failed - what's rendered is last-known, not live. */
  stale: boolean;
  /** Human-readable text for the most recent failure; null while the last attempt succeeded. */
  errorMessage: string | null;
}

export type PolledRpcResult<T> = UseQueryResult<T> & PolledRpcStatus;

function describeRpcError(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "string" && error) return error;
  return "The DevKit sidecar did not respond.";
}

/**
 * Polls one RPC method on an interval, but only while the window is
 * visible (see useVisibility) - the metrics/node/git/mcp lanes on the
 * PowerShell side stay cheap, but there is no reason to even ask when
 * nobody's looking.
 *
 * `enabled` (default true) is the other half of that: pass `false` - most
 * callers compute it as `!!active` - when there's nothing to ask about yet
 * (no project selected). This is deliberately a separate flag rather than
 * inferred from `params === undefined`: several panels (Gauges, Node/Ports)
 * legitimately poll methods that take no params at all, and treating their
 * `undefined` as "disabled" would silently stop them polling forever.
 *
 * Returns the full UseQueryResult (unchanged for existing callers) plus the
 * PolledRpcStatus flags above - see that type for why panels should read
 * `failed`/`stale` rather than inferring health from `data` alone.
 */
export function usePolledRpc<T>(
  method: string,
  params: Record<string, unknown> | undefined,
  intervalMs: number,
  enabled = true,
): PolledRpcResult<T> {
  const visible = useVisibility();
  const query = useQuery({
    queryKey: [method, params ?? null],
    queryFn: () => rpcCall<T>(method, params),
    enabled,
    refetchInterval: visible && enabled ? intervalMs : false,
    refetchIntervalInBackground: false,
    staleTime: intervalMs / 2,
  });

  const hasData = query.data !== undefined;
  return {
    ...query,
    // `isLoading` (not `isPending`) on purpose: a disabled query sits in
    // status "pending" forever, and calling that "loading" would leave
    // project-scoped panels spinning with no project selected.
    pending: query.isLoading && !hasData,
    failed: query.isError && !hasData,
    stale: query.isError && hasData,
    errorMessage: query.isError ? describeRpcError(query.error) : null,
  };
}
