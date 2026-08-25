//! Interactive ratatui menu for the `devkit` CLI - replaces `DevKit.ps1`'s
//! console TUI. Reads the same `catalog.get` payload the GUI renders,
//! navigates arrow-key style with `/` search and a `p` project switcher,
//! and - unlike the Control Center's `tool.run` RPC, which pipes stdio and
//! can't drive an interactive console menu - runs a chosen tool by
//! suspending this UI and spawning `pwsh -File <script> <args>` directly
//! with inherited stdio, so the tool's own prompts/menus behave exactly as
//! they did under the old TUI.

use std::collections::HashMap;
use std::io::{self, Stdout};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::Context;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use devkit_host::PsHost;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{Frame, Terminal};
use serde_json::json;

use crate::catalog::{self, Catalog, CatalogItem, LinkedProject, PromptRawValue};

// ==================== terminal lifecycle ====================

/// Owns the alternate-screen/raw-mode terminal state. `Drop` always tries
/// to restore the terminal (best-effort, errors ignored - we may already
/// be unwinding), which covers every normal early return via `?`.
/// [`install_panic_hook`] covers the panic case, including a `panic =
/// "abort"` release build where no destructor runs at all: a panic hook
/// fires *before* the abort/unwind decision either way, so it is the only
/// path that is reliable in both profiles.
struct Tui {
    terminal: Terminal<CrosstermBackend<Stdout>>,
}

impl Tui {
    fn new() -> anyhow::Result<Self> {
        enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(stdout, EnterAlternateScreen)?;
        let terminal = Terminal::new(CrosstermBackend::new(stdout))?;
        Ok(Self { terminal })
    }

    /// Leaves the alternate screen / raw mode so a spawned tool gets a
    /// normal inherited console, matching the old TUI's own console.
    fn suspend(&mut self) -> anyhow::Result<()> {
        disable_raw_mode()?;
        execute!(self.terminal.backend_mut(), LeaveAlternateScreen)?;
        self.terminal.show_cursor()?;
        Ok(())
    }

    fn resume(&mut self) -> anyhow::Result<()> {
        enable_raw_mode()?;
        execute!(self.terminal.backend_mut(), EnterAlternateScreen)?;
        self.terminal.hide_cursor()?;
        self.terminal.clear()?;
        Ok(())
    }
}

impl Drop for Tui {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(self.terminal.backend_mut(), LeaveAlternateScreen);
        let _ = self.terminal.show_cursor();
    }
}

fn install_panic_hook() {
    let original = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        original(info);
    }));
}

/// Ctrl+C arrives as a plain key event while raw mode is enabled (it is
/// not delivered as a signal), so every input loop below treats it the
/// same as Escape rather than letting it fall through and get typed into
/// whatever buffer has focus.
fn is_cancel_key(code: KeyCode, modifiers: KeyModifiers) -> bool {
    matches!(code, KeyCode::Esc)
        || (modifiers.contains(KeyModifiers::CONTROL) && matches!(code, KeyCode::Char('c') | KeyCode::Char('C')))
}

// ==================== entry point ====================

pub async fn run(host: PsHost, pwsh: PathBuf, root: PathBuf) -> anyhow::Result<()> {
    install_panic_hook();
    let mut tui = Tui::new()?;
    // `tui`'s Drop restores the terminal here regardless of which branch
    // `run_inner` returned through.
    run_inner(&host, &pwsh, &root, &mut tui).await
}

async fn run_inner(host: &PsHost, pwsh: &Path, root: &Path, tui: &mut Tui) -> anyhow::Result<()> {
    let catalog: Catalog = serde_json::from_value(host.call("catalog.get", None).await?)
        .context("failed to parse catalog.get response")?;
    let mut active_project: Option<LinkedProject> =
        serde_json::from_value(host.call("projects.getActive", None).await?)
            .context("failed to parse projects.getActive response")?;

    let groups = catalog::ordered_groups(&catalog);

    loop {
        let project_line = format_project_line(&active_project);
        let rows: Vec<ListRow> = groups.iter().map(|g| ListRow::plain(g.clone())).collect();
        let help = "\u{2191}/\u{2193} move   Enter open   / search   p project   digits+Enter jump   Esc quit";

        match list_screen(tui, "Main Menu", help, &rows, &project_line, true, true)? {
            ListAction::Back => break,
            ListAction::ToggleProject => {
                if let Some(p) = project_picker_flow(host, tui, false).await? {
                    active_project = Some(p);
                }
            }
            ListAction::Search => {
                run_search_loop(host, tui, pwsh, root, &catalog, &mut active_project).await?;
            }
            ListAction::Enter(idx) => {
                let group = groups[idx].clone();
                run_category_loop(host, tui, pwsh, root, &catalog, &group, &mut active_project).await?;
            }
        }
    }

    Ok(())
}

