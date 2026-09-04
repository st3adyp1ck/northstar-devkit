# Contributing to Northstar DevKit

First off, thanks for taking the time to contribute! 🎉

## How Can I Contribute?

### Reporting Bugs

- Check if the bug has already been reported in [Issues](https://github.com/st3adyp1ck/northstar-devkit/issues).
- If not, open a new issue and use the **Bug Report** template.
- Include your PowerShell version, Windows version, and steps to reproduce.

### Suggesting Features

- Open a new issue and use the **Feature Request** template.
- Explain the use case and why it would help other developers.

### Pull Requests

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-feature`.
3. Make your changes.
4. Test your changes on both **PowerShell 7** and **Windows PowerShell 5.1** if possible.
5. Commit with a clear message.
6. Push and open a Pull Request.

## Development Guidelines

- **Language**: The tool scripts under `tools/` are all PowerShell. Target PowerShell 5.1+ compatibility. The desktop app (`app/`) is Rust + TypeScript/React (Tauri v2); the terminal menu (`cli/`) and the RPC sidecar host (`crates/devkit-host`) are Rust.
- **Style**: Follow the existing script structure in `AGENTS.md`.
- **Shared helpers**: Dot-source `tools/lib/DevKit-Common.ps1` for common tasks (path validation, safe `node_modules` deletion, package-manager detection, banners, etc.).
- **No new dependencies for tools**: The PowerShell tool scripts are meant to be dependency-free and use built-in Windows tools.
- **Menu integration**: Adding a tool to an **existing** category (`ports/`, `node/`, etc.) means adding the script, a `.bat` wrapper, and an entry in that category's `_module.psd1` (see `AGENTS.md`'s "Adding New Tools" for the schema). That manifest is the single source of truth for the tool catalog - there's no `DevKit.ps1` menu to edit any more. Both the CLI (`cli/`) and the desktop app's Control Center (`app/`) discover tools the same way: they call the `catalog.get` RPC method (handled in `core/RpcMethods.ps1`, which reads every `tools/*/_module.psd1` at request time), so a manifest edit shows up in both front ends automatically with no other code changes. A brand-new top-level category needs a couple of registration lines beyond the manifest - see `AGENTS.md`'s "Adding a new module category".
- **Single source of truth**: Avoid duplicating tool logic. `cli/` and `app/` are thin front ends over the same `tools/*.ps1` scripts (invoked via RPC through `core/RpcMethods.ps1`) - put real logic in the script, not in the Rust or TypeScript layers.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md) v2.1. Be kind, be patient, and help others learn.

## Security

Please don't report vulnerabilities through public issues or pull requests - see [SECURITY.md](SECURITY.md) for the private reporting path.

## Questions?

Open a [Discussion](https://github.com/st3adyp1ck/northstar-devkit/discussions), or email [thesage@northstarcoding.com](mailto:thesage@northstarcoding.com). More at [northstarcoding.com](https://www.northstarcoding.com).
