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

/** Subscribes to just one `runId`'s tool.output/started/finished events - used by the Control Center's tool runner. */
export function onToolRun(
  runId: string,
  handlers: {
    onOutput?: (stream: "stdout" | "stderr", line: string) => void;
    onFinished?: (exitCode: number) => void;
  },
): Promise<UnlistenFn> {
  return onDevKitEvent((evt) => {
    if (evt.runId !== runId) return;
    if (evt.event === "tool.output" && evt.stream && evt.line !== undefined) {
      handlers.onOutput?.(evt.stream, evt.line);
    } else if (evt.event === "tool.finished") {
      handlers.onFinished?.(Number(evt.exitCode ?? -1));
    }
  });
}
