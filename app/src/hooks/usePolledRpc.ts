import { useQuery, type UseQueryResult } from "@tanstack/react-query";
import { rpcCall } from "../lib/ipc";
import { useVisibility } from "./useVisibility";

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
 */
export function usePolledRpc<T>(
  method: string,
  params: Record<string, unknown> | undefined,
  intervalMs: number,
  enabled = true,
): UseQueryResult<T> {
  const visible = useVisibility();
  return useQuery({
    queryKey: [method, params ?? null],
    queryFn: () => rpcCall<T>(method, params),
    enabled,
    refetchInterval: visible && enabled ? intervalMs : false,
    refetchIntervalInBackground: false,
    staleTime: intervalMs / 2,
  });
}
