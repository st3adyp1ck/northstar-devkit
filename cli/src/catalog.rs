//! Data model for `catalog.get` plus the argument-building contract that
//! turns a manifest item + collected prompt values into the final argv for
//! the tool's script.
//!
//! The JSON field casing mirrors what `core/RpcMethods.ps1`'s
//! `Get-DevKitCatalogPayload` actually emits (verified against
//! `app/src/lib/types.ts`, whose comment marks it "verified live"):
//! top-level item/module fields are camelCase (written literally as an
//! `[ordered]@{ key = ...; label = ... }` hashtable), but `Prompts` and
//! `RequiresFile` are passed through **unprocessed** from the manifest
//! `.psd1` hashtables, so their own keys stay PascalCase.
//!
//! `build_arguments` is a line-for-line port of `ConvertTo-DevKitToolArguments`
//! (`gui/DevKit-GuiCore.ps1`): project arg via `ProjectArgName`/`Path` when
//! `requiresProject`, `RequiresFile`'s `ParamName` otherwise, prompts in
//! manifest order (Int parsed + range-checked, YesNo only added when true,
//! blank/missing values skipped when `Optional` else an error), then
//! `staticArgs` merged last (updating a same-named key in place rather than
//! moving it, matching PowerShell's ordered-hashtable assignment semantics).

use std::collections::HashMap;

use serde::Deserialize;
use serde_json::{Map, Value};

#[derive(Debug, Clone, Deserialize)]
pub struct ToolPrompt {
    #[serde(rename = "Name")]
    pub name: String,
    #[serde(rename = "Type")]
    pub kind: String, // "Int" | "YesNo" | "String"
    #[serde(rename = "Prompt")]
    pub prompt: String,
    #[serde(rename = "Optional", default)]
    pub optional: bool,
    #[serde(rename = "Min", default)]
    pub min: Option<i64>,
    #[serde(rename = "Max", default)]
    pub max: Option<i64>,
    #[serde(rename = "InvalidMessage", default)]
    pub invalid_message: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RequiresFile {
    // Shown by neither the GUI's own file dialog nor the CLI's native
    // picker (`menu::run_native_file_picker`) - both set the dialog's
    // Title from the item's Label instead, so the user sees why a picker
    // popped up; kept so this struct matches the manifest's RequiresFile
    // shape exactly.
    #[allow(dead_code)]
    #[serde(rename = "Description", default)]
    pub description: Option<String>,
    // Standard Windows Forms file-dialog filter string (e.g. "DevKit
    // backups (*.json)|*.json|All files (*.*)|*.*"), fed straight into the
    // native `OpenFileDialog.Filter` the CLI shells out to - see
    // `menu::run_native_file_picker`.
    #[serde(rename = "Filter", default)]
    pub filter: Option<String>,
    // Only meaningful for a typed-path fallback prompt; the CLI always
    // shows a real native OpenFileDialog instead (see `RequiresFile`
    // handling in `menu::run_tool_flow`), so this is never read here -
    // kept for shape fidelity with the manifest.
    #[allow(dead_code)]
    #[serde(rename = "TypePrompt", default)]
    pub type_prompt: Option<String>,
    #[serde(rename = "ParamName")]
    pub param_name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CatalogItem {
    // The manifest's own per-item number (used by the retired TUI's
    // Start-DevKitModuleTools numbered menu). The CLI navigates a
    // flattened, arrow-driven list instead, so this isn't rendered - kept
    // for parity with the full catalog.get item shape.
    #[allow(dead_code)]
    pub key: String,
    pub label: String,
    pub script: String,
    pub help: String,
    #[serde(default)]
    pub caution: bool,
    #[serde(rename = "requiresProject", default)]
    pub requires_project: bool,
    #[serde(rename = "projectArgName", default)]
    pub project_arg_name: Option<String>,
    #[serde(rename = "requiresFile", default)]
    pub requires_file: Option<RequiresFile>,
    #[serde(default)]
    pub prompts: Option<Vec<ToolPrompt>>,
    #[serde(rename = "staticArgs", default)]
    pub static_args: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CatalogModule {
    pub group: String,
    pub folder: String,
    pub name: String,
    // Module-level blurb (shown as a left-nav tooltip in the GUI); a
    // category screen here mixes items from several modules, so there's
    // no single place to show one module's description - kept for shape
    // fidelity with catalog.get.
    #[allow(dead_code)]
    #[serde(default)]
    pub description: String,
    pub items: Vec<CatalogItem>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Catalog {
    pub modules: Vec<CatalogModule>,
}

/// The distinct `group` values from the catalog's modules, in the order
/// they first appear (matches `Get-DevKitGuiCategories`' ordering without
/// hardcoding it here - the RPC payload is the single source of truth).
pub fn ordered_groups(catalog: &Catalog) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for module in &catalog.modules {
        if seen.insert(module.group.clone()) {
            out.push(module.group.clone());
        }
    }
    out
}

/// Every item belonging to `group`, flattened across that group's modules
/// in module-then-item manifest order. Each entry is `(folder, module
/// name, item)` - `folder` is what a caller joins with `tools/` + the
/// item's own `script` to get the script path to run.
pub fn items_for_group<'a>(
    catalog: &'a Catalog,
    group: &str,
) -> Vec<(&'a str, &'a str, &'a CatalogItem)> {
    let mut out = Vec::new();
    for module in &catalog.modules {
        if module.group == group {
            for item in &module.items {
                out.push((module.folder.as_str(), module.name.as_str(), item));
            }
        }
    }
    out
}

pub struct SearchHit<'a> {
    pub module_name: &'a str,
    pub folder: &'a str,
    pub item: &'a CatalogItem,
}

/// Case-insensitive substring search over every item's module name, label,
/// and help text - mirrors `Search-DevKitGuiTools`' haystack exactly
/// (`"$($module.Name) $($item.Label) $($item.Help)"`, PowerShell `-match`
/// being case-insensitive by default).
pub fn search<'a>(catalog: &'a Catalog, keyword: &str) -> Vec<SearchHit<'a>> {
    if keyword.trim().is_empty() {
        return Vec::new();
    }
    let needle = keyword.to_lowercase();
    let mut out = Vec::new();
    for module in &catalog.modules {
        for item in &module.items {
            let haystack = format!("{} {} {}", module.name, item.label, item.help).to_lowercase();
            if haystack.contains(&needle) {
                out.push(SearchHit {
                    module_name: &module.name,
                    folder: &module.folder,
                    item,
                });
            }
        }
    }
    out
}