async fn run_category_loop(
    host: &PsHost,
    tui: &mut Tui,
    pwsh: &Path,
    root: &Path,
    catalog: &Catalog,
    group: &str,
    active_project: &mut Option<LinkedProject>,
) -> anyhow::Result<()> {
    loop {
        let project_line = format_project_line(active_project);
        let entries = catalog::items_for_group(catalog, group);
        let rows: Vec<ListRow> = entries
            .iter()
            .map(|(_, module_name, item)| ListRow::tool(module_name, item))
            .collect();
        let help = "\u{2191}/\u{2193} move   Enter run   p project   digits+Enter jump   Esc back";

        match list_screen(tui, group, help, &rows, &project_line, false, true)? {
            ListAction::Back => return Ok(()),
            ListAction::ToggleProject => {
                if let Some(p) = project_picker_flow(host, tui, false).await? {
                    *active_project = Some(p);
                }
            }
            ListAction::Enter(i) => {
                let (folder, _module_name, item) = entries[i];
                if let Some(msg) =
                    run_tool_flow(host, tui, pwsh, root, folder, item, active_project).await?
                {
                    message_screen(tui, "Tool Run", &msg, msg.starts_with("ERROR"))?;
                }
            }
            ListAction::Search => unreachable!("search is disabled inside a category screen"),
        }
    }
}

async fn run_search_loop(
    host: &PsHost,
    tui: &mut Tui,
    pwsh: &Path,
    root: &Path,
    catalog: &Catalog,
    active_project: &mut Option<LinkedProject>,
) -> anyhow::Result<()> {
    loop {
        let project_line = format_project_line(active_project);
        match search_screen(tui, catalog, &project_line)? {
            SearchOutcome::Cancel => return Ok(()),
            SearchOutcome::Run(folder, item) => {
                if let Some(msg) =
                    run_tool_flow(host, tui, pwsh, root, &folder, &item, active_project).await?
                {
                    message_screen(tui, "Tool Run", &msg, msg.starts_with("ERROR"))?;
                }
            }
        }
    }
}

// ==================== running a tool ====================

