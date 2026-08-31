/**
 * TypeScript shapes for RPC results. PowerShell's ConvertTo-Json emits
 * PascalCase property names from PSCustomObjects but plain hashtable keys
 * as authored (see core/RpcMethods.ps1 - most hand-built response objects
 * there use lowercase `[ordered]@{}` keys; passthrough PSCustomObjects
 * from WidgetCore/GuiCore keep their PascalCase). Each interface below
 * matches its source function's actual casing - verified against a live
 * `core/Invoke-DevKitRpc.ps1` round-trip where noted. When building a new
 * panel, prefer re-verifying the live shape over trusting this file blindly.
 */

// ---------- metrics.system (verified live) ----------
export interface DriveInfo {
  Name: string;
  FreeBytes: number;
  TotalBytes: number;
}

export interface SystemMetrics {
  CpuPercent: number | null;
  CpuTempC: number | null;
  MemoryPercent: number | null;
  MemoryUsedGB: number | null;
  MemoryTotalGB: number | null;
  GpuPercent: number | null;
  GpuTempC: number | null;
  GpuSource: string | null;
  DiskFreeBytes: number | null;
  DiskTotalBytes: number | null;
  Drives: DriveInfo[];
  RebootPending: boolean;
  UptimeDays: number | null;
}

// ---------- metrics.node ----------
export interface NodeProcessInfo {
  Pid: number;
  Name: string;
  MemoryMB: number;
  CpuSeconds: number;
  AgeMinutes: number | null;
  Ports: number[];
  /** Minutes since this process last burned measurable CPU. Computed by the
   *  metrics lane across polls (it caches per-pid CPU totals and timestamps),
   *  so it is null until a process has been observed at least twice. */
  IdleMinutes: number | null;
  /** Recent CPU share, derived from the delta between the last two polls. */
  CpuPercent: number | null;
  /** True when this looks safe to kill - see StaleReason for why. */
  IsStale: boolean;
  /** Human-readable justification, e.g. "idle 47m, no listening port".
   *  null when the process is NOT stale. */
  StaleReason: string | null;
  /** Best-effort command line, so two `node` rows are tellable apart. */
  CommandLine: string | null;
}

export interface OtherPortInfo {
  Port: number;
  ProcessName: string;
  Pid: number;
}

export interface NodeSnapshot {
  Processes: NodeProcessInfo[];
  OtherPorts: OtherPortInfo[];
  ReservedPorts: number[];
}

// ---------- process.topCpu / process.topMemory / metrics.gpuProcesses
// (verified live against Get-DevKitTopCpuProcesses / Get-DevKitTopMemoryProcesses /
// Get-DevKitGpuProcessUsage in core/DevKit-WidgetCore.ps1 - the original
// placeholder shape here was wrong on three counts: topCpu's percent field
// is `CpuPercent`, not `Percent`; topMemory does NOT return a bare array -
// it returns `{ Processes, TotalGB, UsedGB, FreeGB }`; and
// Get-DevKitProcessClassification only ever returns 'System' | 'Safe' |
// 'Caution' (never 'Unknown')) ----------
export type ProcessClassification = "System" | "Safe" | "Caution" | string;

export interface TopCpuProcessRow {
  Pid: number;
  Name: string;
  Classification: ProcessClassification;
  CpuPercent: number;
  MemoryMB: number;
}

export interface TopMemoryProcessRow {
  Pid: number;
  Name: string;
  Classification: ProcessClassification;
  MemoryMB: number;
}

/** Wrapper object, NOT a bare array - `Processes` is the row list. */
export interface TopMemoryResult {
  Processes: TopMemoryProcessRow[];
  TotalGB: number | null;
  UsedGB: number | null;
  FreeGB: number | null;
}

export interface GpuProcessRow {
  Pid: number;
  Name: string;
  Classification: ProcessClassification;
  GpuPercent: number;
}

export interface GpuAdapterInfo {
  Name: string | null;
  UtilPercent: number | null;
  TempC: number | null;
  MemUsedMB: number | null;
  MemTotalMB: number | null;
  Source: string;
}

