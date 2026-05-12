# Security Policy

## Supported versions

Only the latest released version of voxline is supported. Please update before reporting issues.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** via GitHub's
[Private Vulnerability Reporting](https://github.com/tfredricks/voxline/security/advisories/new).

Do **not** open a public issue for security reports.

We aim to acknowledge reports within 7 days and to provide a remediation plan within 30 days, where the issue is reproducible and in scope.

## Scope

voxline is a macOS dictation app. We are particularly interested in:

- Issues that could leak audio, transcripts, or API keys held by the app.
- Privilege-escalation paths through the Accessibility or Input Monitoring permissions voxline requests.
- Bypasses of the user's configured privacy settings (dictation history, model provider, what is sent to external APIs).
- Issues in the local build / install scripts that could be exploited on a developer machine.

Out of scope:

- Vulnerabilities in upstream dependencies (WhisperKit, Apple frameworks, third-party LLM providers) without a voxline-specific exploit path. Please report those to the upstream project.
- Self-inflicted misconfiguration (e.g., committing your own API key to a public repo).
