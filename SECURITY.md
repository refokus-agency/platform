# Security Policy

## Supported Versions

This repo's reusable workflows are referenced by callers via ref. The supported pin is `@v1` (the floating major tag); `@main` is supported as the bleeding-edge development line. We support the latest release on each major line.

| Version  | Supported |
| -------- | --------- |
| `@v1`    | Yes — latest v1.x release (recommended for consumers) |
| `@main`  | Yes — current development line |
| `< v1`   | N/A — no pre-v1 releases shipped |

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Please use GitHub's Private Vulnerability Reporting:
https://github.com/refokus-agency/platform/security/advisories/new

See GitHub's docs for the flow: https://docs.github.com/en/code-security/security-advisories

Expected response: within 5 business days.

## Scope

Relevant concerns for this repo include:

- Secrets being printed in logs by the reusable workflows
- Misuse of `pull_request_target` or similar elevated-permission triggers
- Supply chain issues in the third-party actions we pin
- Logic that would let a caller repo gain access to secrets it shouldn't

Issues outside this scope (e.g., a vulnerability in a consumer app that happens to use these workflows) should be reported to that project.
