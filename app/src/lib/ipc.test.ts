import { describe, expect, it } from "vitest";
import { parseRpcError } from "./ipc";

/**
 * parseRpcError recovers { kind, message } from the flat string the invoke
 * boundary rejects with. The format is HostError::Remote's Display,
 * constructed as Remote(kind, message):
 *   "sidecar returned an error: {KIND} ({message})"  (kind FIRST)
 * See crates/devkit-host/src/host.rs. These cases pin that wire format -
 * a kind/message inversion here silently breaks every kind-based branch
 * (e.g. the tool-lane-busy UX) downstream.
 */
describe("parseRpcError", () => {
  it("parses a real sidecar refusal frame to kind + exact message", () => {
    const rejection = parseRpcError(
      "sidecar returned an error: toolLaneBusy (Another DevKit tool is already running. Wait for it to finish or stop it first.)",
    );
    expect(rejection.kind).toBe("toolLaneBusy");
    expect(rejection.message).toBe("Another DevKit tool is already running. Wait for it to finish or stop it first.");
    expect(rejection.raw).toBe(
      "sidecar returned an error: toolLaneBusy (Another DevKit tool is already running. Wait for it to finish or stop it first.)",
    );
  });

  it("returns a null kind for transport-level failures", () => {
    const rejection = parseRpcError("sidecar process is not running");
    expect(rejection.kind).toBeNull();
    expect(rejection.message).toBe("sidecar process is not running");
    expect(rejection.raw).toBe("sidecar process is not running");
  });

  it("round-trips a message that itself contains parentheses", () => {
    const rejection = parseRpcError("sidecar returned an error: ToolFailed (boom (mid-dle) done.)");
    expect(rejection.kind).toBe("ToolFailed");
    expect(rejection.message).toBe("boom (mid-dle) done.");
  });

  it("unwraps Error objects to their message before parsing", () => {
    const rejection = parseRpcError(new Error("sidecar returned an error: BadParams (missing folder)"));
    expect(rejection.kind).toBe("BadParams");
    expect(rejection.message).toBe("missing folder");
  });

  it("does not misfire on kind-last text", () => {
    // The pre-fix regex expected message-first/kind-last and would have
    // parsed this as kind "toolLaneBusy" + message "Other text"; kind-first
    // means the leading token must be the kind.
    const rejection = parseRpcError("sidecar returned an error: toolLaneBusy (real message) (other)");
    expect(rejection.kind).toBe("toolLaneBusy");
    expect(rejection.message).toBe("real message) (other");
  });
});
