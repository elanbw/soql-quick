# SOQL Quick Change Requests

Use this document as a lightweight inbox for proposed SOQL Quick changes. Record
requests here without implementing them immediately. Add technical design and
acceptance criteria when a request moves from `New` or `Clarify` to `Ready`.

## Request Inbox

Priority values: `High`, `Medium`, `Low`

Status values: `New`, `Clarify`, `Ready`, `Implemented`, `Declined`

| ID       | Change request                                | Priority | Status      | Notes                                                                                                                                                                                                                                                                                                             |
| -------- | --------------------------------------------- | -------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SOQL-001 | Copy field label                              | Medium   | Implemented | Added a "Copy Field Label" action beside "Copy API Name" in version 2.0.1.                                                                                                                                                                                                                                        |
| SOQL-002 | Move autocomplete popup                       | Medium   | Implemented | Autocomplete now opens below the active caret line and stays within the viewport in version 2.0.1.                                                                                                                                                                                                                |
| SOQL-003 | Turn IDs into hyperlinks to SF record         | Medium   | Implemented | Result values matching valid 15- or 18-character Salesforce IDs open the record on the authenticated Salesforce instance in version 2.0.3.                                                                                                                                                                        |
| SOQL-004 | Fix column order and NULL columns             | Medium   | Implemented | Common queries now follow SELECT-list order and retain fully null columns; advanced projections retain the server-derived fallback behavior in version 2.0.3.                                                                                                                                                     |
| SOQL-005 | Context-derived auto-complete menu for fields | Medium   | Implemented | Field suggestions are loaded from the main object in the query's `FROM` clause, independently of the schema-browser selection, in version 2.0.4.                                                                                                                                                                  |
| SOQL-006 | Pin top 3 objects to schema browser | Medium | Implemented | Implemented in 2.0.4 as hard pinning of the three most recent objects; replaced by usage-weighted relevance ranking in SOQL-013. |
| SOQL-007 | Option to remove objects from browser         | Medium   | Implemented | A default-on browser-only filter systematically hides managed-package, support, rules-engine, automation, setup, access, and metadata object families, with administrative label-prefix fallbacks, in version 2.0.4.                                                                                                |
| SOQL-008 | Enabled auto-complete for lookup references   | Medium   | Implemented | Field autocomplete resolves unambiguous multi-level lookup paths from relationship metadata; polymorphic relationships are intentionally skipped in version 2.0.4.                                                                                                                                               |
| SOQL-009 | Open results in a new Google Sheet | Medium | Implemented | A "Google Sheet" toolbar button copies the full result table as TSV and opens `https://sheet.new` in the default browser for pasting. The URL is fixed in Rust; no Google sign-in or upload happens in the app. |
| SOQL-010 | Fewer Keychain password prompts | Medium | Implemented | The refresh credential is read from the OS credential store at most once per launch and cached in memory; unchanged writes and empty deletes are skipped, and only a real token rejection deletes it. New unsigned builds should prompt once (choose "Always Allow"). |
| SOQL-011 | Accept autocomplete with Tab only | Medium | Implemented | Enter closes the suggestion panel and inserts a newline; Cmd/Ctrl+Enter still runs the query. |
| SOQL-012 | No dictionary-word suggestions | Medium | Implemented | Disabled OS/WebView inline predictions, autocorrect, autocomplete, and autocapitalize on the editor and schema searches. The app's own list only offers schema names and SOQL terms. |
| SOQL-013 | Smart suggestion ranking | Medium | Implemented | Cardinal-style ranking for autocomplete and schema searches: match tiers (exact, prefix, word-segment, initials, substring, fuzzy) across API names and labels, plus a capped frecency boost from object usage. Empty object search shows up to 5 frequently used objects, then alphabetical. |
| SOQL-014 | Fix clause order before running | Medium | Implemented | Top-level clauses typed out of order (for example FROM before SELECT) are reordered into SOQL order in the editor before the query runs. Duplicate clauses and other errors are left unchanged. |

### New Request Template

Copy this row into the Request Inbox and replace each placeholder:

```markdown
| SOQL-001 | Brief description of the requested change | Medium | New | Relevant context or open questions |
```

Use the next available sequential ID. Keep the request description focused on
the desired behavior; use Notes for context, dependencies, or unresolved details.

## Bulk Implementation

Complete this section when selecting requests for a shared implementation pass.

- **Batch:** SOQL Quick 2.0.4 schema and autocomplete improvements
- **Selected request IDs:** SOQL-005, SOQL-006, SOQL-007, SOQL-008
- **Shared constraints:** Preserve read-only Salesforce access, keep query text/results in memory, persist only preferences and recent object API names, and keep hidden objects available to explicit query autocomplete.
- **Verification notes:** Synthetic frontend tests cover query-object parsing, relationship resolution, managed-package/system-object classification, and recent-object ordering. Rust tests continue to cover the read-only command boundary and result processing. Live Salesforce smoke testing remains user-owned.