/// Collects whatever the item needs (project path, file path, prompts),
/// builds the final argv via [`catalog::build_arguments`], then suspends
/// the TUI and runs the script as a direct inherited-stdio child process.
/// Returns a status/error message for the caller to show via
/// [`message_screen`], or `None` if the user cancelled with no message
/// needed.
async fn run_tool_flow(
    host: &PsHost,
    tui: &mut Tui,
    pwsh: &Path,
    root: &Path,
    folder: &str,
    item: &CatalogItem,
    active_project: &mut Option<LinkedProject>,
) -> anyhow::Result<Option<String>> {
    let mut values: HashMap<String, PromptRawValue> = HashMap::new();
    let project_line = format_project_line(active_project);

    if item.requires_project {
        // Fast path: an active, present project is used silently - matches
        // Select-DevKitProject's behavior. Otherwise force the picker,
        // same as Select-DevKitProject falling through to its interactive
        // picker when there is no usable Active Project.
        let usable = active_project.as_ref().filter(|p| !p.missing).cloned();
        let project = match usable {
            Some(p) => p,
            None => match project_picker_flow(host, tui, true).await? {
                Some(p) => {
                    *active_project = Some(p.clone());
                    p
                }
                None => return Ok(Some("Cancelled -- no project selected.".to_string())),
            },
        };
        let arg_name = item
            .project_arg_name
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "Path".to_string());
        values.insert(arg_name, PromptRawValue::Text(project.path.clone()));
    } else if let Some(rf) = &item.requires_file {
        // A genuine native Windows file dialog, not a typed-path prompt -
        // matches Show-DevKitFileBrowser's own OpenFileDialog. Suspend the
        // TUI first (same pattern as the tool-run spawn below) so the
        // hidden pwsh process showing it isn't fighting the alternate
        // screen for the console.
        tui.suspend()?;
        let pwsh_owned = pwsh.to_path_buf();
        let title = item.label.clone();
        let filter = rf.filter.clone();
        let picker_result = tokio::task::spawn_blocking(move || {
            run_native_file_picker(&pwsh_owned, &title, filter.as_deref())
        })
        .await;
        tui.resume()?;

        let picked = match picker_result {
            Ok(Ok(path)) => path,
            Ok(Err(e)) => return Ok(Some(format!("ERROR: file picker failed: {e}"))),
            Err(e) => {
                return Ok(Some(format!(
                    "ERROR: internal task failure showing file picker: {e}"
                )))
            }
        };
        // Empty output means the dialog was cancelled - treated exactly
        // like a blank required text prompt: `build_arguments` below turns
        // this `None` into the "Missing required file" error message.
        let value = match picked {
            Some(path) if !path.trim().is_empty() => PromptRawValue::Text(path),
            _ => PromptRawValue::None,
        };
        values.insert(rf.param_name.clone(), value);
    }

    if let Some(prompts) = &item.prompts {
        for spec in prompts {
            let outcome = match spec.kind.as_str() {
                "Int" => prompt_int(tui, spec, &project_line)?,
                "YesNo" => prompt_yesno(tui, spec, &project_line)?,
                _ => prompt_string(tui, spec, &project_line)?,
            };
            match outcome {
                PromptOutcome::Cancelled => return Ok(None),
                PromptOutcome::Value(v) => {
                    values.insert(spec.name.clone(), v);
                }
            }
        }
    }

    let args = match catalog::build_arguments(item, &values) {
        Ok(a) => a,
        Err(msg) => return Ok(Some(format!("ERROR: {msg}"))),
    };

    let script_path = root.join("tools").join(folder).join(&item.script);
    if !script_path.exists() {
        return Ok(Some(format!(
            "ERROR: script not found: {}",
            script_path.display()
        )));
    }

    tui.suspend()?;
    let pwsh_owned = pwsh.to_path_buf();
    let root_owned = root.to_path_buf();
    let spawn_result = tokio::task::spawn_blocking(move || {
        Command::new(&pwsh_owned)
            .arg("-NoLogo")
            .arg("-NoProfile")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&script_path)
            .args(&args)
            .current_dir(&root_owned)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
    })
    .await;
    tui.resume()?;

    let message = match spawn_result {
        Ok(Ok(status)) => format!(
            "Finished: {}  (exit code {})",
            item.label,
            status.code().map(|c| c.to_string()).unwrap_or_else(|| "unknown".to_string())
        ),
        Ok(Err(e)) => format!("ERROR: failed to launch '{}': {e}", item.label),
        Err(e) => format!("ERROR: internal task failure running '{}': {e}", item.label),
    };
    Ok(Some(message))
}

// ==================== native file picker ====================
//
// Windows' `CREATE_NO_WINDOW` process-creation flag - kept the child pwsh
// process from flashing its own console window while it puts up the
// OpenFileDialog (which is a real Win32 window of its own, unrelated to
// the console).
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Shells out to a hidden `pwsh` process that shows a native
/// `System.Windows.Forms.OpenFileDialog` and reads the chosen path back
/// from its stdout - the CLI has no console-native file picker of its own,
/// so (like `Show-DevKitFileBrowser` in the old PowerShell TUI) this
/// borrows a real Win32 dialog instead of a typed-path prompt. `title` is
/// the item's own label, so the user sees why a picker popped up; `filter`
/// is `RequiresFile.Filter` verbatim (already a standard Windows Forms
/// filter string - see `catalog::RequiresFile`), defaulting to "All Files
/// (*.*)|*.*" when absent. Returns `Ok(None)` if the dialog produced no
/// output (cancelled/closed with no selection).
fn run_native_file_picker(
    pwsh: &Path,
    title: &str,
    filter: Option<&str>,
) -> anyhow::Result<Option<String>> {
    let filter = filter.filter(|f| !f.is_empty()).unwrap_or("All Files (*.*)|*.*");
    let script = format!(
        "Add-Type -AssemblyName System.Windows.Forms\n\
         $dialog = New-Object System.Windows.Forms.OpenFileDialog\n\
         $dialog.Filter = {}\n\
         $dialog.Title = {}\n\
         if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {{\n\
         \x20   Write-Output $dialog.FileName\n\
         }}\n",
        ps_single_quote(filter),
        ps_single_quote(title),
    );

    let output = Command::new(pwsh)
        .arg("-NoLogo")
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-WindowStyle")
        .arg("Hidden")
        .arg("-Command")
        .arg(&script)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .context("failed to launch the native file picker")?;

    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        return Ok(None);
    }
    Ok(Some(path))
}

