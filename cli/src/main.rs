//! `devkit` - terminal entry point for Northstar DevKit.
//!
//! Bare `devkit` opens an interactive ratatui menu driven by the same
//! `catalog.get` payload the GUI uses (arrow-key nav, `/` search, a `p`
//! project switcher - parity with the old `DevKit.ps1` TUI, see
//! `menu.rs`). `devkit catalog` / `devkit doctor` remain one-shot
//! subcommands for scripting/automation.

mod catalog;
mod menu;
mod sidecar_paths;

use clap::{Parser, Subcommand};
use devkit_host::PsHost;

#[derive(Parser)]
#[command(name = "devkit", version, about = "Northstar DevKit CLI")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Print the tool catalog as JSON (same data the GUI renders).
    Catalog,
    /// Check that the PowerShell sidecar starts and responds to a ping.
    Doctor,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Stderr, not the default stdout: `devkit catalog` prints real JSON to
    // stdout meant to be piped/parsed, and the sidecar's forwarded stderr
    // (tracing::warn! from crates/devkit-host) would otherwise interleave
    // with it on the same stream, corrupting it for any consumer stricter
    // than a human eyeballing the terminal.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                // Quiet the forwarded sidecar stderr (WARN) by default: it
                // would print into the ratatui alternate screen and corrupt
                // the menu. RUST_LOG still overrides for debugging.
                .unwrap_or_else(|_| {
                    tracing_subscriber::EnvFilter::new("warn,devkit_sidecar_stderr=error")
                }),
        )
        .init();

    let cli = Cli::parse();
    // The interactive menu draws a ratatui UI: without a real TTY on both
    // stdin and stdout (piped or redirected output) it would scribble
    // alternate-screen escape sequences into the pipe and fail later, deep
    // inside enable_raw_mode, with a cryptic OS error. Gate it here and
    // point at the scriptable subcommands instead. catalog/doctor stay
    // pipe-friendly on purpose.
    if cli.command.is_none() {
        use std::io::IsTerminal;
        if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
            anyhow::bail!(
                "the interactive menu needs a real terminal (stdin/stdout are not TTYs); \
                 try `devkit catalog` or `devkit doctor` for scriptable output"
            );
        }
    }
    let spec = sidecar_paths::resolve()?;
    let host = PsHost::spawn(spec.clone()).await?;

    let run_result = match cli.command {
        Some(Command::Catalog) => {
            let catalog = host.call("catalog.get", None).await?;
            println!("{}", serde_json::to_string_pretty(&catalog)?);
            Ok(())
        }
        Some(Command::Doctor) => {
            let pong = host.call("ping", None).await?;
            println!("sidecar ok: {pong}");
            Ok(())
        }
        None => menu::run(host.clone(), spec.program.clone(), spec.cwd.clone()).await,
    };

    // Best-effort graceful shutdown on BOTH paths: on the error path the
    // old `?` skipped this and leaned on kill_on_drop - which prevents
    // orphans but force-kills the sidecar instead of letting it drain
    // (its own ~7s worst case), cutting off an in-flight tool.run's child.
    let _ = host.shutdown().await;
    run_result
}
