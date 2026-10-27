# Installing SOQL Quick

SOQL Quick is a read-only Salesforce query utility. Builds are unsigned, so the operating system will warn on first install.

## System requirements

- Windows 10 or 11 on an x64 PC
- macOS 13 or newer on an Apple-silicon Mac
- A build of SOQL Quick configured for your Salesforce org (see the README)
- A Salesforce account permitted to use the SOQL Quick External Client App

Intel Macs are not supported by this release.

## Download and install

Download the file for your computer from the release page, where `<version>` is the release number:

- Windows: `SOQL-Quick-Setup-<version>-Windows-x64.exe`
- Mac: `SOQL-Quick-<version>-macOS-arm64.dmg`

### Windows

1. Run the downloaded `.exe` installer.
2. Because this build is unsigned, Microsoft Defender SmartScreen may say the publisher is unknown. Confirm that the file came from the release you expected, choose **More info**, and then choose **Run anyway** if your organization’s policy permits.
3. Do not disable SmartScreen globally. If your organization’s policy blocks installation, contact your IT team.

### Mac

1. Open the downloaded `.dmg` and install SOQL Quick.
2. Because this build is not notarized, macOS may block the first launch. Confirm that the file came from the release you expected, Control-click SOQL Quick, choose **Open**, and confirm **Open**.
3. Do not disable Gatekeeper globally. If your organization’s policy blocks installation, contact your IT team.

## First connection

1. Open SOQL Quick and choose **Connect Salesforce**.
2. Complete the Salesforce authorization in your browser using your Salesforce account.
3. Return to SOQL Quick after Salesforce confirms access.

SOQL Quick stores its refresh credential in Windows Credential Manager or macOS Keychain. It never asks you to type your Salesforce password into the app.

## Basics

- Run a query: **Control–Return** on Windows or **Command–Return** on Mac
- Show autocomplete: **Control–Space**
- Toggle the schema browser: **Control–Alt–B** on Windows or **Command–Option–B** on Mac
- Show or focus SOQL Quick globally: **Control–Alt–S** by default
- Use **Copy Table** to paste complete results into a spreadsheet

The app accepts `SELECT` queries only and does not provide create, update, or delete operations.

## Troubleshooting and safe use

- If the login callback port is busy, close older SOQL Quick or Salesforce login processes and try again.
- If the session expires, choose **Reconnect**.
- If schema information appears stale, refresh the schema browser.
- If a query times out, narrow it or add filters.
- Never paste query results containing private data into AI chats, commit them to Git, or share them outside systems your organization approves.