/// One collected prompt/project/file value, prior to the
/// `ConvertTo-DevKitToolArguments`-equivalent validation in
/// [`build_arguments`]. `None` means "no value" - matches
/// `Read-DevKitTypedValue` returning `$null` for a blank or invalid entry.
#[derive(Debug, Clone)]
pub enum PromptRawValue {
    None,
    Text(String),
    Bool(bool),
}

#[derive(Debug, Clone, Copy)]
enum ArgValue<'a> {
    Bool(bool),
    Number(&'a str),
    Str(&'a str),
}

/// Ordered-hashtable "set": update the existing entry's value in place
/// (keeping its original position) or append a new one - matches how
/// PowerShell's `$callArgs[$key] = $value` behaves on an `[ordered]`
/// hashtable, which is what lets `staticArgs` "win" over a same-named
/// prompt without reordering the rendered command line.
fn set_arg(ordered: &mut Vec<(String, OwnedArgValue)>, key: String, value: OwnedArgValue) {
    if let Some(entry) = ordered.iter_mut().find(|(k, _)| *k == key) {
        entry.1 = value;
    } else {
        ordered.push((key, value));
    }
}

#[derive(Debug, Clone)]
enum OwnedArgValue {
    Bool(bool),
    Number(String),
    Str(String),
}

impl OwnedArgValue {
    fn as_ref(&self) -> ArgValue<'_> {
        match self {
            OwnedArgValue::Bool(b) => ArgValue::Bool(*b),
            OwnedArgValue::Number(s) => ArgValue::Number(s),
            OwnedArgValue::Str(s) => ArgValue::Str(s),
        }
    }

    fn from_json(value: &Value) -> Self {
        match value {
            Value::Bool(b) => OwnedArgValue::Bool(*b),
            Value::Number(n) => OwnedArgValue::Number(n.to_string()),
            Value::String(s) => OwnedArgValue::Str(s.clone()),
            Value::Null => OwnedArgValue::Bool(false),
            other => OwnedArgValue::Str(other.to_string()),
        }
    }
}

/// Renders the ordered arg list to argv, matching
/// `ConvertTo-DevKitArgumentString`'s rendering rules: `true` becomes a
/// bare `-Key` switch, `false`/omitted values are skipped entirely, and
/// everything else becomes a `-Key`, `value` pair. Unlike the GUI (which
/// builds one shell command-line string for `wt.exe`/conhost and so must
/// quote-escape each value), this returns separate argv entries for direct
/// `std::process::Command` use, which needs no manual quoting.
fn render_args(ordered: &[(String, OwnedArgValue)]) -> Vec<String> {
    let mut out = Vec::new();
    for (key, value) in ordered {
        match value.as_ref() {
            ArgValue::Bool(true) => out.push(format!("-{key}")),
            ArgValue::Bool(false) => {}
            ArgValue::Number(s) => {
                out.push(format!("-{key}"));
                out.push(s.to_string());
            }
            ArgValue::Str(s) => {
                out.push(format!("-{key}"));
                out.push(s.to_string());
            }
        }
    }
    out
}

