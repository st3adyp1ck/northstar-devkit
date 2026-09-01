# Changelog

All notable changes to Northstar DevKit are documented here.

## [4.3.0] - 2026-08-31

### Added

- **MCP Servers is a tray now.** The panel moved out of the docked
  sidebar's column into its own slide-out tray, with a server-stack glyph
  on the rail beside Git / Terminal / Files / Notes. Floating keeps it
  inline (there is no rail to hold a tray when the widget floats), and the
  panel's spawn-on-expand polling now also parks itself whenever its tray
  is shut, like every other tray panel.
- **The rail's tabs are drag-arrangeable.** Grab any tray tab and drag it
  to a new slot - the other tabs step aside as you go - or press
  Alt+Up/Down on a focused tab (focus follows the moved tab, so repeated
  presses walk it up or down the rail). The arrangement persists as
  `preferences.flyoutTabOrder` and survives trays being added or removed
  across versions: unknown ids are dropped, new trays append in default
  order. The DEVKIT plate stays seated at the foot of the rail - it is
  chassis, not a tab.

### Fixed

- **The idle widget no longer eats the machine.** Measured on the installed
  4.2.0 build sitting untouched: the process tree burned **81% of a CPU
  core**, most of it the WebView2 GPU process compositing at 60fps. Three
  causes, all fixed:
  - **The hidden Control Center window thought it was visible.** Chromium
    disables occlusion tracking for transparent windows, so the never-shown
    window reported `document.visibilityState === "visible"`, defeating
    every visibility-gated poll - and its 800ms loading spinner spun at
    60fps into a window nobody had ever seen (43% of a core in the GPU
    process plus 25% in that window's renderer, measured). `useVisibility`
    now also asks the OS (`getCurrentWindow().isVisible()`) at mount, and a
    new `WindowEffectsGate` stamps `data-devkit-window-hidden` on any
    hidden window, under which global.css pauses every animation and
    transition. Pausing animations alone took the tree from 81% to 15% in
    a controlled A/B on the installed build.
  - **The MCP panel spawned your entire MCP server fleet three times a
    minute.** `mcp.report` polled every 20s, each report runs
    `claude mcp list` twice (neutral + project scope), and that command
    health-checks by CONNECTING - spawning every configured stdio server
    as a real process (~1 GB of transient process tree measured hanging
    off the sidecar). The report now runs only while one of the panel's
    boxes is actually expanded, at 60s; collapsed boxes show the last
    known state or "not checked".
  - **`claude mcp list` had no deadline.** One wedged server hung the
    check forever and stranded the whole spawned fleet as orphans.
    `Invoke-DevKitMcpList` now runs it as a child process with a 25s
    timeout (two sequential runs must fit the RPC's 60s budget) and kills
    the process TREE (`taskkill /T`) on expiry. Resolution goes through
    `Get-DevKitWindowsExecutable`, and a `claude.ps1` npm shim runs via the
    current PowerShell host - a bare `Get-Command` would have handed
    `CreateProcess` a script it cannot launch on npm-installed CLIs.
- **Minimize now counts as hidden.** The titlebar's Minimize button went
  through neither the tray-hide event nor `document.hidden` (occlusion
  tracking is off for transparent windows), so a minimized window kept
  every poll and animation at full idle cost. The Rust side now emits the
  visibility event on minimize/restore transitions, for both windows.
- **The gauges stopped re-rendering at 40 commits/second.** The arc eased
  through a rAF `setState` loop, and real CPU/mem/GPU readings jitter on
  nearly every 2s poll - so three gauges kept React committing ~40 times a
  second at idle, each frame re-rasterizing a drop-shadow over the panel's
  backdrop blur. The arc is now a CSS `stroke-dashoffset` transition (one
  commit per poll, reduced-motion contract inherited from
  `--duration-gauge`), and moves under one percentage point snap without
  animating at all.
- **Decorative glows stopped costing paint.** The healthy sidecar dot
  animated `box-shadow` - a paint-per-frame property - 60fps for the life
  of every window; the peak halo now sits on a pseudo-element whose
  opacity breathes instead. The widget rail's breathe ran even while the
  rail was held at `opacity: 0` in the expanded layout; it is now scoped
  to the collapsed sliver, the only state where the rail is visible.
- **Mounted no longer means polling.** Node & Ports kept its 3s
  process/TCP enumeration running forever once the section had been opened
  a single time (`lazyMount` keeps panels mounted on purpose); its
  Expander's new `onOpenChange` now gates the poll. Notes/On-Deck (10s)
  and Files (15s) polled inside a SHUT flyout tray; both now read the same
  pane-visibility signal GitPanel already used.
- **The embedded terminal no longer boots into PSReadLine's yellow
  "ListView temporarily disabled" wall.** The ConPTY spawned at a nominal
  80x24 and was resized to the tray's real ~42 columns mid-profile-load;
  PSReadLine's ListView prediction needs 50 columns and re-warned on every
  prompt render. `terminal_spawn` now opens the pty at the size xterm
  actually measured, and the injected first command downgrades the
  prediction view to `InlineView` when the pane is narrower than 54
  columns - your profile and real terminals keep ListView untouched. (The
  pause before the prompt is your own PowerShell profile loading -
  measured 1.3s vs 0.2s without - and is unchanged: the embedded terminal
  deliberately loads your real profile.)

### Changed

- **Releases publish themselves** (`.github/workflows/release.yml`,
  `releaseDraft: false`). A `vX.Y.Z` tag now builds, signs and PUBLISHES in
  one go instead of leaving a draft for someone to click. The updater's
  endpoint only ever resolves to published releases, so a draft reaches no
  machine at all - and "tag, then remember to publish" is a step that gets
  skipped exactly once. The trade-off is stated where it matters: a bad
  build ships the moment it is tagged, and deleting the release
  un-advertises it without rolling anyone back, so tag from a green `main`.
- **Docs corrected to match CI.** `AGENTS.md` described
  `.github/workflows/ci.yml` as PowerShell-only in two places; it has in
  fact run four parallel jobs (version triple, PowerShell, Rust workspace,
  frontend) for some time, and now runs vitest as well.

## [4.2.0] - 2026-08-30

The commit graph learns about pull requests, the Control Center moves in
beside the widget as a slide-out tray, and the embedded terminal stops
booting into a blank pane.

### Added

- **Open-PR pills and hover ribbons in the commit graph**: every open PR
  renders as a `#42` pill (drafts dashed) on the head commit it actually
  points at - PR identity lives IN the chart, never in a separate legend
  band above it. Click a pill for the PR's details; hover to light up that
  PR's own commits as a ribbon. Matching is hash-exact via `gh`'s
  `headRefOid`, with a branch-name fallback (`git/prLanes.ts`).
- **Throttled background auto-fetch** (`Invoke-DevKitGitAutoFetch` in
  `core/DevKit-WidgetCore.ps1`): the repo overview freshens remote refs
  itself - at most one prompt-free attempt per minute per repo - so
  bot-pushed branches like Dependabot's reach the log without anyone
  pressing Fetch. The due-check is split out as a pure
  `Test-DevKitGitAutoFetchDue` so it is unit-testable apart from its side
  effects.
- **Adaptive commit-log window**: `git.overview` now accepts `extraTips`
  (the frontend's open-PR head SHAs) and `Get-DevKitRepoOverview` grows
  the log from 40 up to 400 commits until every tip fits, so a busy trunk
  can no longer push open PRs out of the chart.
- **The Control Center as a slide-out tray in the docked widget**: the
  same component mounts as `<ControlCenterApp embedded />` in the widget's
  flyout pane stack, with the rail's DEVKIT brand plate as its tab.
  Embedded mode drops the TitleBar (a pane has no window chrome), the
  ProjectPicker (the widget's own picker shares the store), and the
  `PALETTE_TOOL_EVENT` listener (the standalone window stays the command
  palette's single tool-run target - two mounted instances consuming one
  event would open the same dialog twice). The tray fills the rest of the
  screen on open and persists a resize drag as `controlCenterFlyoutWidth`
  (`null` = fill).
- **Scheduled-task admin mode** (`tools/system/Set-DevKitAdminMode.ps1`)
  and a **deep close-out variant**. Enabling it moves Start-with-Windows off
  the Run key and onto the task's logon trigger (Windows will not auto-start
  an elevated app from the Run key), so the tray's own **Start with Windows**
  item reads that state from Admin Mode's marker: while Admin Mode is on it
  shows ticked and greyed, `(managed by Admin Mode)`. Ticking it there would
  otherwise have added a second, non-elevated autostart racing the elevated
  one. `-Off` restores the Run key and hands the item back.
- **`/dance`** - a hidden command-palette entry that makes the gauges
  bounce, matched as a whole word rather than through the fuzzy scorer so
  it can never be stumbled onto by a loose match.
- **Tooltips on the destructive Quick Actions and Node/Ports buttons**,
  spelling out what each one actually ends before you press it.
- **Vitest now runs in CI** (`.github/workflows/ci.yml`). The frontend job
  gated only `tsc --noEmit` and `vite build`, so every frontend assertion
  (fuzzy matching, git lane/label colours, PR lane assignment, the
  markdown-lite renderer) could break without turning a single check red.

### Changed

- **Node & Ports is collapsed by default**, like the embedded terminal -
  `lazyMount`, so its polls cost nothing until it is first opened.
- **The commit graph is a single renderer again**: `GitGraph.tsx` and
  `git/CommitGraph.tsx` are gone, leaving `git/PrGraph.tsx` as the one
  drawing path. `CommitGraph.css` stays - it still carries the commit-row,
  node and lane styles PrGraph draws with.

### Fixed

- **The embedded terminal no longer boots blank inside the flyout tray.**
  The tray keeps its panes mounted while hidden, so `TerminalView` mounted
  against a 0x0 host; opening xterm and spawning the session there left a
  blank pane with a dead cursor that only a manual kill+restart (a remount
  while visible) ever recovered from. Startup is now deferred until the
  host has real dimensions, and every `fit()` goes through one guarded
  path - a zero-size host computes 0 cols, and fitting a terminal whose
  renderer has not initialized throws xterm's "Cannot read properties of
  undefined (reading 'dimensions')", the TypeError this logged on every
  tray open.
- **`[devkit-rpc] child stdin detached` is treated as benign sidecar
  chatter** rather than a fault: the deliberate stdin detach behind the
  25s spawn-stall fix reports success at every single startup.

## [4.1.0] - 2026-08-26

### Added

- **GitHub Actions release pipeline** (`.github/workflows/release.yml`):
  pushing a `vX.Y.Z` tag builds the Tauri app on `windows-latest`,
  minisign-signs the updater artifacts, and publishes a draft GitHub
  Release with the NSIS installer, its `.sig`, and `latest.json` (the
  in-app updater's endpoint) - a human still reviews and publishes the
  draft. To cut a release: `git tag vX.Y.Z && git push origin vX.Y.Z`.
- **Error center, flyout trays and the command palette**, plus a
  JARVIS-style slide-out tray for the docked widget.
- **Settings panel** with 10 themes, compass-rose branding and UI sounds,
  alongside a general widget UX round-out.

### Fixed

- The **sidecar spawn stall**, and every broken wire found by the
  cross-boundary audit.
- **Real sidebar docking** - full-height, immovable and resize-locked -
  with width-resizable docking and zoom-compensated window heights.
- Widget width, so all four gauges fit, with a wrap fallback.
- The installed app itself: verbatim paths, a lane-init race, the silent
  console and real logging.

### Removed

- The **legacy WPF app**, retired now that the Tauri v2 rebuild is proven.

## [4.0.0] - 2026-08-04

The widget becomes the app: DevKit is now a properly installed Windows
application whose main face is the companion widget, with the full toolkit
GUI (DevKit Control Center) one click away - plus a repo-wide restructure
and a performance pass that makes a tray-hidden widget cost essentially
nothing. USB/ portable builds remain supported via
`dev/Build-UsbPortable.ps1`.

### Added

- **Real installer** (`Install.ps1` / `Install.bat`): a stepped wizard -
  a welcome/permissions screen explaining the fully per-user install (no
  admin needed; the tools that require elevation self-elevate at runtime),
  an install location defaulting to
  `%LOCALAPPDATA%\Programs\NorthstarDevKit`, and options for
  Start-with-Windows (default on), shortcuts, PATH, and the two opt-in
  integrations (Explorer shell entry, Windows Terminal profile). Registers
  DevKit in Windows Settings > Apps (HKCU Uninstall key); the main Start
  Menu/Desktop "Northstar DevKit" icon opens the widget directly,
  alongside "Northstar DevKit Control Center" and "Northstar DevKit
  (Terminal)" shortcuts. Automation flags: `-Silent`, `-Destination`,
  `-NoStartWithWindows`, `-SkipPath`, `-SkipShortcuts`,
  `-NoDesktopShortcut`, `-AddShellIntegration`, `-AddTerminalProfile`.
- **Real uninstaller** (`Uninstall.ps1`): removes the running widget, the
  Explorer/Terminal integrations, the Run-key entry, the PATH entry, all
  shortcuts, the Apps & Features entry, and the install directory -
  guarded by a `.northstar-installed` marker file so a source checkout can
  never be deleted by accident - and offers to keep or remove the app data
  (`%LOCALAPPDATA%\NorthstarDevKit`) when asked. Flags: `-Silent`,
  `-KeepUserData`.
- **New root `Widget.bat`** launches the companion widget windowlessly
  (via `gui/Start-Widget-Startup.vbs`) - the widget is now the main face
  of the app. It gained a title-bar **DEVKIT** button that opens the full
  toolkit GUI (DevKit Control Center); the Quick Actions button was
  relabeled "Open DevKit Control Center", and the tray menu item likewise.
  `DevKit.bat` (terminal menu) and `DevKit-GUI.bat` (Control Center)
  remain as secondary surfaces.
- **Clickable CPU/MEM/GPU gauges with management dialogs** (widget): each
  gauge opens a themed dialog that refreshes every 3s while open (never
  in the tray, timers created/stopped with the dialog). CPU lists the top
  processes by usage; MEM lists top consumers with a one-click **Free
  Memory** action (psapi `EmptyWorkingSet` across non-system processes,
  reporting freed MB); GPU shows the adapter summary (nvidia-smi
  name/util/temp/VRAM when present) plus per-process GPU usage parsed from
  the `\GPU Engine(*)` counters. Every row carries a SAFE TO CLOSE /
  CAUTION / LEAVE ALONE badge (system-critical processes have no kill
  button, and `Stop-DevKitProcessById` refuses them server-side too).
  New Pester-covered pure logic in `gui/DevKit-WidgetCore.ps1`:
  `Get-DevKitProcessClassification`, `Get-DevKitTopCpuProcesses`,
  `Get-DevKitTopMemoryProcesses`, `Get-DevKitGpuProcessUsage` (+
  `ConvertFrom-DevKitGpuEngineInstance`), `Stop-DevKitProcessById`,
  `Invoke-DevKitFreeMemory`.
- **Junk cleanup is now 100% GUI-side** (widget): the old "Cleanup
  Tool..." button (which dumped the user into a terminal to type CLEAN)
  is gone. "Clean Now" runs the whole clean in the widget behind one
  styled Yes/No - user temp + Recycle Bin always, Windows\Temp and the
  Windows Update download cache when elevated - and reports a per-category
  freed breakdown, with an ember hint naming any admin-only areas it had
  to skip. A new "Details..." dialog shows the per-category scan
  breakdown. No cleanup path opens a terminal or asks for typed input.
- **Hosted real terminal panel** (widget): the TERMINAL side tab slides out
  a REAL terminal hosted in the panel - Windows Terminal (`wt.exe -w new`,
  with the registered "Northstar DevKit" fragment profile when present,
  else the default profile; pwsh/powershell conhost fallback), chrome-
  stripped and owned by the widget, with a sync loop gluing it to the
  panel's live rect through slides/dock flips/resizes. It starts in the
  active project's folder, so interactive CLIs (kimi, claude) genuinely
  work - it IS a normal terminal. Its topmost state mirrors the widget's
  pin (a non-topmost owned window sinks below a topmost owner - the
  reported "terminal invisible while pinned" bug). The session closes with
  the panel (WT processes are killed only after re-verifying ownership, so
  the user's own WT windows are never touched), restarts on project
  switch, survives widget hide, and is independent of the flyout carousel
  (stays open next to GIT/FILES/NOTES/ON DECK, always outermost).
- **Gauge management windows are slide-out panels now** (widget): the
  CPU/MEM/GPU dialogs became carousel flyout panels (same slide machinery
  as the other tabs) instead of floating popup windows.
- **Click-to-expand commit details** (widget GIT flyout): every commit row
  on the graph toggles an inline details card under it - full hash, author
  + date, the FULL multi-line message, and per-file `+/-` stats - fetched
  lazily via a new `CommitDetails` work-runspace job and parsed by the
  Pester-covered `ConvertFrom-DevKitGitShow`. Selection survives graph
  refreshes and resets on project switch. Also fixes the earlier
  misunderstanding: UNCOMMITTED CHANGES and COMMIT GRAPH are expanded by
  default again (applied in code, not markup - the theme's Expander
  template only reveals content via the Expanded event's storyboard).
- **Built-in icon set** (widget): `gui/DevKit-WidgetIcons.ps1` ships 40+
  Material-style vector glyphs (per-language file pages, folder
  open/closed, image/archive/sql/config/env/docker/git/lock/bat/exe
  specials, git-branch/tag/head), built once and frozen
  (`Get-DevKitIconDrawing`) so tree rows and pills reuse shared geometry.
  The pure name -> icon/color mapping (`Get-DevKitFileIconInfo`) lives in
  WidgetCore with Pester coverage; the Files flyout and the git graph's
  ref pills use it.
- **Section-anchored side tabs + divider** (widget): FILES+GIT sit across
  from the CPU/MEM/GPU card, NOTES+ON DECK across from the junk/drives
  card, TERMINAL across from QUICK ACTIONS - positions computed from the
  un-scrolled layout (scroll never moves the tabs), clamped to never
  overlap or leave the strip, flipping sides with the dock. A 2px
  sapphire-to-ember vertical divider now separates the tab strip from the
  widget body.
- **Node-process table resize/expand affordances** (`gui/DevKit-Widget.ps1`):
  the header's column splitters (previously invisible until hover) now show
  an always-visible 2px grip bar between the column titles that brightens
  sapphire on hover, so the drag-to-resize affordance is discoverable; and
  the "+N more" overflow line is now clickable - it expands the list to all
  processes in place and toggles to "Show less", re-rendering immediately
  from the last collected snapshot instead of waiting for the next metrics
  cycle.
- **Files flyout in the companion widget** (`gui/DevKit-Widget.ps1`,
  `gui/DevKit-Widget.xaml`, `gui/Theme.xaml`, `gui/DevKit-WidgetCore.ps1`):
  a new FILES side tab (beside GIT/NOTES) slides out a mini VS Code-style
  explorer of the active project's root folder. The dark TreeView
  lazy-loads one directory level per expansion (folders first, then files,
  case-insensitive alpha; enumeration errors degrade to a greyed "access
  denied" node), restores expanded folders across Refresh, and offers a
  toolbar (New File / New Folder / Refresh / Collapse All) plus per-item
  right-click menus (Open, Open in Explorer, Open in Editor, Copy/Cut/
  Paste, Rename..., Delete, New File/Folder Here, Copy Full/Relative Path)
  and a project-level background menu. Cut/Copy/Paste are an internal
  clipboard with Explorer-style " - Copy" collision renaming and a dimmed
  cut marker (Esc cancels); every mutating op re-validates containment in
  the project root, names are validated in-dialog, and Delete goes to the
  Recycle Bin behind the styled Yes/No confirm - failures land in the
  flyout's status line, never a crash. The panel reuses the Git/Notes
  flyout machinery (slide animation, dock-side flips, grip resize) with
  its own persisted width (`preferences.filesFlyoutWidth`). New pure
  helpers in the Pester-covered widget core: `Get-DevKitDirChildren`,
  `Test-DevKitPathWithinRoot`, `Get-DevKitSafeChildName`,
  `Get-DevKitCopyName`, `Get-DevKitRelativePath`.
- **On-Deck flyout in the companion widget** (`gui/DevKit-Widget.ps1`,
  `gui/DevKit-Widget.xaml`, `gui/Theme.xaml`, `gui/DevKit-WidgetCore.ps1`):
  a fourth ON DECK side tab (violet-accented `OnDeckTabButtonWest/East`)
  slides out a per-project to-do list persisted to
  `%LOCALAPPDATA%\NorthstarDevKit\ondeck.json` - same canonical project
  keying and forgiving corrupt/missing-file posture as the notes store,
  saved on every mutation. An add-row (Add button or Enter) lands items at
  the top of NOT STARTED; three fixed sections (NOT STARTED / IN PROGRESS /
  DONE) show live counts and a subtle "No items" hint when empty. Each row
  has a status cycle button and a right-click status menu (FilesContextMenu
  styling, current status disabled); the stored list is always
  section-grouped, so a status change moves the item to its new section
  immediately. Done rows render dimmed with strikethrough, the DONE header
  has a "Clear Done" button, and delete is a deliberate single click on the
  row's small x. The panel reuses the flyout machinery wholesale (slide
  animation, dock-side flips, grip resize as Kind 'OnDeck', width persisted
  as `preferences.onDeckFlyoutWidth`, greyed out with no active project,
  reloads on project switch). New Pester-covered core helpers:
  `Get/Save-DevKitProjectOnDeck`, `Add-DevKitOnDeckItem`,
  `Remove-DevKitOnDeckItem`, `Set-DevKitOnDeckItemStatus`,
  `Clear-DevKitOnDeckDone`, `Group-DevKitOnDeckItems`.
- **Collapsible note cards in the widget's Notes flyout**: notes now render
  as compact title cards by default - single line with ellipsis, the title
  derived from the body's first line (`Get-DevKitNoteTitle`). Clicking a
  card expands the full editor (existing debounced autosave + two-step
  delete, now with a Done button); saving or clicking/focusing away
  collapses it back and flushes pending edits. The notes.json schema is
  unchanged (no title field on disk), so existing notes load untouched and
  older widget builds read the same file.
- **Collapsible sections in the widget's Git flyout**: the Commits tab's
  commit graph is now a collapsed-by-default expander with a live
  commit-count badge (matching the Uncommitted Changes expander; the whole
  tab scrolls, the graph scrolls horizontally), and each open pull request
  renders as a collapsed-by-default accordion exactly like the issue
  accordions - header with #number/title + draft/review badges, body with
  the author/branches/updated meta line and an Open-on-GitHub button.
- **Files flyout rescans on every open**: reopening the widget's Files
  panel for the same project now re-enumerates the tree from disk (the
  Refresh button's exact rebuild path, with expanded folders restored)
  instead of keeping the tree cached from before the panel was closed.

### Changed

- **Repo restructure**: all twelve tool-category folders (agents,
  diagnostics, docker, git, maintenance, nextjs, node, ports, system,
  vite, wifi, workflow) and `lib/` moved under a new `tools/` folder, and
  maintainer-only tooling (`Build-UsbPortable.ps1`/`.bat`, `RELEASING.md`)
  moved to a new `dev/` folder. Leaf scripts and .bat wrappers are
  unchanged (they resolve `lib` relative to their own folder); direct
  script invocations are now `.\tools\ports\Kill-Port.ps1`-style. The repo
  root now holds only the launchers, the installer/uninstaller, docs,
  `VERSION`, and the `gui/`, `tools/`, `tests/`, `dev/` folders.
- **Widget performance pass ("lightweight")** (`gui/DevKit-Widget.ps1`,
  `gui/DevKit-WidgetCore.ps1`):
  - Hovering the gauges card no longer spikes CPU/GPU: the ToolCard hover
    lift/scale storyboard was removed (hover is now an instant brush
    swap), the gauge-arc DropShadowEffects were removed, the 30fps gauge
    easing timer was deleted (arcs now snap to a frozen cached 0-100%
    geometry table, never allocating geometry per frame), and the root
    window shadow blur was reduced.
  - The background runspaces now dot-source the shared libraries once at
    creation instead of re-parsing ~150KB of script every ~4s cycle -
    which also stops the sensor caches being wiped every cycle: nvidia-smi
    was spawning every 4s instead of every 10s, the ~1s thermal-counter
    stall ran every cycle instead of every 45s, and the winnat port-range
    netsh call ran every cycle instead of every 30 minutes.
  - The node-process table only rebuilds when the process set or a
    bucketed value changes (memory in 25MB buckets, age in 5-minute
    buckets) instead of nearly every cycle; the junk scan cadence went
    from 5 to 30 minutes.
  - All refresh timers now stop when the widget is hidden to the tray and
    resume (with an immediate refresh) when shown - a hidden widget costs
    ~nothing.
- Version bumped to 4.0.0 (`VERSION`, README badge, menu banner).

### Fixed

- **desktop.ini folder icon** now points at the bundled
  `gui/Assets/logo.ico` instead of a dead hardcoded path.
- **Widget "Start with Windows" failing at logon** (`gui/Start-Widget-Startup.vbs`):
  the old retry loop waited on the launched process (`sh.Run cmd, 0, True`),
  so a powershell.exe stuck behind the loader-error 0xC0000142 dialog kept
  the launcher blocked until the retry window was always considered expired
  and the widget never started. The launcher now launches non-blocking and
  confirms success via a pid-file handshake - the widget writes
  `%LOCALAPPDATA%\NorthstarDevKit\widget.pid` once its window is up;
  the .vbs polls for it (30s), terminates only the widget processes its own
  attempt started on timeout, backs off 30s, and retries (max 3 attempts).
- **Stale "Start with Windows" Run entry after moving/reinstalling DevKit**:
  the registered command bakes in the .vbs absolute path and nothing
  re-registered it, so logon popped "Can not find script file" forever. The
  widget now self-heals the value at startup (rewrites it when it differs
  from the expected command or its .vbs target is gone, via a shared
  `Get-DevKitStartupCommand` helper), Install.ps1 repairs it after the copy
  step, and registration failures now surface as a tray balloon tip instead
  of being swallowed by `catch { }`.
- **Cross-elevation single-instance trap on pwsh 7** (`gui/DevKit-Widget.ps1`):
  the Authenticated-Users ACL on the instance mutex/summon event was only
  applied on Windows PowerShell 5.1; under pwsh 7 the kernel objects got
  default ACLs, which - combined with an already-running elevated tray
  instance - made normal launches silently no-op, so only "Run as
  administrator" appeared to work. The ACL now applies on both editions
  (`System.Threading.AccessControl` is Add-Type'd on Core first, with
  fallback to default-ACL creation). The widget still needs no admin rights.
- **Invisible widget startup deaths**: `Get-DevKitSettingsFile` /
  `Get-DevKitProjectsFile` (`lib/DevKit-Common.ps1`) created the
  `%LOCALAPPDATA%\NorthstarDevKit` directory unguarded, and one throwing
  startup initializer (e.g. `Update-DevKitWidgetProjects`) terminated the
  whole headless widget through the trap with no visible sign. Directory
  creation is now best-effort, each startup step is individually guarded
  (failures log to `widget-startup.log` and startup continues), and the
  trap itself now shows a MessageBox with the error and log path after
  writing the log.
- **SmartScreen blocking manually-copied installs** (Install.ps1): the
  installed tree is now `Unblock-File`'d after copying, dropping any
  Mark-of-the-Web zone tag from the .bat wrappers.

### Removed

- **`Setup-Path.bat`** - superseded by the installer, which manages PATH
  (reversibly) alongside shortcuts and startup; the old portable-installer
  behavior is replaced by `Install.ps1`.

## [3.8.0] - 2026-08-02

The companion widget becomes the main surface: a hand-drawn commit graph,
ambient project awareness, and eight new toolkit utilities - plus a full-repo
bug sweep that fixed two long-standing HIGH-severity bugs.

### Added

- **A real commit graph in the widget's Git flyout**, replacing the
  monospace `git log --graph` dump. `Get-DevKitRepoOverview` now parses
  `git log --all --topo-order -n 40` with record/unit separators,
  `ConvertTo-DevKitGitGraphLayout` assigns lanes (the first-parent trunk
  stays a straight vertical line; side branches and merges bend into it),
  and `Render-DevKitGitGraph` draws it on a Canvas: gradient S-curve links
  that flow from each branch's color into its parent's, bright lane nodes
  with a HEAD ring, branch/tag pills, subject + hash/author/date lines,
  tooltips, and a measured canvas width so horizontal scrolling appears
  exactly when needed. Branch header now shows ahead/behind vs upstream.
- **Disk Free dial** next to System Junk (`System.IO.DriveInfo` - arc shows
  used space, the number shows free space, ember under 10% free).
- **Node table upgrades**: an AGE column (5m/3h/2d), a confirmed per-process
  kill button (stop the stale dev server, not all of node), click-to-open
  `http://localhost:<port>` links, row tooltips, a friendlier empty state,
  and an ember warning when common dev ports sit inside Hyper-V/winnat
  reserved ranges (the "nothing is listening yet the port refuses to bind"
  case - parsed from `netsh show excludedportrange` via the new
  `ConvertFrom-DevKitExcludedPortRanges` in `lib/DevKit-Common.ps1`, cached
  30 minutes).
- **Ambient project awareness** under the widget's project selector: a git
  badge with branch + uncommitted/ahead/behind/stash counts (refreshed every
  2 minutes in the background), and an ember `.env` drift hint when the
  project's `.env` is missing keys its template declares or leaves them
  empty (key-name diff only - values are secrets and never read), with a
  "Fix..." button that opens the real Copy-EnvTemplate tool.
- **Reboot-pending / long-uptime hint** in the gauges card (documented
  registry sentinels + LastBootUpTime), because a pending reboot explains a
  whole class of phantom dev-machine weirdness.
- **Four project launchers** in the widget's quick actions: Editor (VS
  Code/Cursor), Explorer, Terminal (wt.exe or fallback), and Run Script...
  (the new package.json script picker) - all enabled only with a project.
- **Widget polish**: themed thin scrollbars everywhere (see Changed), a
  sapphire-to-ember brand strip under the title bar, an ACTIVE PROJECT
  label, a close button inside the Git flyout, an indeterminate progress
  bar during the first MCP check, a green "Freed X" result, Enter submits
  the Kill Port dialog, grip tooltips + hover fade on the invisible resize
  grips, dock-aware grip resizing (a docked widget keeps its screen edge),
  and a calmer HH:mm footer clock.
- **GUI polish**: Run buttons on CAUTION-tagged (destructive) cards are now
  ember DangerButtons; cards hover-highlight; dialogs get Enter-to-submit /
  Escape-to-cancel, first-field focus, a close [x], and drag-by-title;
  prompt dialogs show the tool's help excerpt (ember for safety notes) and
  highlight the offending field on validation failure; search shows its
  Ctrl+F hint, clears with Escape, restores the previous page when emptied,
  and has a real no-results state; the pinned-project glyph renders in the
  correct icon font (was a tofu box); first launch opens Getting Started;
  launching a tool flashes "Launched ✓" on its button; nav items carry
  their module's description as a tooltip; the projects page keeps its
  scroll position across actions; the window resizes from any edge or
  corner (was a single near-invisible grip).
- **Theme system**: semantic success/warning tokens and badge styles
  (`BrushSuccess*`, `BrushWarning*`, `BrushInfoSurface`, `BrushEmberSurface`,
  `BrushGitTag`, `BadgeSuccess`, `BadgeWarning`), a shared keyboard
  `DevKitFocusVisual` wired into buttons/nav/combo boxes, disabled-state
  triggers on every button style, wrapping max-width tooltips, brand text
  selection colors, an indeterminate ProgressBar state, a readable gauge
  track ring, and deduplicated one-off color literals into named tokens.
- **TUI polish**: the gradient engine's palette re-anchored to the logo's
  sapphire/ember duality (was an old cyan ramp), the spinner matches and
  shows elapsed seconds past 2s, the startup banner centers itself for any
  version-string length, and static section chrome moved from Magenta to
  White on both the menu header and search results.
- **`ports/Show-ExcludedPortRanges.ps1`** - lists Hyper-V/winnat-reserved
  TCP port ranges and flags common dev ports caught inside them; `-Port`
  checks one port (exit 0 free / 1 reserved). The answer to "EACCES /
  WinError 10013 with nothing listening".
- **`ports/Test-DevEndpoint.ps1`** - HTTP health check: status code,
  latency, redirect target, and TLS certificate days-remaining for https
  URLs; with no `-Url` it probes every common dev port that's actually
  listening.
- **`git/Get-GitStandup.ps1`** - your commits across repos since N hours
  ago (default 24), grouped per repo for standup notes; author resolved
  from git config; never fetches, never mutates.
- **`node/Start-PackageScript.ps1`** - arrow-key picker over a project's
  package.json scripts, run with the auto-detected package manager
  (`-Name` skips the picker).
- **`node/Find-StaleNodeModules.ps1`** - finds every node_modules under a
  root, reports size + age, and offers a gated cleanup (report-only by
  default; deletion behind `Confirm-DevKitDestructiveAction` via the
  long-path-safe shared helper).
- **`system/Edit-HostsFile.ps1`** - view/add/remove/comment-toggle hosts
  entries with a timestamped backup, admin gate with elevation offer, and
  a DNS flush after each change - the "myapp.test" workflow without
  googling where the file lives.
- **`workflow/Compare-EnvFiles.ps1`** - `.env` vs template drift report
  (missing / empty / extra keys; values never printed).
- **`workflow/Convert-DevText.ps1`** - the "google-this" converter box:
  Base64 and URL encode/decode, Unix timestamps (s/ms) to local time and
  back, GUIDs, SHA-256, and JWT header/payload decoding (signature never
  verified, and it says so). Optional `-Clipboard`.

### Changed

- **Both WPF apps now load the theme into `Application.Resources` before
  parsing any window XAML** (the Application is created first), replacing
  the old `Theme.xaml` string-merge into `Window.Resources`. Keyless
  styles (ScrollBar, ToolTip, CheckBox) only reach template-generated
  elements - every ScrollViewer's scrollbars, ComboBox popups - through
  application resources, so scrollbars were stock light Windows chrome
  and dialog windows lost implicit styles. One structural change fixes both.
- **Maintenance report tools now offer to apply right after the report.**
  The six report-then-flag tools - `Clear-DiskJunk.ps1`,
  `Manage-StartupPrograms.ps1`, `Get-ScheduledTasksReport.ps1`,
  `Manage-Services.ps1`, `Set-PowerPlan.ps1`, and `Set-VisualEffects.ps1` -
  previously ended their default report with a "re-run with `-Apply` /
  `-Disable <Name>` / ..." hint, a dead end for anyone launching via a
  batch wrapper or the interactive menu (no way to add flags). An
  interactive run now ends with an optional prompt to act immediately
  (clean up now, entry/task name to toggle, service + startup type, plan
  number or name, new visual-effects mode). The prompt only collects input
  and sets the same variables the flags would have set, then falls into the
  existing code path unchanged - same admin checks, same
  `Confirm-DevKitDestructiveAction` gate. All flags keep working, and
  piped/automated runs keep the old report-then-exit behavior via a
  `[Console]::IsInputRedirected` guard.
- **Package-manager detection recognizes modern bun**: bun >= 1.2's text
  `bun.lock` is probed alongside the legacy binary `bun.lockb`, and the
  nuke/full-clean lock-file delete lists include it.
- The Agents menu's "List MCP Servers" entry now actually passes
  `-UseActiveProject`, so the user/global vs project/local scope split its
  help always promised is reachable from the menu.
- The MCP add-from-catalog scope picker has a Cancel entry (Escape used to
  loop forever).
- Settings and the linked-projects registry merge with the on-disk document
  before writing, so the long-running widget and a menu session no longer
  silently discard each other's concurrent updates.
- **Final-sweep performance pass.** The widget's metrics runspace now
  caches its two slowest sensor reads per runspace - the ACPI
  thermal-zone CPU temperature for 45s and the nvidia-smi GPU reading
  for 10s - instead of re-running both on every 2-second cycle; GUI
  startup compiles its three inline C# native helpers (taskbar AUMID,
  WM_SETICON, edge-resize) in a single Add-Type invocation instead of
  three separate compiler runs; the GUI search box debounces typing by
  ~150ms, rendering one results page for a quickly typed query instead
  of one per keystroke; `Find-StaleNodeModules` sizes each node_modules
  with robocopy in list-only mode (roughly 5x faster than summing
  `Get-ChildItem -Recurse`, and long-path-safe); and Test-DevEndpoint's
  no-URL scan probes each listening port with a 2s timeout (was 3s).

### Fixed

- **The Agents "Manage..." dialogs never attached their content**
  (`$root.Child` / `$dlg.Content` were never set) - clicking Manage opened
  an invisible empty modal window that froze the widget until dismissed
  with Escape. Found by rendering the real dialog in an off-screen probe.
- **Every MCP menu tool crashed on second use within one DevKit session**
  ("The term 'Get-DevKitMcpCatalog' is not recognized"): the three MCP
  libs used `$global:` load-guards that outlived the menu dispatcher's
  child scope while their functions did not. Guards now use function
  detection, matching `lib/DevKit-Common.ps1`'s documented pattern.
- **`Env-Restore` no longer destroys live secrets**: `Env-Backup` redacts
  secret-like values to `***REDACTED***` by default, and restoring such a
  backup used to write that literal over the real secrets. Redacted values
  are now skipped (with a count + reminder to re-enter them).
- **GUI argument rendering treated Int 1 as a switch and dropped Int 0**,
  so e.g. `-Port 1` launched as a bare `-Port` and failed immediately.
  Type-first branching fixes it, with new Pester coverage.
- **The widget's metrics runspace could freeze the UI permanently** on a
  wedged native call (nvidia-smi/WMI): it now gets the same
  BeginStop-and-fresh-runspace recovery as the MCP and work runspaces.
- **Switching projects while a git overview was in flight left the previous
  project's graph on screen permanently**; declined refreshes now re-fire
  when the work slot frees, and stale results for a since-switched project
  are discarded instead of rendered.
- Git actions (fetch/pull/push) color the status line ember on failure
  (was friendly dim for errors too) and disable the repo buttons while
  running; the junk gauge reads "of 10 GB" and its rescan clock no longer
  resets when a scan is declined; the junk clean button is the visual
  primary; the git graph's commit subjects no longer carry a trailing
  newline (phantom second line / skewed truncation).
- **Update-AiClis could downgrade a CLI** when the installed version was
  newer than the channel's latest - versions are now compared as parsed
  `[version]`s and only a strictly-greater remote queues an update.
- **Clear-DiskJunk's Windows Update steps silently no-oped for non-admins**
  while printing DONE; they're now admin-gated with a clear skip notice.
- Manage-StartupPrograms: all-users Startup-folder entries now correctly
  require elevation, and disabling over an existing backup name aborts
  instead of silently destroying the earlier backup.
- Set-PowerPlan's numeric pick no longer fails on duplicate-similar plan
  names (selects by GUID); Show-DiskUsageReport validates `-Top`;
  DevKit-Doctor labels the real system drive (not hardcoded "C:").
- Docker-Cleanup's "Estimated reclaimable" regex now matches `docker
  system df`'s actual output (was dead code); Git-SyncFork's git-missing
  check is reachable (was dead code bypassed by the exception);
  lock-file deletions in Nuke-And-Reinstall / Next-FullClean fail loudly
  instead of printing DONE; Edit-Path no longer writes a leading empty
  PATH segment on machines with an empty user PATH;
  `Get-DevKitProcessByPort` prefers the live LISTEN row over stale
  TIME_WAIT rows; the active-project header cache is invalidated on
  unlink/relink/rename; `Read-DevKitTypedValue` honors `Min = 0` and
  rejects out-of-range input instead of throwing; the GUI's project
  picker "Browse..." sets the Active Project like "Use Selected" does;
  the GUI's "Restart as Administrator" keeps `-NoWindowsTerminal`; clearing
  the GUI search box restores the pre-search page instead of replaying a
  stale search.
- **The widget's System Junk clean touches only locations that always
  work unelevated**: the contents of the user's own temp folder and the
  Recycle Bin. `Windows\Temp` (where deletes silently no-op for
  non-admins) and the Windows Update download cache still count toward
  the gauge but are left to the real Clear-DiskJunk tool, and "Freed X"
  is measured before/after on that same subset so the number stays
  honest.
- Set-PowerPlan parses `powercfg /list` output by line shape (GUID,
  parenthesized name, optional active marker) instead of anchoring on
  the English "Power Scheme GUID:" label, so it no longer breaks on
  localized Windows.
- Convert-DevText no longer hangs on piped/redirected stdin: EOF at the
  mode picker exits cleanly as "Cancelled", and a mode that needs input
  fails with a clear error instead of waiting on a Read-Host that can
  never return.
- The hardcoded version fallbacks in `DevKit.ps1` and `lib/DevKit-UI.ps1`
  (used only when the repo-root `VERSION` file is unreadable) still said
  `3.1.0`; they now read 3.8.0.

## [3.7.0] - 2026-08-02

A persistent companion for the desktop app: a small branded widget that
keeps your system's vitals and your AI tooling's wiring on screen even after
DevKit itself is closed.

### Added

- **Companion widget** (`gui/DevKit-Widget.ps1`, launched from the gauge
  button in the DevKit title bar or the Getting Started page). A compact
  always-on-top window - CPU, memory, and GPU load with best-effort
  temperatures (ACPI thermal-zone counter; nvidia-smi when present; every
  sensor honestly degrades to "n/a" rather than inventing numbers) - plus
  the running Node.js processes with their listening ports, and any other
  process squatting on a common dev port.
- **Project selector** at the top of the widget, bound to the same Active
  Project the GUI and terminal UI share - changes made in any of the three
  front-ends show up in the others within seconds.
- **Expandable Claude Code and Kimi Code boxes**: CLI presence/version plus
  MCP servers for the user scope and the selected project, each with a
  status badge - Connected / Disconnected / Requires Auth for Claude (from
  the documented `claude mcp list` health check, run in a background
  runspace so the widget never freezes), Configured / Disabled / Requires
  Auth for Kimi (from its documented `mcp.json` files - Kimi has no headless
  status command, so the widget says so rather than guessing).
- **Quick actions**: Clear NPM Cache, Kill All Node, Kill Port..., and
  Doctor launch the real DevKit tools in terminal windows; Open DevKit
  brings up the main app.
- **System-tray presence**: the widget lives in the tray with a dark branded
  context menu (Show/Hide, Open DevKit, a reversible Start with Windows
  toggle, Exit), balloon hints, re-registration after an Explorer restart,
  and a single-instance guard with a summon event - clicking the gauge in
  DevKit always resurfaces the running widget instead of starting a second
  one. Closing the widget window only hides it.

## [3.6.0] - 2026-08-02

A branded desktop app for the toolkit - the same twelve manifests, the same
sixty-plus scripts, now behind a native dark UI themed on the Northstar
compass-rose logo.

### Added

- **Desktop GUI** (`gui/` + root `DevKit-GUI.bat`). A dependency-free WPF
  shell (runs on both pwsh 7 and Windows PowerShell 5.1) that renders every
  tool-category `_module.psd1` as a navigable page of tool cards: grouped
  category navigation, live search across all tools, linked-project
  management (link/pin/rename/relink/remove, set/clear active), and
  validated dialogs for each item's declared inputs (project picker, file
  picker, typed prompts with min/max checking). Cards flag what a tool needs
  (`PROJECT`/`FILE`/`INPUT`) and surface a `CAUTION` chip for tools whose
  help text carries a safety note.
- **Tools launch in a real terminal window** - Windows Terminal when
  installed, classic console otherwise, pwsh preferred with a powershell
  fallback - with `-NoExit` so quick tools' output stays on screen. Every
  script's existing interactivity (arrow-key menus, gradient banners,
  spinners, confirmations, dev servers) works byte-for-byte unchanged; the
  GUI is purely additive and the classic terminal UI (`DevKit.bat`) remains
  fully supported.
- **Brand system**: `gui/Theme.xaml` (palette, gradients, and control styles
  extracted from the company logo - gunmetal backgrounds, brushed-silver
  title text, sapphire and ember accents) plus committed logo assets
  (`gui/Assets/`, regenerable via `gui/Build-Assets.ps1`), custom window
  chrome, and a status bar showing active project, terminal, and version.
- **Pester coverage for the GUI core** (`tests/Unit/GuiCore.Tests.ps1`):
  argument-resolution parity with `Invoke-DevKitTool`, shell quoting,
  terminal command building, and a catalog integrity check that every
  manifest item points at a script that exists on disk.

## [3.5.0] - 2026-07-12

A gradient startup banner and spinner engine, in-menu help across every
tool category, a much wider (and more honest) AI-CLI tracking list, a
curated MCP server catalog with a scan-and-fill-gaps flow, and a batch of
real bugs found and fixed during the audit that produced all of the above.

### Added

- **Animation & color engine** (new `lib\DevKit-UI.ps1`):
  `Test-DevKitAnimationSupport` is a capability probe that fails closed to
  today's plain output on any doubt - it checks `NO_COLOR` is unset,
  `settings.json`'s new `preferences.enableAnimations` is true, console
  output isn't redirected, and a real Windows Console API probe
  (`GetStdHandle`/`GetConsoleMode`/`SetConsoleMode`) confirms virtual
  terminal processing can actually be enabled on the stdout handle.
  `Write-DevKitGradientText` renders 24-bit ANSI gradient text anchored on
  the existing brand blue `#00B4D8`. `Show-DevKitStartupBanner` prints a
  gradient banner exactly once per session - `DevKit.ps1` calls it once at
  startup, never on every menu redraw. `Invoke-DevKitWithSpinner` runs a
  scriptblock behind an animated braille spinner on a dedicated Runspace
  via `BeginInvoke`, for callers whose child output is already fully
  captured/buffered; it falls back to today's plain
  `Write-DevKitStep`/`-Done`/`-Error` sequence whenever animation isn't
  supported or spinner setup fails, invoking the scriptblock exactly once
  either way. `DevKit.ps1` also no longer hardcodes `v3.1.0` in its header
  banner - it now reads the repo-root `VERSION` file dynamically, closing
  a real pre-existing gap where every past version bump required
  remembering to hand-edit that literal string (nobody had, for 3.1.0).
- **In-menu help.** The `_module.psd1` manifest schema gained two optional
  keys: a top-level `Description` (one or two sentences about the whole
  category) and a per-item `Help` (what it does, when to use it, and any
  safety notes). `Show-DevKitModuleMenu` now prints a category's
  `Description` under its header, and `Start-DevKitModuleTools` gained a
  `?` entry that lists every item's Label and Help text. All twelve
  tool-category manifests - Agents & MCP, Ports, Node, Next.js, Vite, Git,
  Docker, System, Workflow, Diagnostics, WiFi, and Maintenance (14 items,
  the largest category) - now have this filled in for every item. The
  Main Menu also gained its own `?` "Getting Started" entry
  (`Show-DevKitGettingStarted`) explaining Active Project linking, the `p`
  suffix convention, `/` search, and the new per-category help.
- **CLI tracking expanded from 6 to 11 tools.** `Get-InstalledAiClis.ps1`
  and `Update-AiClis.ps1` now also detect Supabase CLI, Vercel CLI,
  Railway CLI, Kimi Code CLI, and Augment Code CLI (`auggie`), alongside
  the existing claude/gh/codex/gemini/cursor-agent/aider. Update now
  branches per tool on a real "channel" (`npm` / `npm+builtin` / `scoop` /
  `manual`) instead of assuming everything is an npm package - Supabase's
  CLI cannot be installed globally via npm at all (confirmed against a
  real upstream issue), so it's tracked via Scoop; Vercel and Railway
  prefer their own builtin `upgrade` subcommand before falling back to
  npm; Kimi is deliberately manual-only because the `kimi` command name is
  shared by two unrelated real-world tools (Moonshot AI's npm-based Kimi
  Code CLI and an older Python-based `kimi-cli`) - a live, confirmed
  ambiguity, not a theoretical one - so auto-updating it risked corrupting
  an unrelated tool; Augment Code CLI now shows an explicit
  "Windows support is WSL-only" note instead of a bare "not installed"
  when it's missing from native PATH.
- **MCP server catalog and scan** (new `lib\DevKit-McpCatalog.ps1`,
  `lib\DevKit-McpList.ps1`, `lib\DevKit-McpAddFlow.ps1`; new
  `agents\Add-McpServerFromCatalog.ps1`, `agents\Scan-McpServers.ps1`): a
  10-entry curated catalog of well-known MCP servers (Supabase, Sequential
  Thinking, Context7, GitHub, Filesystem, Notion, Jira/Atlassian, Linear,
  Stripe, Plaid), most offering one or more registration variants - many
  now default to a remote/OAuth-hosted HTTP server rather than a local
  npx package (Supabase, GitHub, Notion, Jira/Atlassian, Linear, and
  Stripe all default to remote; Sequential Thinking and Filesystem are
  local-only; Context7 defaults local with a remote alternate); Plaid is
  marked experimental with no automatable variant at all, since its MCP
  server needs a short-lived OAuth token refresh that a one-time
  registration can't sustain, so picking it just shows a docs pointer.
  `agents\Add-McpServer.ps1` gained a second parameter set
  (`-Transport http -Url -Headers`) - previously it could only register
  local stdio commands, so it structurally could not register 6 of the 10
  catalog entries. `agents\Get-McpServers.ps1`'s `-Scope` parameter is now
  real (it used to be purely informational, since `claude mcp list` has no
  scope flag) - it diffs a listing run from a neutral directory against
  one run from the active project directory to split user/global scope
  from project/local scope. `agents\Scan-McpServers.ps1` cross-references
  configured servers against the catalog per scope and interactively
  offers to add anything missing. `agents\_module.psd1` grew from 5 items
  to 7.

### Fixed

- **`wifi\WiFi-Scan.ps1`**: a PowerShell array-flattening bug made a
  single-network scan report the wrong count ("Found 4 network(s)" when
  only 1 was found), because a returned 1-element array flattened to a
  bare Hashtable whose `.Count` read as its key count instead. Fixed at
  both the function-return and pipeline-assignment sites; a new Pester
  regression test (`tests\Unit\WiFiScan-Parser.Tests.ps1`) was added using
  real captured single-network `netsh` output, since the pre-existing
  fixture only ever exercised 3-network input.
- **`lib\DevKit-McpList.ps1`**'s server-name parser was silently dropping
  server names containing spaces (e.g. a real connector named
  `claude.ai Notion`) due to an over-restrictive character-class regex;
  fixed to split on the first `': '` instead. Caught via a live run
  against this machine's actual configured MCP servers.
- **`docker\Docker-Nuke.ps1`**'s "nothing to nuke" early-exit check
  special-cased `-KeepVolumes` but not `-KeepImages`, so running
  `-KeepImages` on a machine with only images (no containers/volumes/
  networks) skipped straight to a live confirmation prompt for an
  operation that would end up deleting nothing. Fixed to mirror the
  existing `-KeepVolumes` pattern.
- **`diagnostics\System-DevInfo.ps1`**: (a) the disk-usage loop divided by
  zero on an empty/unmounted local-disk-type volume (`Size` 0 or null),
  which threw and silently dropped every disk enumerated after it from the
  report behind a misleading "Could not query WMI/CIM" message - it now
  skips just that one disk with a clear "unavailable" line and continues;
  (b) network-adapter selection picked whichever "Up" adapter enumerated
  first with no preference for one with a real default gateway, so a
  machine with a Hyper-V/WSL/VPN virtual adapter could report that
  adapter's NAT-only IP instead of the machine's real network identity -
  it now prefers an adapter with a non-null default gateway before falling
  back.
- **`node\Nuke-And-Reinstall.ps1`**: the pre-confirmation warning shown
  right before the typed-`nuke` safety gate didn't match what the script
  actually deletes (it claimed `dist` and `.vite` caches, which are never
  touched by default, and omitted `.turbo`, which always is). Fixed the
  displayed text only - no change to actual deletion behavior.
- **Repo-wide color-convention cleanup**: `AGENTS.md` documents Yellow as
  reserved for real warnings, not routine progress chrome. Roughly 25+
  stray Yellow progress-chrome lines were corrected to Cyan/Gray as
  appropriate across `ports/`, `node/`, `vite/`, `git/`, `docker/`,
  `system/`, `workflow/`, and `diagnostics/`.
- Small doc/comment accuracy fixes: missing `.PARAMETER` entries added
  (`system\Env-Backup.ps1`'s `-Force`, `wifi\WiFi-FastMode.ps1`'s
  `-KeepDNS`/`-Force`), a stale/missing script-header footer added
  (`node\Clear-NpmCache.ps1`), `.SYNOPSIS` lines brought in line with the
  repo-wide template (`system\Install-/Uninstall-ShellIntegration.ps1`),
  dead/unused variables removed (`git\Git-StatusAll.ps1`,
  `diagnostics\DevKit-Doctor.ps1`), and a missing version-display line
  added to `docker\Docker-Cleanup.ps1` to match its sibling
  `Docker-Nuke.ps1`.

### Known Issues

Real gaps found during this sprint's audit and deliberately left
unchanged, since fixing them would alter user-facing mutating behavior
rather than just correct wrong information:

- Many mutating scripts across `ports/`, `node/`, `nextjs/`, `vite/`,
  `git/`, `docker/`, `system/`, and `workflow/` predate the shared
  `Confirm-DevKitDestructiveAction` helper and hand-roll their own y/n
  prompts, so they don't honor `settings.json`'s global
  `confirmDestructive` toggle the way newer destructive scripts do
  (already documented in `AGENTS.md`).
- `maintenance\Repair-SystemFiles.ps1` and
  `maintenance\Reset-WindowsUpdate.ps1` both default to attempting the
  real mutating action behind just a confirmation prompt (`-DryRun` is
  opt-out, not opt-in) - the inverse of the safe-by-default pattern the
  rest of `maintenance/` follows, and structurally the same shape as the
  2026-07-11 incident `AGENTS.md` already documents for
  `Reset-WindowsUpdate.ps1` specifically.
- `git\Git-SyncFork.ps1` has no `-DryRun`/preview mode at all, unlike its
  sibling `Git-Cleanup.ps1`.
- `system\Uninstall-ShellIntegration.ps1` and
  `system\Unregister-DevKitTerminalProfile.ps1` delete real registry/file
  state with no confirmation prompt of any kind.
- `docker\Docker-Cleanup.ps1`'s displayed "Custom networks" count can
  overstate what `-AllUnused` actually prunes - Docker has no built-in
  "dangling" filter for networks, so the count includes in-use ones.
- A handful of judgment-call color/severity inconsistencies (e.g.
  `ports\Kill-AllNode.ps1`'s failure severity vs. its siblings,
  `maintenance\Manage-Services.ps1`'s disclaimer color) and duplicated
  logic (`system\Edit-Path.ps1`/`Shell-Reload.ps1` share a copy-pasted
  helper function; `diagnostics\DevKit-Doctor.ps1`/`System-DevInfo.ps1`
  each separately implement tool-version detection) were flagged but not
  changed.
- `AGENTS.md`'s Project Structure tree was missing a few files that exist
  on disk and now have in-menu help text (`node\Check-NpmCacheSize.ps1`,
  `nextjs`'s `Clear-NextCache.bat`/`Clear-TurboCache.bat`, and `system`'s
  four opt-in setup scripts) - fixed as part of this release's
  documentation pass.

## [3.1.0] - 2026-07-11

Arrow-key navigation across every menu, and two new tool categories: real
Windows maintenance/tuning tools (not just a dev-environment health check),
and an AI CLI & MCP server manager.

### Added

- **Arrow-key navigation** (`Show-DevKitInteractiveMenu` in
  `lib\DevKit-Common.ps1`). Every menu - Main Menu, each tool category,
  Projects, and Search results - now supports Up/Down + Enter to move and
  select, Escape to go back, while typing a number (and the `p` suffix for
  a one-off project override) still works exactly as before. On a console
  that can't do raw key reads (redirected input, CI, some non-interactive
  hosts), it transparently falls back to the classic `Read-Host` prompt -
  every existing scripted/piped-input workflow keeps working unchanged.
- **`[12] Maintenance`** - 14 real Windows maintenance/tuning tools across
  six areas: disk & storage cleanup (`Clear-DiskJunk.ps1`,
  `Show-DiskUsageReport.ps1`), startup & services tuning
  (`Manage-StartupPrograms.ps1`, `Manage-Services.ps1`), system repair
  (`Repair-SystemFiles.ps1` for SFC/DISM, `Reset-WindowsUpdate.ps1`),
  scheduled tasks & event log triage (`Get-ScheduledTasksReport.ps1`,
  `Get-RecentEventErrors.ps1`), power & performance tuning
  (`Set-PowerPlan.ps1`, `Set-VisualEffects.ps1`, `Test-PageFileConfig.ps1`),
  and hardware health (`Get-DiskHealthReport.ps1`, `Get-BatteryReport.ps1`,
  `Invoke-MemoryDiagnostic.ps1`). Every mutating tool defaults to a safe
  read-only report and requires an explicit flag plus confirmation
  (`Confirm-DevKitDestructiveAction`) to actually change anything.
- **`[13] Agents & MCP`** - manage AI coding-agent CLIs and Claude Code's
  MCP servers, both globally and per linked project:
  `Get-InstalledAiClis.ps1` (detect claude/gh/codex/gemini/cursor-agent/
  aider), `Update-AiClis.ps1` (best-effort npm-based updates), and
  `Get-McpServers.ps1` / `Add-McpServer.ps1` / `Remove-McpServer.ps1`
  wrapping `claude mcp list/add/remove`, using the existing active-project
  system to target a specific project's MCP scope.

### Fixed

- **A real "Select an app to open" dialog bug**, hit while building the
  Agents & MCP pack: on a machine with more than one `gh` on PATH,
  `Get-Command`'s first match can be an extension-less shim rather than a
  `.exe`/`.cmd` wrapper, and invoking that with PowerShell's `&` operator
  makes it fall back to ShellExecute, popping a real Windows dialog instead
  of failing cleanly. Added `Get-DevKitWindowsExecutable` (`lib\DevKit-
  Common.ps1`) - resolves to only a recognized Windows-executable match (or
  a native PS command, which never hits ShellExecute) - and use it anywhere
  this codebase invokes a user-installed CLI by name.
- A background build-time agent for this release ran `Reset-WindowsUpdate.ps1`
  for real instead of the instructed `-DryRun` while self-testing; the
  safety system blocked it before any change landed (independently
  confirmed via service-state event logs and folder timestamps). See
  `AGENTS.md`'s Security Considerations for the guardrail this added.

## [3.0.0] - 2026-07-11

A full review-driven overhaul: every confirmed critical/high bug fixed, a
browsable project-linking system (the headline ask for this release), and
a manifest-driven menu architecture that replaces ~40 duplicated blocks of
dispatch logic with one reusable implementation.

### Added

- **Browsable project linking.** Every tool that needs a project directory
  now goes through a shared picker instead of a bare typed prompt: pick
  from previously-linked projects (sorted by pinned, then most recently
  used), browse for a folder via a real Windows folder dialog, use the
  current directory, or type a path manually. Whatever you choose becomes
  the **Active Project**, shown in the header and reused silently by every
  subsequent tool for the rest of the session. Append `p` to any menu
  number (e.g. `4p`) to use a different project for one run without
  disturbing the active one. New `[10] Projects` menu to set/clear the
  active project and manage the linked list (rename/pin/unlink/relink).
- **Manifest-driven tool menus.** Each tool category (Port/Node/Next.js/
  Vite/Git/Docker/System/Workflow/Diagnostics/WiFi Tools) is now described
  by a small `_module.psd1` data file instead of a hand-written menu
  function. Adding a new tool to an existing category is a manifest entry,
  not a `DevKit.ps1` edit.
- **Search/jump** (`/` from the Main Menu): search every tool category's
  items by keyword and jump straight to one instead of drilling through
  submenus by number.
- **A reusable confirmation gate** (`Confirm-DevKitDestructiveAction`) and
  a settings file (`%LOCALAPPDATA%\NorthstarDevKit\settings.json`,
  `preferences.confirmDestructive`) so destructive actions share one
  correctly-implemented (case-sensitive typed-phrase, or y/N) prompt.
  `docker\Docker-Nuke.ps1` now uses it as the reference example.
- **Pester test suite** (`tests/Unit`, wired into CI) covering the parsers
  and converters this release's review found real bugs in: package-manager
  detection, PATH de-duplication, the `.env` template parser, the git-
  remote-to-browsable-URL converter, and the WiFi network scan parser.
- `node\Check-NpmCacheSize.bat` (the one script in the repo missing its
  batch wrapper).

### Fixed

Selected highlights - see the full 3.0 code review for the complete list
of ~150 confirmed findings:

- **`system\Env-Restore.ps1` could not run at all.** Loose top-level code
  sat between `param()` and an explicit `begin {}` block, which made
  PowerShell treat the literal token `begin` as a command name instead of
  a pipeline block - every invocation threw `The term 'begin' is not
  recognized...`. Pre-existing; found and fixed during this release.
- `workflow\Open-Repo.ps1`: the resolved URL is now validated as a real
  `http(s)://` address before being handed to `Start-Process`, closing a
  local-code-execution path via a malicious/tampered git remote.
- `git\Git-SyncFork.ps1`: rebase-sync now force-pushes with
  `--force-with-lease` (fetching the remote ref first) instead of a plain
  `-f`.
- `git\Git-Cleanup.ps1`: merged-branch detection now compares against the
  repo's actual default branch instead of bare `HEAD`, so an unmerged
  branch can no longer be offered for deletion.
- `wifi\WiFi-Scan.ps1`: fixed the SSID/BSSID regex collision that meant
  the scanner had never successfully parsed a single network.
- `wifi\WiFi-FastMode.ps1`: fixed a guaranteed parameter-binding crash when
  launched from the DevKit.ps1 menu.
- `docker\Docker-Nuke.ps1`: the "type NUKE" confirmation is now
  case-sensitive (typing `nuke` no longer silently proceeds).
- `docker\Docker-QuickLogs.ps1`: fixed a single-container array-collapse
  bug and a `-Follow $false` positional-parameter-binding trap.
- `node\Nuke-And-Reinstall.ps1` / `nextjs\Next-FullClean.ps1`: package
  manager is no longer silently re-detected (and downgraded to npm) after
  the project's own lock file has already been deleted.
- `nextjs\Next-FullClean.ps1`: `-StartDev` now launches the dev server
  from the actual project directory, not wherever the process happened to
  be beforehand.
- `ports\Kill-Port.ps1`, `Kill-AllNode.ps1`, `Scan-Ports.ps1`: process
  identity is now re-verified immediately before `Stop-Process`, closing a
  time-of-check-to-time-of-use gap between showing a process and killing
  it.
- `.bat` wrappers across the repo now propagate real script failures
  correctly instead of always exiting 0.
- Color-output convention corrected repo-wide: Yellow is reserved for real
  warnings; routine progress/chrome text moved off Yellow; a handful of
  messages that hard-`exit`ed were relabeled from "WARNING" to "ERROR" to
  match what they actually do.

### Changed

- `DevKit.ps1` dropped from 691 lines to ~180: it now dot-sources
  `lib\DevKit-Common.ps1` (previously the one script in the repo that
  didn't) and delegates all ten tool-category submenus to the generic
  manifest dispatcher.
- Version banner and `.VERSION` metadata bumped to 3.0.0 across
  `DevKit.ps1` and `lib\DevKit-Common.ps1`.

## [2.1.0] - prior to this repository's public history

Unified the toolkit under a shared helper module (`lib\DevKit-Common.ps1`),
added package-manager auto-detection, completed batch-wrapper coverage,
and fixed a series of PowerShell 7 / path-validation / process-killing
bugs. Recorded here retrospectively; see git history for specifics.
