# SOQL Quick

SOQL Quick is a read-only desktop utility for running Salesforce SOQL, browsing object and field metadata, and copying complete result tables into a spreadsheet. Version 2 is a Tauri application for macOS and Windows and does **not** require R, Python, or `salesforcer`.

The original Swift/R implementation is archived under `legacy-salesforcer/` as migration history. The supported application is the standalone Tauri/Rust version.

## Supported systems

- macOS 13 or newer on Apple Silicon
- Windows 10 or 11 on x64

Builds are unsigned. Intel Macs, automatic updates, Apple notarization, and Windows code signing are not included yet.

## Quick start: use SOQL Quick with your own Salesforce org

There is no one-size installer to download. Each build is tied to one org's External Client App: the client ID and login URL are compiled into the app, so you make your own build once and then share that installer with your colleagues. Plan on about 30 minutes.

1. **Create the External Client App** in your org (a Salesforce admin, about 10 minutes). Follow [Salesforce administrator setup](#salesforce-administrator-setup) below, then copy two values: the **consumer key** and your org's **My Domain login URL** (for example `https://acme.my.salesforce.com`). No client secret is involved.
2. **Get the code:**

   ```bash
   git clone https://github.com/elanbw/soql-quick.git
   cd soql-quick
   cp .env.example .env
   ```

3. **Fill in `.env`:** paste the consumer key into `SALESFORCE_CLIENT_ID` and the login URL into `SALESFORCE_LOGIN_URL`. Leave the callback URL and API version as they are unless your admin set them differently.
4. **Build the installer**, choosing one route:
   - **On your own computer.** Install Node.js 20+, Rust (via [rustup](https://rustup.rs)), and [Tauri's prerequisites](https://v2.tauri.app/start/prerequisites/) for your system (Xcode Command Line Tools on macOS; Microsoft C++ Build Tools and WebView2 on Windows). Then run `zsh build-cross-platform.sh` on a Mac or `.\build-windows.ps1` in Windows PowerShell. The scripts read `.env`, run the tests, and write the installer under `src-tauri/target/release/bundle/` (`.dmg` on macOS, `.msi`/`.exe` on Windows). A Mac builds the Mac installer and Windows builds the Windows one.
   - **With GitHub Actions, with no local tools.** Fork this repository. In your fork, open **Settings → Secrets and variables → Actions** and add the secret `SOQL_QUICK_SALESFORCE_CLIENT_ID` (the consumer key) and the variable `SOQL_QUICK_SALESFORCE_LOGIN_URL` (the login URL). On the **Actions** tab, enable workflows, open **SOQL Quick installers**, and choose **Run workflow**. When it finishes, download the macOS and Windows installers from the run's artifacts. Pushing a tag such as `v2.0.5` also publishes them on a prerelease.
5. **Install and connect.** Follow [INSTALL.md](INSTALL.md). The first launch warns because builds are unsigned. Choose **Connect Salesforce** and approve access in the browser.
6. **Share it.** Give colleagues the installer and `INSTALL.md`. Each person needs access to the External Client App, usually through a permission set.

To run the app in development mode against your org, load `.env` first, because `npm run dev` doesn't read it on its own:

```bash
set -a; source .env; set +a
npm install
npm run dev
```

## Salesforce administrator setup

SOQL Quick uses OAuth Authorization Code with PKCE. It never embeds a client secret or asks the user to enter a Salesforce password into the app.

1. In Salesforce Setup, create an **External Client App** for your org.
2. Enable OAuth and the Authorization Code flow.
3. Set the callback URL exactly to `http://localhost:1410/callback`.
4. Require PKCE using SHA-256.
5. Add these OAuth scopes:
   - `api` — Manage user data via APIs
   - `refresh_token` / `offline_access` — Perform requests at any time
6. Configure permitted users according to your org’s policy, normally administrator-approved users assigned through a permission set.
7. Record the consumer key (OAuth client ID) and your org’s My Domain login URL. No client secret is used or distributed.

Salesforce can take several minutes to activate new OAuth configuration. If port 1410 is already occupied on a user’s computer, quit old SOQL Quick/R login processes and retry.

## Configure a build

Copy `.env.example` to `.env` and set:

```text
SALESFORCE_CLIENT_ID=the_external_client_app_consumer_key
SALESFORCE_LOGIN_URL=https://your-domain.my.salesforce.com
SALESFORCE_CALLBACK_URL=http://localhost:1410/callback
SALESFORCE_API_VERSION=66.0
```

`.env` is ignored by Git. The client ID is a public OAuth identifier, not a client secret, but keeping org-specific configuration out of source control is the safer default.

## Local development and tests

Prerequisites:

- Node.js 20 or newer
- Rust 1.77.2 or newer
- Tauri’s macOS or Windows system prerequisites

```bash
npm install
npm run check
npm run dev
```

Tests use synthetic JSON and strings only. They do not connect to Salesforce. Codex must not run a live record-level Salesforce query; the user performs that final smoke test locally.

## Build installers

On macOS:

```bash
zsh build-cross-platform.sh
```

On Windows PowerShell:

```powershell
.\build-windows.ps1
```

Outputs are written under `src-tauri/target/release/bundle/`. A Mac build creates the macOS app/DMG; a Windows build creates MSI and NSIS installers. Windows installers must be built and tested on Windows.

The repository workflow `.github/workflows/installers.yml` builds both native artifacts manually and publishes prereleases from tags matching `v*`. Configure these repository settings first:

- Secret `SOQL_QUICK_SALESFORCE_CLIENT_ID`
- Variable `SOQL_QUICK_SALESFORCE_LOGIN_URL`

Ordinary workflow artifacts are retained for 14 days. Tagged builds publish the friendly Windows `.exe` and macOS `.dmg` as permanent assets on a GitHub prerelease after both native builds succeed. End-user install instructions are in `INSTALL.md`.

## Installing an unsigned build

macOS Gatekeeper will warn because the DMG is not signed or notarized. After confirming the file came from a trusted source:

1. Drag **SOQL Quick.app** into **Applications**.
2. Control-click the installed application, choose **Open**, and confirm **Open**.

If macOS instead reports that **“SOQL Quick” is damaged and can't be opened**, remove the download quarantine attribute from this application only:

```bash
xattr -dr com.apple.quarantine "/Applications/SOQL Quick.app"
```

Then open SOQL Quick normally. Only use this workaround for a build obtained from a trusted source. Do not disable Gatekeeper globally.

Windows SmartScreen can warn that the publisher is unknown. After confirming the installer came from a trusted source, choose **More info**, verify the filename, then **Run anyway**. Do not disable SmartScreen globally.

## Security and data handling

- The Rust command boundary exposes login/logout, SOQL query, cancellation, object listing, and object describe operations only.
- Queries must begin with `SELECT`; no create, update, delete, Tooling API, or arbitrary REST command exists.
- Query text and results remain in memory and are discarded when the app closes.
- Refresh credentials are stored in macOS Keychain or Windows Credential Manager.
- Schema metadata and preferences are cached in the WebView’s platform application-data storage; schema entries expire after 24 hours.
- Complete result copying protects text cells beginning with `=`, `+`, `-`, or `@` against spreadsheet formula execution.
- Error messages redact common credential fields and are limited to 4,000 characters.

## User shortcuts

- Run query: Command–Return on macOS; Control–Return on Windows
- Show completions: Control–Space
- Toggle schema browser: Command/Control–Option/Alt–B
- Show/focus the app globally: Control–Option/Alt–S by default, configurable in Settings

## Troubleshooting

- **Build says no Salesforce client ID:** create `.env` or configure the CI secret.
- **Login callback port is in use:** quit older SOQL Quick or R OAuth processes, then retry.
- **No refresh token:** confirm `refresh_token`/`offline_access` is allowed and the user is permitted for the External Client App.
- **Session expired:** choose Reconnect and authorize again.
- **Cached schema is stale:** use the refresh button in the schema browser.
- **Query timeout:** narrow the query or add filters; requests time out after 120 seconds.
- **Private results:** never paste private query results into an AI chat or commit them to this repository.

## License

MIT. See [LICENSE](LICENSE).