/** Wrapper object, NOT a bare array - `Processes` is the row list. */
export interface GpuProcessUsage {
  Adapter: GpuAdapterInfo;
  Processes: GpuProcessRow[];
}

// ---------- process.freeMemory (verified live against
// Invoke-DevKitFreeMemory in core/DevKit-WidgetCore.ps1) ----------
export interface FreeMemoryResult {
  FreedMB: number;
  TrimmedProcesses: number;
  Note: string;
}

// ---------- catalog.get (verified live) ----------
export interface ToolPrompt {
  Name: string;
  Type: "Int" | "YesNo" | "String";
  Prompt: string;
  Optional?: boolean;
  Min?: number;
  Max?: number;
  InvalidMessage?: string;
}

export interface CatalogItem {
  key: string;
  label: string;
  script: string;
  help: string;
  caution: boolean;
  requiresProject: boolean;
  projectArgName: string | null;
  requiresFile: unknown;
  prompts: ToolPrompt[] | null;
  staticArgs: Record<string, unknown> | null;
}

export interface CatalogModule {
  group: string;
  folder: string;
  name: string;
  description: string;
  items: CatalogItem[];
}

export interface Catalog {
  modules: CatalogModule[];
}

// ---------- projects.* ----------
export interface LinkedProject {
  id: string;
  name: string;
  path: string;
  tags: string[];
  pinned: boolean;
  addedUtc: string;
  lastUsedUtc: string;
  useCount: number;
  Missing: boolean;
}

// ---------- git.overview (verified live via ConvertFrom-DevKitGitLogOutput /
// ConvertTo-DevKitGitGraphLayout / Get-DevKitRepoOverview in
// core/DevKit-WidgetCore.ps1 - the original placeholder shapes here were
// wrong: DirtyFiles is not string[], and GitCommit/GitGraphLink both carry
// more fields than first assumed) ----------
export interface GitRef {
  Name: string;
  Kind: "head" | "tag" | "branch";
}

export interface GitCommit {
  Hash: string;
  ShortHash: string;
  Parents: string[];
  Author: string;
  /** Relative, e.g. "3 weeks ago" (git log %ar) - already formatted server-side. */
  When: string;
  Refs: GitRef[];
  Subject: string;
  IsHead: boolean;
}

export interface GitDirtyFile {
  /** Raw 2-char porcelain status (e.g. " M", "??", " D"). */
  Status: string;
  Path: string;
}

export interface GitGraphNode {
  Hash: string;
  Row: number;
  Lane: number;
  Color: string;
  Commit: GitCommit;
}

export interface GitGraphLink {
  FromRow: number;
  FromLane: number;
  ToRow: number;
  ToLane: number;
  /** Same as FromColor for a straight line; the lane-join color for a merge edge. */
  Color: string;
  FromColor: string;
  ToColor: string;
  IsMerge: boolean;
}

export interface GitGraph {
  Nodes: GitGraphNode[];
  Links: GitGraphLink[];
  LaneCount: number;
}

export interface GitOverview {
  IsRepo: boolean;
  Branch: string;
  Ahead: number | null;
  Behind: number | null;
  DirtyCount: number;
  DirtyFiles: GitDirtyFile[];
  StashCount: number;
  Commits: GitCommit[];
  /** null when GraphSkipped, or when IncludeGraph was true but the repo has 0 commits. */
  Graph: GitGraph | null;
  /** true when the caller passed includeGraph:false - "not collected", distinct from "no commits". */
  GraphSkipped: boolean;
  RemoteUrl: string | null;
  Error: string | null;
}

export interface GitActionResult {
  Success: boolean;
  LastLine: string;
  Output: string;
}

// ---------- git.commitDetails (verified live via Get-DevKitCommitDetails /
// ConvertFrom-DevKitGitShow in core/DevKit-WidgetCore.ps1) ----------
export interface GitCommitFile {
  Path: string;
  Added: number;
  Deleted: number;
  IsBinary: boolean;
}

export interface GitCommitDetails {
  Found: boolean;
  Hash: string;
  Error: string | null;
  Author: string;
  Email: string;
  /** ISO 8601 strict (git %aI) - parseable directly by `new Date(...)`. */
  Date: string;
  /** Full multi-line commit message, subject included. */
  Message: string;
  Files: GitCommitFile[];
  FilesChanged: number;
  Insertions: number;
  Deletions: number;
}