/// Wraps `s` in a PowerShell single-quoted string literal, doubling any
/// embedded `'` - the standard PowerShell escape for that quote style, so
/// a label or filter containing one can't break out of the literal.
fn ps_single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

// ==================== project picker ====================

/// Shared "which project?" flow for both the header's `p` switcher and a
/// tool that `requiresProject` with no usable Active Project - mirrors
/// `Select-DevKitProject`'s interactive picker (linked projects sorted
/// pinned-first/most-recent-first, plus add-new and clear-active).
/// `forced` just changes the title/copy and whether "Clear active
/// project" is offered (clearing would defeat the point of a forced pick).
async fn project_picker_flow(
    host: &PsHost,
    tui: &mut Tui,
    forced: bool,
) -> anyhow::Result<Option<LinkedProject>> {
    loop {
        let mut projects: Vec<LinkedProject> =
            serde_json::from_value(host.call("projects.list", None).await?)
                .context("failed to parse projects.list response")?;
        projects.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then_with(|| b.last_used_utc.cmp(&a.last_used_utc))
        });

        let mut rows: Vec<ListRow> = projects.iter().map(ListRow::project).collect();
        let add_idx = rows.len();
        rows.push(ListRow::plain("+ Add new project (type a path)".to_string()));
        let clear_idx = if !forced {
            rows.push(ListRow::plain("x Clear active project".to_string()));
            Some(rows.len() - 1)
        } else {
            None
        };

        let title = if forced {
            "Select a Project (required)"
        } else {
            "Switch Project"
        };
        let subtitle = if forced {
            "This tool needs a project - pick or link one to continue."
        } else {
            "Pick a linked project to make it Active."
        };
        let help = "\u{2191}/\u{2193} move   Enter select   Esc cancel";

        match list_screen(tui, title, help, &rows, subtitle, false, false)? {
            ListAction::Back => return Ok(None),
            ListAction::Enter(i) if i < projects.len() => {
                let picked = projects[i].clone();
                host.call("projects.setActive", Some(json!({ "id": picked.id })))
                    .await?;
                return Ok(Some(picked));
            }
            ListAction::Enter(i) if i == add_idx => {
                let Some(path) = read_text_input(tui, "Add Project", "Enter a folder path to link", TextInputKind::Free, subtitle)? else {
                    continue;
                };
                if path.trim().is_empty() {
                    continue;
                }
                let added = host
                    .call("projects.add", Some(json!({ "path": path })))
                    .await?;
                let project: LinkedProject = serde_json::from_value(added)
                    .context("failed to parse projects.add response")?;
                host.call("projects.setActive", Some(json!({ "id": project.id })))
                    .await?;
                return Ok(Some(project));
            }
            ListAction::Enter(i) if Some(i) == clear_idx => {
                host.call("projects.clearActive", None).await?;
                return Ok(None);
            }
            _ => continue,
        }
    }
}

fn format_project_line(active: &Option<LinkedProject>) -> String {
    match active {
        Some(p) if p.missing => format!(
            "Active Project: {}  -- PATH MISSING (press 'p' to relink)",
            p.name
        ),
        Some(p) => format!("Active Project: {} ({})", p.name, p.path),
        None => "Active Project: <none linked yet - press 'p' to link one>".to_string(),
    }
}

// ==================== prompt collection ====================
//
// Validation here mirrors Read-DevKitTypedValue (tools/lib/DevKit-Common.ps1)
// exactly: Int only accepts digits and is range/overflow-checked, blank or
// invalid input is "no value" rather than a re-prompt loop; YesNo is a
// single y/n keypress ('y'/'Y' -> true, anything else -> false, never "no
// value"); String is free text, blank -> "no value". What "no value" (vs
// required-and-missing being an error) *means* is then decided once by
// catalog::build_arguments, matching ConvertTo-DevKitToolArguments.

