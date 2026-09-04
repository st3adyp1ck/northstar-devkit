# Security Policy

## Supported versions

Northstar DevKit ships a single supported line. Only the latest release receives
security fixes; the in-app updater installs it automatically within 24 hours.

| Version | Supported |
| ------- | --------- |
| 4.4.x   | Yes |
| < 4.4   | No — update via the installer or **Check for Updates** in the widget |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Preferred: use GitHub's private reporting —
[Report a vulnerability](https://github.com/st3adyp1ck/northstar-devkit/security/advisories/new).

Alternatively, email [thesage@northstarcoding.com](mailto:thesage@northstarcoding.com) with `[SECURITY]` in the subject.

Please include the affected version, your Windows build, reproduction steps, and the
impact you believe it has. We will acknowledge within **3 business days**, give you an
assessment and a target fix window within **10 business days**, and credit you in the
release notes unless you ask us not to.

## Scope

In scope:

- The NSIS installer and the minisign-signed update feed (`latest.json`)
- The PowerShell RPC sidecar (`core/Invoke-DevKitRpc.ps1`) and its method dispatch
- Any tool under `tools/` that elevates, edits the system PATH or environment, or
  writes outside `%LOCALAPPDATA%\NorthstarDevKit\`
- The Tauri desktop app and the `devkit` CLI

Out of scope:

- Issues that require an attacker to already hold administrator rights on the machine
- Vulnerabilities in third-party tools DevKit merely launches (Node, Docker, `gh`, git)
- Findings from automated scanners with no demonstrated exploit path

## Data handling

DevKit runs entirely on your machine. It stores linked projects and settings under
`%LOCALAPPDATA%\NorthstarDevKit\` and sends no telemetry. Its only outbound network
calls are the GitHub requests described under "What it touches" in the README.
