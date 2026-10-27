# SOQL Quick Agent Instructions

## Scope

This repository contains the SOQL Quick desktop application. Keep application changes, installer automation, release documentation, and tests within this repository.

## Security and privacy

- Never commit or display `.env`, credentials, OAuth tokens, Salesforce record data, query results, customer data, or employee data.
- Treat the Salesforce login URL and OAuth client ID as private build configuration even though the client ID is not a client secret.
- Do not run live Salesforce record queries. Use synthetic fixtures for automated tests and leave final live-query smoke testing to the user.
- Preserve the read-only boundary: accepted queries begin with `SELECT`, and the application must not add create, update, delete, Tooling API, or arbitrary REST operations without explicit authorization.
- Keep refresh credentials in macOS Keychain or Windows Credential Manager and keep query text/results in memory only.

## Validation

- Run `npm test` for frontend logic.
- Run `npm run check` when Rust is available; this includes JavaScript and Rust tests.
- Build Windows installers on Windows and macOS installers on macOS, normally through `.github/workflows/installers.yml`.
- Never expose private build configuration in logs, artifacts, release notes, or chat.
