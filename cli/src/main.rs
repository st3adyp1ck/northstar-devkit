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
    let spec = sidecar_paths::resolve()?;
    let host = PsHost::spawn(spec.clone()).await?;

    match cli.command {
        Some(Command::Catalog) => {
            let catalog = host.call("catalog.get", None).await?;
            println!("{}", serde_json::to_string_pretty(&catalog)?);
        }
        Some(Command::Doctor) => {
            let pong = host.call("ping", None).await?;
            println!("sidecar ok: {pong}");
        }
        None => {
            menu::run(host.clone(), spec.program.clone(), spec.cwd.clone()).await?;
        }
    }

    host.shutdown().await;
    Ok(())
}