/// Port of `ConvertTo-DevKitToolArguments`. `values` holds one raw entry
/// per prompt `Name` (collected by the CLI's own input screens), plus - if
/// the caller already resolved them - the project path under
/// `ProjectArgName`/`"Path"` or the file path under `RequiresFile.ParamName`.
/// Returns the final argv, or `Err(message)` matching the PowerShell
/// function's `throw` (an invalid/missing required value).
pub fn build_arguments(
    item: &CatalogItem,
    values: &HashMap<String, PromptRawValue>,
) -> Result<Vec<String>, String> {
    let mut ordered: Vec<(String, OwnedArgValue)> = Vec::new();

    if item.requires_project {
        let arg_name = item
            .project_arg_name
            .as_deref()
            .filter(|s| !s.is_empty())
            .unwrap_or("Path")
            .to_string();
        let text = match values.get(&arg_name) {
            Some(PromptRawValue::Text(s)) if !s.trim().is_empty() => s.clone(),
            _ => {
                return Err(format!(
                    "Missing required project path for '{}'.",
                    item.label
                ))
            }
        };
        set_arg(&mut ordered, arg_name, OwnedArgValue::Str(text));
    } else if let Some(rf) = &item.requires_file {
        let text = match values.get(&rf.param_name) {
            Some(PromptRawValue::Text(s)) if !s.trim().is_empty() => s.clone(),
            _ => return Err(format!("Missing required file for '{}'.", item.label)),
        };
        set_arg(&mut ordered, rf.param_name.clone(), OwnedArgValue::Str(text));
    }

    if let Some(prompts) = &item.prompts {
        for spec in prompts {
            let value = values
                .get(&spec.name)
                .cloned()
                .unwrap_or(PromptRawValue::None);
            let invalid_msg = || {
                spec.invalid_message
                    .clone()
                    .unwrap_or_else(|| format!("Invalid value for {}.", spec.name))
            };

            match spec.kind.as_str() {
                "Int" => {
                    let text = match &value {
                        PromptRawValue::Text(s) if !s.trim().is_empty() => s.trim().to_string(),
                        _ => {
                            if spec.optional {
                                continue;
                            }
                            return Err(invalid_msg());
                        }
                    };
                    let parsed: i64 = text.parse().map_err(|_| invalid_msg())?;
                    if parsed > i32::MAX as i64 || parsed < i32::MIN as i64 {
                        return Err(invalid_msg());
                    }
                    if let Some(min) = spec.min {
                        if parsed < min {
                            return Err(invalid_msg());
                        }
                    }
                    if let Some(max) = spec.max {
                        if parsed > max {
                            return Err(invalid_msg());
                        }
                    }
                    set_arg(
                        &mut ordered,
                        spec.name.clone(),
                        OwnedArgValue::Number(parsed.to_string()),
                    );
                }
                "YesNo" => {
                    // Only ever adds the arg when true - a false answer
                    // means "leave the switch off", matching both
                    // Invoke-DevKitTool and ConvertTo-DevKitToolArguments.
                    if matches!(value, PromptRawValue::Bool(true)) {
                        set_arg(&mut ordered, spec.name.clone(), OwnedArgValue::Bool(true));
                    }
                }
                _ => {
                    let text = match &value {
                        PromptRawValue::Text(s) if !s.trim().is_empty() => Some(s.clone()),
                        _ => None,
                    };
                    match text {
                        Some(t) => set_arg(&mut ordered, spec.name.clone(), OwnedArgValue::Str(t)),
                        None => {
                            if spec.optional {
                                continue;
                            }
                            return Err(invalid_msg());
                        }
                    }
                }
            }
        }
    }

    if let Some(static_args) = &item.static_args {
        for (key, value) in static_args {
            set_arg(&mut ordered, key.clone(), OwnedArgValue::from_json(value));
        }
    }

    Ok(render_args(&ordered))
}

#[derive(Debug, Clone, Deserialize)]
pub struct LinkedProject {
    pub id: String,
    pub name: String,
    pub path: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub pinned: bool,
    // Shown by neither the GUI nor this CLI today; kept so this struct
    // matches Get-DevKitLinkedProjects' full shape.
    #[allow(dead_code)]
    #[serde(rename = "addedUtc", default)]
    pub added_utc: String,
    #[serde(rename = "lastUsedUtc", default)]
    pub last_used_utc: String,
    #[serde(rename = "useCount", default)]
    pub use_count: i64,
    #[serde(rename = "Missing", default)]
    pub missing: bool,
}
