/**
 * Typed wrapper around the single generic `rpc_call` Tauri command, which
 * forwards to the long-lived PowerShell sidecar (core/Invoke-DevKitRpc.ps1).
 * Every RPC method the sidecar knows about (see core/RpcMethods.ps1) is
 * called through here - adding a panel means adding a method there and a
 * call here, never a new Tauri command.
 */
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { recordRpcFailure } from "./errorCapture";

export class RpcClientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RpcClientError";
  }
}

/**
 * The structured half of a sidecar RPC rejection, recovered from the flat
 * string the invoke boundary hands back. The sidecar answers a failed
 * method with `{ kind, message, detail? }`; HostError::Remote is built as
 * `Remote(err.kind, err.message)` and its Display renders
 * "sidecar returned an error: {KIND} ({message})" - KIND FIRST, message in
 * the trailing parentheses (crates/devkit-host/src/host.rs). That flat
 * string is what rpc_call's Result<T, String> rejection delivers here, so
 * this parses the kind back out (e.g. toolLaneBusy) for callers to branch
 * on. The message match is greedy up to the FINAL ")" so messages
 * containing parentheses round-trip. Anything that doesn't match (local
 * failures like timeouts and disconnects) comes back with a null kind and
 * the raw text as the message.
 */
export interface RpcRejection {
  kind: string | null;
  message: string;
  /** The exact rejection string, unparsed, for logging. */
  raw: string;
}

export function parseRpcError(err: unknown): RpcRejection {
  const raw = typeof err === "string" ? err : err instanceof Error ? err.message : String(err);
  const match = raw.match(/^sidecar returned an error: ([A-Za-z][\w]*) \(([\s\S]*)\)$/);
  if (match) return { kind: match[1], message: match[2], raw };
  return { kind: null, message: raw, raw };
}

export async function rpcCall<T>(method: string, params?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>("rpc_call", { method, params: params ?? null });
  } catch (err) {
    const failure = new RpcClientError(typeof err === "string" ? err : String(err));
    // Feeds the Error Center's "app" section. Deliberately fire-and-forget
    // and non-throwing (see lib/errorCapture.ts): the caller's rejection is
    // unchanged - same RpcClientError, same timing - so every existing
    // try/catch and react-query error path behaves exactly as before.
    recordRpcFailure(method, failure);
    throw failure;
  }
}

export async function sidecarStatus(): Promise<boolean> {
  return invoke<boolean>("sidecar_status");
}

/**
 * True when the whole app (and therefore the sidecar and every tool it
 * runs) is elevated - i.e. launched through Admin Mode's scheduled task
 * (tools/system/Set-DevKitAdminMode.ps1). Fixed for the process's lifetime.
 */
export async function isElevated(): Promise<boolean> {
  const result = await rpcCall<{ elevated: boolean }>("system.isElevated");
  return !!result?.elevated;
}

export async function sidecarRestart(): Promise<void> {
  return invoke<void>("sidecar_restart");
}

export async function toggleWindow(label: string): Promise<void> {
  return invoke<void>("toggle_window", { label });
}

export async function showWindow(label: string): Promise<void> {
  return invoke<void>("show_window", { label });
}

export interface DevKitRpcEvent {
  event: string;
  runId?: string;
  stream?: "stdout" | "stderr";
  line?: string;
  data?: unknown;
  [key: string]: unknown;
}

/** Subscribes to every sidecar event (tool.started/output/finished, etc.). Call the returned fn to unsubscribe. */
export async function onDevKitEvent(handler: (evt: DevKitRpcEvent) => void): Promise<UnlistenFn> {
  return listen<DevKitRpcEvent>("devkit://event", (e) => handler(e.payload));
}

/** Subscribes to just one `runId`'s tool.started/output/finished events - used by the Control Center's tool runner. */
export function onToolRun(
  runId: string,
  handlers: {
    /** Fires when the sidecar confirms the child process exists (carries its pid). Never fires for a refused run. */
    onStarted?: (pid: number) => void;
    onOutput?: (stream: "stdout" | "stderr", line: string) => void;
    /** `cancelled` is the sidecar's own flag (tool.finished flattens `{exitCode, cancelled}`) - true when the run ended via tool.stop. */
    onFinished?: (exitCode: number, cancelled: boolean) => void;
  },
): Promise<UnlistenFn> {
  return onDevKitEvent((evt) => {
    if (evt.runId !== runId) return;
    if (evt.event === "tool.started") {
      handlers.onStarted?.(Number(evt.pid ?? 0));
    } else if (evt.event === "tool.output" && evt.stream && evt.line !== undefined) {
      handlers.onOutput?.(evt.stream, evt.line);
    } else if (evt.event === "tool.finished") {
      handlers.onFinished?.(Number(evt.exitCode ?? -1), evt.cancelled === true);
    }
  });
}