enum PromptOutcome {
    Cancelled,
    Value(PromptRawValue),
}

fn prompt_int(
    tui: &mut Tui,
    spec: &catalog::ToolPrompt,
    project_line: &str,
) -> anyhow::Result<PromptOutcome> {
    let subtitle = prompt_subtitle(spec);
    let Some(raw) = read_text_input(tui, "Enter Value", &subtitle, TextInputKind::DigitsOnly, project_line)? else {
        return Ok(PromptOutcome::Cancelled);
    };

    if raw.trim().is_empty() {
        return Ok(PromptOutcome::Value(PromptRawValue::None));
    }
    // Everything already typed is a digit (TextInputKind::DigitsOnly), but
    // stay defensive rather than assume the input filter is exhaustive.
    if !raw.chars().all(|c| c.is_ascii_digit()) {
        return Ok(PromptOutcome::Value(PromptRawValue::None));
    }
    let Ok(val) = raw.parse::<i64>() else {
        return Ok(PromptOutcome::Value(PromptRawValue::None));
    };
    if let Some(min) = spec.min {
        if val < min {
            return Ok(PromptOutcome::Value(PromptRawValue::None));
        }
    }
    if let Some(max) = spec.max {
        if val > max {
            return Ok(PromptOutcome::Value(PromptRawValue::None));
        }
    }
    // Read-DevKitTypedValue rejects casting past Int32.MaxValue rather
    // than overflowing.
    if val > i32::MAX as i64 {
        return Ok(PromptOutcome::Value(PromptRawValue::None));
    }
    Ok(PromptOutcome::Value(PromptRawValue::Text(val.to_string())))
}

fn prompt_string(
    tui: &mut Tui,
    spec: &catalog::ToolPrompt,
    project_line: &str,
) -> anyhow::Result<PromptOutcome> {
    let subtitle = prompt_subtitle(spec);
    let Some(raw) = read_text_input(tui, "Enter Value", &subtitle, TextInputKind::Free, project_line)? else {
        return Ok(PromptOutcome::Cancelled);
    };
    if raw.trim().is_empty() {
        return Ok(PromptOutcome::Value(PromptRawValue::None));
    }
    Ok(PromptOutcome::Value(PromptRawValue::Text(raw)))
}

fn prompt_yesno(
    tui: &mut Tui,
    spec: &catalog::ToolPrompt,
    project_line: &str,
) -> anyhow::Result<PromptOutcome> {
    loop {
        tui.terminal
            .draw(|f| draw_yesno(f, spec, project_line))?;
        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            if is_cancel_key(key.code, key.modifiers) {
                return Ok(PromptOutcome::Cancelled);
            }
            match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    return Ok(PromptOutcome::Value(PromptRawValue::Bool(true)))
                }
                KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Enter => {
                    return Ok(PromptOutcome::Value(PromptRawValue::Bool(false)))
                }
                _ => {}
            }
        }
    }
}

fn prompt_subtitle(spec: &catalog::ToolPrompt) -> String {
    if spec.optional {
        format!("{}  (optional - Enter to skip)", spec.prompt)
    } else {
        spec.prompt.clone()
    }
}

// ==================== generic input primitives ====================

enum TextInputKind {
    Free,
    DigitsOnly,
}

fn read_text_input(
    tui: &mut Tui,
    title: &str,
    subtitle: &str,
    kind: TextInputKind,
    project_line: &str,
) -> anyhow::Result<Option<String>> {
    let mut buf = String::new();
    loop {
        tui.terminal
            .draw(|f| draw_text_input(f, title, subtitle, &buf, project_line))?;
        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            if is_cancel_key(key.code, key.modifiers) {
                return Ok(None);
            }
            match key.code {
                KeyCode::Enter => return Ok(Some(buf)),
                KeyCode::Backspace => {
                    buf.pop();
                }
                KeyCode::Char(c) => {
                    let accept = match kind {
                        TextInputKind::Free => !c.is_control(),
                        TextInputKind::DigitsOnly => c.is_ascii_digit(),
                    };
                    if accept {
                        buf.push(c);
                    }
                }
                _ => {}
            }
        }
    }
}

