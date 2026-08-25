import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { Expander } from "../../../components/primitives/Expander";
import { ServerIcon } from "./icons";
import type { McpReport, McpClientStatus, McpServerEntry } from "../../../lib/types";
import "./McpPanel.css";

/**
 * Backed by mcp.report, polled every 20s - claude.exe/kimi.exe health
 * checks take real seconds (see Get-DevKitMcpWidgetReport's docstring in
 * gui/DevKit-WidgetCore.ps1), so this must stay infrequent.
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
  const { data, isLoading } = usePolledRpc<McpReport>(
    "mcp.report",
    { projectPath: active?.path ?? "" },
    20000,
  );

  return (
    <GlassPanel>
      <div className="panel-header">
        <span className="panel-header__icon">
          <ServerIcon />
        </span>
        <h2 className="panel-header__title">MCP Servers</h2>
        {isLoading && !data && <span className="panel-header__hint">checking…</span>}
      </div>
      <div className="mcp-panel__list">
        {CLIENTS.map(({ key, label }) => {
          const status = data?.[key];
          return (
            <Expander
              key={key}
              title={label}
              actionSlot={
                status?.CliInstalled ? (
                  <Badge tone="accent">{status.Version ?? "installed"}</Badge>
                ) : (
                  <Badge tone="neutral">not installed</Badge>
                )
              }
            >
              <div className="mcp-panel__body">
                <ClientBody status={status} />
              </div>
            </Expander>
          );
        })}
      </div>
    </GlassPanel>
  );
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
  if (status.Servers.length === 0) {
    return <div className="panel-empty">No MCP servers configured</div>;
  }
  return (
    <div className="mcp-panel__servers">
      {status.Servers.map((s) => (
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
