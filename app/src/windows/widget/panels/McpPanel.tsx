import { useEffect, useState } from "react";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { asArray } from "../../../lib/arrays";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { Expander } from "../../../components/primitives/Expander";
import { ServerIcon } from "./icons";
import type { McpReport, McpClientStatus, McpServerEntry } from "../../../lib/types";
import "./McpPanel.css";

/**
 * Backed by mcp.report - polled ONLY while one of the two client boxes is
 * expanded, and then at 60s. This is not a freshness knob: each report runs
 * `claude mcp list`, and that command health-checks by CONNECTING, which
 * spawns every configured stdio MCP server as a real process. On a project
 * with a dozen servers, the old always-on 20s cadence meant a fleet of
 * node/docker processes being churned three times a minute for as long as
 * the widget existed - the single largest contributor to "the widget is
 * eating my machine at idle" (measured: ~1 GB of transient process tree
 * hanging off the sidecar). Collapsed boxes show the last-known report, or
 * "not checked" before the first one; expanding is what asks.
 *
 * Status vocabulary is read from the actual parsers, not guessed:
 *   - Claude (ConvertFrom-DevKitClaudeMcpLine): Connected | Disconnected |
 *     RequiresAuth | Unknown
 *   - Kimi (ConvertFrom-DevKitKimiMcpConfig): Configured | Disabled |
 *     RequiresAuth (Kimi's health is config-only - the CLI's live
 *     connection state is TUI-only - so "Configured" is its healthy badge,
 *     equivalent to Claude's "Connected")
 */
const STATUS_TONE: Record<string, "success" | "danger" | "warning" | "neutral"> = {
  Connected: "success",
  Configured: "success",
  Disconnected: "danger",
  RequiresAuth: "warning",
  Disabled: "neutral",
  Unknown: "neutral",
};

function statusTone(status: string): "success" | "danger" | "warning" | "neutral" {
  return STATUS_TONE[status] ?? "neutral";
}

const CLIENTS: { key: keyof McpReport; label: string }[] = [
  { key: "Claude", label: "Claude Code" },
  { key: "Kimi", label: "Kimi Code" },
];

export function McpPanel() {
  const active = useProjectStore((s) => s.active);
  // How many of the client boxes are currently expanded. The poll below is
  // enabled only while this is non-zero - see the panel doc block for why
  // an idle check is genuinely expensive here.
  const [openBoxes, setOpenBoxes] = useState(0);
  const anyOpen = openBoxes > 0;
  const { data, pending, failed, stale, errorMessage } = usePolledRpc<McpReport>(
    "mcp.report",
    { projectPath: active?.path ?? "" },
    60000,
    anyOpen,
  );

  // The failed branch below UNMOUNTS the Expanders, so ones that were open
  // never fire onOpenChange(false) - without this reset the counter stays
  // >=1 forever and the poll this gating exists to stop quietly comes back.
  // When the sidecar recovers, the boxes remount closed, which matches 0.
  useEffect(() => {
    if (failed) setOpenBoxes(0);
  }, [failed]);

  return (
    <GlassPanel>
      <div className="panel-header">
        <span className="panel-header__icon">
          <ServerIcon />
        </span>
        <h2 className="panel-header__title">MCP Servers</h2>
        {pending && <span className="panel-header__hint">checking…</span>}
        {/* Only while a box is open: with the poll parked, "not answering"
            would freeze on screen long after the sidecar recovered. */}
        {stale && anyOpen && <span className="panel-header__hint mcp-panel__stale">last known — sidecar not answering</span>}
      </div>
      {/* A dead sidecar used to render as two innocent "not installed"
          badges: with no report, `data?.[key]` is undefined for BOTH
          clients and every downstream check reads that as "absent". That
          is the machine-with-no-MCP-tooling story, not the truth. */}
      {failed ? (
        <div className="panel-empty panel-empty--danger" role="alert">
          Couldn&apos;t check MCP clients{errorMessage ? ` - ${errorMessage}` : "."}
        </div>
      ) : (
        <div className="mcp-panel__list">
          {CLIENTS.map(({ key, label }) => {
            const status = data?.[key];
            return (
              <Expander
                key={key}
                title={label}
                actionSlot={<ClientBadge status={status} checking={anyOpen} />}
                onOpenChange={(open) => setOpenBoxes((n) => Math.max(0, n + (open ? 1 : -1)))}
              >
                <div className="mcp-panel__body">
                  <ClientBody status={status} />
                </div>
              </Expander>
            );
          })}
        </div>
      )}
    </GlassPanel>
  );
}

function ClientBadge({ status, checking }: { status: McpClientStatus | undefined; checking: boolean }) {
  // Undefined means no report has landed - and since the poll only runs
  // while a box is open, that is an honest resting state, not a stall.
  // "checking…" is only claimed while a check could actually be running;
  // it must not borrow the "not installed" badge a real report earns.
  if (!status) return <Badge tone="neutral">{checking ? "checking…" : "not checked"}</Badge>;
  if (!status.CliInstalled) return <Badge tone="neutral">not installed</Badge>;
  return <Badge tone="accent">{status.Version ?? "installed"}</Badge>;
}

function ClientBody({ status }: { status: McpClientStatus | undefined }) {
  if (!status) {
    return <div className="panel-empty">Checking…</div>;
  }
  if (!status.CliInstalled) {
    return <div className="panel-empty">CLI not installed.</div>;
  }
  if (status.ErrorMessage) {
    return <div className="panel-empty panel-empty--danger">{status.ErrorMessage}</div>;
  }
  // Wire-shape guard: a client with exactly one configured server can
  // arrive as a bare object rather than a 1-element list (lib/arrays.ts).
  const servers = asArray(status.Servers);
  if (servers.length === 0) {
    return <div className="panel-empty">No MCP servers configured</div>;
  }
  return (
    <div className="mcp-panel__servers">
      {servers.map((s) => (
        <ServerRow key={`${s.Scope}:${s.Name}`} server={s} />
      ))}
    </div>
  );
}

function ServerRow({ server }: { server: McpServerEntry }) {
  return (
    <div className="mcp-panel__row">
      <div className="mcp-panel__row-name-col">
        <span className="mcp-panel__row-name">{server.Name}</span>
        <span className="mcp-panel__row-meta">
          {server.Scope}
          {server.Transport ? ` · ${server.Transport}` : ""}
        </span>
      </div>
      <Badge tone={statusTone(server.Status)}>{server.Status}</Badge>
    </div>
  );
}