fn message_screen(tui: &mut Tui, title: &str, message: &str, is_error: bool) -> anyhow::Result<()> {
    loop {
        tui.terminal
            .draw(|f| draw_message(f, title, message, is_error))?;
        if let Event::Key(key) = event::read()? {
            if key.kind == KeyEventKind::Press {
                return Ok(());
            }
        }
    }
}

// ==================== category / search list screens ====================

enum ListAction {
    Enter(usize),
    Back,
    Search,
    ToggleProject,
}

struct ListRow {
    primary: String,
    secondary: Option<String>,
    caution: bool,
}

impl ListRow {
    fn plain(text: String) -> Self {
        Self {
            primary: text,
            secondary: None,
            caution: false,
        }
    }

    fn tool(module_name: &str, item: &CatalogItem) -> Self {
        Self {
            primary: format!("[{module_name}] {}", item.label),
            secondary: Some(truncate(&item.help, 90)),
            caution: item.caution,
        }
    }

    fn project(p: &LinkedProject) -> Self {
        let pin = if p.pinned { "\u{2605} " } else { "" };
        let status = if p.missing { "  !! MISSING" } else { "" };
        let uses = if p.use_count == 1 {
            "1 use".to_string()
        } else {
            format!("{} uses", p.use_count)
        };
        Self {
            primary: format!("{pin}{}{status}", p.name),
            secondary: Some(format!("{}  [{}]  \u{2022} {uses}", p.path, p.tags.join(", "))),
            caution: p.missing,
        }
    }
}

/// Cap on the jump-to-row digit buffer below - generous for any realistic
/// category/search list (five digits covers up to row 99999) while keeping
/// a stray held-down digit key from growing the buffer unboundedly.
const JUMP_BUF_MAX: usize = 5;

fn list_screen(
    tui: &mut Tui,
    title: &str,
    help: &str,
    rows: &[ListRow],
    project_line: &str,
    allow_search: bool,
    allow_project_toggle: bool,
) -> anyhow::Result<ListAction> {
    let mut state = ListState::default();
    if !rows.is_empty() {
        state.select(Some(0));
    }
    // Digit-accumulator for jump-to-row - mirrors DevKit.ps1's own numbered
    // menu, where Read-Host reads a whole typed number (e.g. "12") before
    // acting on it, rather than only ever reacting to a single keypress.
    // Enter commits the jump (and is "consumed" by it, matching the
    // existing single-digit behavior of moving the selection rather than
    // also opening the row); Escape or any other, non-digit key clears it.
    let mut jump_buf = String::new();
    loop {
        tui.terminal
            .draw(|f| draw_list(f, title, help, rows, &mut state, project_line, &jump_buf))?;
        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            if is_cancel_key(key.code, key.modifiers) {
                return Ok(ListAction::Back);
            }
            if let KeyCode::Char(c) = key.code {
                if c.is_ascii_digit() {
                    if jump_buf.len() < JUMP_BUF_MAX {
                        jump_buf.push(c);
                    }
                    continue;
                }
            }
            if key.code == KeyCode::Enter && !jump_buf.is_empty() {
                if let Ok(n) = jump_buf.parse::<usize>() {
                    if n >= 1 && n <= rows.len() {
                        state.select(Some(n - 1));
                    }
                    // Out of range: no-op, matching "1-9 jump"'s old silent
                    // no-op for an index past the list's end.
                }
                jump_buf.clear();
                continue;
            }
            jump_buf.clear();
            match key.code {
                KeyCode::Up => move_selection(&mut state, rows.len(), -1),
                KeyCode::Down => move_selection(&mut state, rows.len(), 1),
                KeyCode::Enter => {
                    if let Some(i) = state.selected() {
                        if i < rows.len() {
                            return Ok(ListAction::Enter(i));
                        }
                    }
                }
                KeyCode::Char('/') if allow_search => return Ok(ListAction::Search),
                KeyCode::Char('p') | KeyCode::Char('P') if allow_project_toggle => {
                    return Ok(ListAction::ToggleProject)
                }
                _ => {}
            }
        }
    }
}

enum SearchOutcome {
    Cancel,
    Run(String, Box<CatalogItem>),
}