// ---------- github.prs / github.issues ----------
export interface GitHubPullRequest {
  number: number;
  title: string;
  url: string;
  author?: { login: string };
  [key: string]: unknown;
}

export interface GitHubIssue {
  number: number;
  title: string;
  url: string;
  comments?: unknown[];
  [key: string]: unknown;
}

export interface GitHubListResult<T> {
  CliInstalled: boolean;
  IsRepo: boolean;
  ErrorMessage: string | null;
  Truncated: boolean;
  PullRequests?: T[];
  Issues?: T[];
}

// ---------- mcp.report ----------
export interface McpServerEntry {
  Name: string;
  Scope: string;
  Status: string;
  Target: string;
  Transport?: string;
}

export interface McpClientStatus {
  CliInstalled: boolean;
  Version: string | null;
  ErrorMessage: string | null;
  Servers: McpServerEntry[];
}

export interface McpReport {
  Claude: McpClientStatus;
  Kimi: McpClientStatus;
}

// ---------- notes.* / ondeck.* ----------
export interface ProjectNote {
  Id: string;
  Text: string;
  Color: string;
  UpdatedAt: string;
}

export type OnDeckStatus = "notStarted" | "inProgress" | "done";

export interface OnDeckItem {
  Id: string;
  Text: string;
  Status: OnDeckStatus;
  UpdatedAt: string;
}

// ---------- env.drift (verified live: Get-DevKitEnvDrift in core/DevKit-WidgetCore.ps1) ----------
export interface EnvDrift {
  Template: string;
  EnvFile: string;
  EnvExists: boolean;
  Missing: string[];
  Empty: string[];
  Extra: string[];
}

// ---------- files.children ----------
export interface DirChild {
  Name: string;
  FullName: string;
  IsDirectory: boolean;
  [key: string]: unknown;
}

export interface DirChildrenResult {
  Children: DirChild[];
  Error: string | null;
}

// ---------- settings ----------
export interface DevKitPreferences {
  confirmDestructive: boolean;
  updateCheckEnabled: boolean;
  lastUpdateCheckUtc: string | null;
  enableAnimations: boolean;
  widgetDockMode: "Left" | "Right" | "Floating";
  widgetWidth: number;
  gitFlyoutWidth: number;
  notesFlyoutWidth: number;
  controlCenterFlyoutWidth: number | null;
  envDriftSilencedProjects: string[];
  // Appearance/UX (2026 Settings panel) - defaults live in
  // tools/lib/DevKit-Common.ps1's Get-DevKitSettings; the name-level
  // backfill there means older settings.json files gain these on load.
  appTheme: string;
  accentColor: string | null;
  fontFamily: string | null;
  uiScale: number;
  terminalTheme: string;
  uiSounds: boolean;
  uiSoundVolume: number;
  /** Default width for flyout trays without their own (git/notes have theirs above). */
  flyoutWidth: number;
  /** Global shortcut that summons/dismisses the widget, in Tauri accelerator syntax. */
  globalHotkey: string;
  /** How many tool runs the run-history store retains. */
  runHistoryLimit: number;
  /** Glyph style for the flyout rail's icons. */
  iconTheme: "outline" | "solid" | "duotone";
  /** Width of the whole icon rail, logical px. */
  railWidth: number;
  /** Glyph size inside the rail, logical px - separate from railWidth so a
   *  roomier strip with the same icon is expressible. */
  railIconSize: number;
  /** Widget width persisted on close so it reopens exactly as left.
   *  null = never set; Rust falls back to its quarter-screen default. */
  widgetSavedWidth: number | null;
}

export interface DevKitSettings {
  schemaVersion: number;
  preferences: DevKitPreferences;
}

// ---------- junk ----------
export interface JunkReport {
  BytesBefore?: number;
  BytesAfter?: number;
  FreedBytes?: number;
  TotalReclaimableBytes?: number;
  [key: string]: unknown;
}

// ---------- tool.run ----------
export interface ToolRunResult {
  runId: string;
  exitCode: number;
}
