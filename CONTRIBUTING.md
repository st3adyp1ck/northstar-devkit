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

- **Language**: All scripts are PowerShell. Target PowerShell 5.1+ compatibility.
- **Style**: Follow the existing script structure in `AGENTS.md`.
- **Shared helpers**: Dot-source `lib/DevKit-Common.ps1` for common tasks (path validation, safe `node_modules` deletion, package-manager detection, banners, etc.).
- **No new dependencies**: DevKit is meant to be dependency-free and use built-in Windows tools.
- **Menu integration**: If you add a new tool, update `DevKit.ps1` and add a `.bat` wrapper.
- **Single source of truth**: Avoid duplicating logic between `DevKit.ps1` and standalone scripts. The menu should call the standalone script whenever possible.

## Code of Conduct

This project adheres to a standard of respectful, constructive communication. Be kind, be patient, and help others learn.

## Questions?

Visit [northstarcoding.com](https://www.northstarcoding.com) or open a GitHub Discussion.