fn search_screen(tui: &mut Tui, catalog: &Catalog, project_line: &str) -> anyhow::Result<SearchOutcome> {
    let mut query = String::new();
    let mut state = ListState::default();
    loop {
        let hits = catalog::search(catalog, &query);
        if hits.is_empty() {
            state.select(None);
        } else {
            let sel = state.selected().unwrap_or(0).min(hits.len() - 1);
            state.select(Some(sel));
        }

        tui.terminal
            .draw(|f| draw_search(f, &query, &hits, &mut state, project_line))?;

        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            if is_cancel_key(key.code, key.modifiers) {
                return Ok(SearchOutcome::Cancel);
            }
            match key.code {
                KeyCode::Enter => {
                    if let Some(i) = state.selected() {
                        if let Some(hit) = hits.get(i) {
                            return Ok(SearchOutcome::Run(
                                hit.folder.to_string(),
                                Box::new(hit.item.clone()),
                            ));
                        }
                    }
                }
                KeyCode::Up => move_selection(&mut state, hits.len(), -1),
                KeyCode::Down => move_selection(&mut state, hits.len(), 1),
                KeyCode::Backspace => {
                    query.pop();
                }
                KeyCode::Char(c) => query.push(c),
                _ => {}
            }
        }
    }
}

fn move_selection(state: &mut ListState, len: usize, delta: i32) {
    if len == 0 {
        state.select(None);
        return;
    }
    let cur = state.selected().unwrap_or(0) as i32;
    let mut next = cur + delta;
    if next < 0 {
        next = len as i32 - 1;
    }
    if next >= len as i32 {
        next = 0;
    }
    state.select(Some(next as usize));
}

fn truncate(text: &str, max_chars: usize) -> String {
    let clean: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if clean.chars().count() <= max_chars {
        return clean;
    }
    let mut truncated: String = clean.chars().take(max_chars.saturating_sub(1)).collect();
    truncated.push('\u{2026}');
    truncated
}

// ==================== drawing ====================

fn shell_layout(area: Rect) -> (Rect, Rect, Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(3), Constraint::Length(1)])
        .split(area);
    (chunks[0], chunks[1], chunks[2])
}

fn render_header(f: &mut Frame<'_>, area: Rect, title: &str, project_line: &str) {
    let header = Paragraph::new(vec![
        Line::from(Span::styled(
            format!("Northstar DevKit \u{2014} {title}"),
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        )),
        Line::from(Span::styled(
            project_line.to_string(),
            Style::default().fg(Color::Green),
        )),
    ]);
    f.render_widget(header, area);
}

fn render_footer(f: &mut Frame<'_>, area: Rect, help: &str) {
    let footer = Paragraph::new(Line::from(Span::styled(
        help.to_string(),
        Style::default().fg(Color::DarkGray),
    )));
    f.render_widget(footer, area);
}

fn draw_list(
    f: &mut Frame<'_>,
    title: &str,
    help: &str,
    rows: &[ListRow],
    state: &mut ListState,
    project_line: &str,
    jump_buf: &str,
) {
    let (header_area, body_area, footer_area) = shell_layout(f.area());
    render_header(f, header_area, title, project_line);

    let items: Vec<ListItem> = rows
        .iter()
        .map(|row| {
            let marker = if row.caution {
                Span::styled("\u{25cf} ", Style::default().fg(Color::Red))
            } else {
                Span::raw("  ")
            };
            let mut spans = vec![
                marker,
                Span::styled(row.primary.clone(), Style::default().add_modifier(Modifier::BOLD)),
            ];
            if let Some(secondary) = &row.secondary {
                spans.push(Span::raw("  \u{2014}  "));
                spans.push(Span::styled(secondary.clone(), Style::default().fg(Color::Gray)));
            }
            ListItem::new(Line::from(spans))
        })
        .collect();

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL))
        .highlight_style(Style::default().bg(Color::Blue).add_modifier(Modifier::BOLD))
        .highlight_symbol("\u{27a4} ");

    f.render_stateful_widget(list, body_area, state);

    if jump_buf.is_empty() {
        render_footer(f, footer_area, help);
    } else {
        // Live echo of the pending jump-to-row buffer, so typing a
        // multi-digit number (e.g. "12") isn't done blind before Enter.
        let footer = Paragraph::new(Line::from(vec![
            Span::styled(help.to_string(), Style::default().fg(Color::DarkGray)),
            Span::raw("   "),
            Span::styled(
                format!("Go to: {jump_buf}\u{2588}"),
                Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
            ),
        ]));
        f.render_widget(footer, footer_area);
    }
}

fn draw_search(
    f: &mut Frame<'_>,
    query: &str,
    hits: &[catalog::SearchHit<'_>],
    state: &mut ListState,
    project_line: &str,
) {
    let (header_area, body_area, footer_area) = shell_layout(f.area());
    render_header(f, header_area, "Search", project_line);

    let inner = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(3)])
        .split(body_area);

    let input = Paragraph::new(Line::from(vec![
        Span::raw("/ "),
        Span::styled(query.to_string(), Style::default().fg(Color::Yellow)),
        Span::styled("\u{2502}", Style::default().fg(Color::DarkGray)),
    ]))
    .block(Block::default().borders(Borders::ALL).title("Query"));
    f.render_widget(input, inner[0]);

    let items: Vec<ListItem> = hits
        .iter()
        .map(|hit| {
            let marker = if hit.item.caution {
                Span::styled("\u{25cf} ", Style::default().fg(Color::Red))
            } else {
                Span::raw("  ")
            };
            let label = format!("[{}] {}", hit.module_name, hit.item.label);
            let help = truncate(&hit.item.help, 70);
            ListItem::new(Line::from(vec![
                marker,
                Span::styled(label, Style::default().add_modifier(Modifier::BOLD)),
                Span::raw("  \u{2014}  "),
                Span::styled(help, Style::default().fg(Color::Gray)),
            ]))
        })
        .collect();

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(format!("Results ({})", hits.len())))
        .highlight_style(Style::default().bg(Color::Blue).add_modifier(Modifier::BOLD))
        .highlight_symbol("\u{27a4} ");
    f.render_stateful_widget(list, inner[1], state);

    render_footer(
        f,
        footer_area,
        "type to filter   \u{2191}/\u{2193} move   Enter run   Esc back",
    );
}

fn draw_text_input(f: &mut Frame<'_>, title: &str, subtitle: &str, buf: &str, project_line: &str) {
    let (header_area, body_area, footer_area) = shell_layout(f.area());
    render_header(f, header_area, title, project_line);

    let text = vec![
        Line::from(Span::styled(subtitle.to_string(), Style::default().fg(Color::White))),
        Line::from(""),
        Line::from(vec![
            Span::raw("> "),
            Span::styled(buf.to_string(), Style::default().fg(Color::Yellow)),
            Span::styled("\u{2502}", Style::default().fg(Color::DarkGray)),
        ]),
    ];
    let paragraph = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL))
        .wrap(Wrap { trim: true });
    f.render_widget(paragraph, body_area);

    render_footer(f, footer_area, "Enter confirm   Esc cancel");
}

fn draw_yesno(f: &mut Frame<'_>, spec: &catalog::ToolPrompt, project_line: &str) {
    let (header_area, body_area, footer_area) = shell_layout(f.area());
    render_header(f, header_area, "Enter Value", project_line);

    let text = vec![
        Line::from(Span::styled(
            format!("{} (y/n)", spec.prompt),
            Style::default().fg(Color::White),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Press y or n",
            Style::default().fg(Color::Yellow),
        )),
    ];
    let paragraph = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL))
        .wrap(Wrap { trim: true });
    f.render_widget(paragraph, body_area);

    render_footer(f, footer_area, "y yes   n/Enter no   Esc cancel");
}

fn draw_message(f: &mut Frame<'_>, title: &str, message: &str, is_error: bool) {
    let area = f.area();
    let color = if is_error { Color::Red } else { Color::Green };
    let paragraph = Paragraph::new(vec![
        Line::from(Span::styled(
            title.to_string(),
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(message.to_string(), Style::default().fg(color))),
        Line::from(""),
        Line::from(Span::styled(
            "Press any key to continue\u{2026}",
            Style::default().fg(Color::DarkGray),
        )),
    ])
    .block(Block::default().borders(Borders::ALL))
    .wrap(Wrap { trim: true });
    f.render_widget(paragraph, area);
}
