import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { register, unregisterAll } from "@tauri-apps/plugin-global-shortcut";
import { PREVIEW_LIMIT, cacheRead, cacheWrite, completionContext, completionItems, completionPanelPosition, formatTsv, isHiddenSchemaObject, isSalesforceRecordId, mainQueryObject, rankSchemaItems, recordUsage, reorderSoqlClauses, resolveRelationshipFields } from "./core.js";

const $ = id => document.getElementById(id);
const editor = $("queryEditor");
const OBJECT_USAGE_KEY = "objectUsage:v1";
const LEGACY_RECENT_OBJECTS_KEY = "recentObjects:v1";
const HIDE_SYSTEM_OBJECTS_KEY = "hideSystemObjects";
const state = { connected: false, connecting: false, running: false, objects: [], fields: [], fieldMetadata: new Map(), fieldRequests: new Map(), objectUsage: readObjectUsage(), selectedField: null, result: null, completion: { items: [], index: 0, context: null, requestId: 0 }, lastError: "" };

function readObjectUsage() {
  try {
    const value = JSON.parse(localStorage.getItem(OBJECT_USAGE_KEY));
    if (value && typeof value === "object" && !Array.isArray(value)) return Object.fromEntries(Object.entries(value).filter(([, entry]) => Number.isFinite(entry?.count) && Number.isFinite(entry?.lastUsed)));
  } catch { /* fall through to the legacy recent list */ }
  try {
    const legacy = JSON.parse(localStorage.getItem(LEGACY_RECENT_OBJECTS_KEY));
    const now = Date.now();
    const names = Array.isArray(legacy) ? legacy.filter(item => typeof item === "string").reverse() : [];
    return names.reduce((usage, name, index) => recordUsage(usage, name, now - (names.length - index)), {});
  } catch { return {}; }
}

function hideSystemObjects() { return localStorage.getItem(HIDE_SYSTEM_OBJECTS_KEY) !== "false"; }
// Running a query is the strongest "this is what I wanted" signal, so it counts double (like Cardinal's own opens).
function recordObjectUse(apiName, weight = 1) {
  if (!apiName) return;
  state.objectUsage = recordUsage(state.objectUsage, apiName, Date.now(), weight);
  try { localStorage.setItem(OBJECT_USAGE_KEY, JSON.stringify(state.objectUsage)); } catch { /* usage ranking is a convenience */ }
  renderObjects();
}

function setStatus(message, error = false) {
  state.lastError = error ? String(message) : "";
  $("statusText").textContent = String(message).replaceAll("\n", " ");
  $("statusText").title = String(message);
  $("statusText").classList.toggle("error", error);
  $("detailsButton").classList.toggle("hidden", !error);
}

function setConnected(status) {
  state.connected = status.connected;
  const label = status.connected ? `Connected${status.username ? ` as ${status.username}` : ""}` : "Not connected";
  $("connectionBadge").textContent = label;
  $("connectionBadge").className = `badge ${status.connected ? "connected" : "disconnected"}`;
  $("connectButton").textContent = status.connected ? "Reconnect" : "Connect Salesforce";
  $("signOutButton").classList.toggle("hidden", !status.connected);
  $("runButton").disabled = !status.connected || state.running;
  if (status.connected && state.objects.length === 0) loadObjects(false);
}

async function restoreConnection() {
  try { setConnected(await invoke("restore_session")); }
  catch (error) { setConnected({ connected: false }); setStatus(error, true); }
}

async function connect() {
  state.connecting = true;
  $("connectButton").disabled = false;
  $("connectButton").textContent = "Cancel connection";
  setStatus("Opening Salesforce login in your browser…");
  try {
    setConnected(await invoke("connect_salesforce"));
    setStatus("Salesforce connected.");
    await loadObjects(true);
  } catch (error) { setStatus(error, true); }
  finally { state.connecting = false; $("connectButton").disabled = false; $("connectButton").textContent = state.connected ? "Reconnect" : "Connect Salesforce"; }
}

async function connectOrCancel() {
  if (!state.connecting) return connect();
  $("connectButton").disabled = true;
  try { await invoke("cancel_connection"); setStatus("Salesforce connection cancelled."); }
  catch (error) { setStatus(error, true); }
}

async function signOut() {
  try { await invoke("sign_out"); setConnected({ connected: false }); setStatus("Signed out. Local credentials were removed."); }
  catch (error) { setStatus(error, true); }
}

function setRunning(value) {
  state.running = value;
  $("runButton").disabled = value || !state.connected;
  $("cancelButton").disabled = !value;
  $("spinner").classList.toggle("hidden", !value);
}

// Replaces the whole editor text; execCommand keeps the change on the native undo stack where supported.
function replaceEditorText(text) {
  editor.focus(); editor.select();
  let inserted = false;
  try { inserted = document.execCommand("insertText", false, text); } catch { inserted = false; }
  if (!inserted || editor.value !== text) editor.setRangeText(text, 0, editor.value.length, "end");
}

async function runQuery() {
  const typed = editor.value.trim();
  if (!typed) return setStatus("Enter a SOQL query before running it.", true);
  const query = reorderSoqlClauses(typed);
  const reordered = query !== typed;
  if (reordered) replaceEditorText(query);
  recordObjectUse(mainQueryObject(query), 2);
  closeCompletions(); setRunning(true); setStatus(reordered ? "Clause order fixed. Running query…" : "Running query…");
  try {
    const result = await invoke("run_query", { query });
    state.result = result; renderResults(result);
    setStatus(`${reordered ? "Clause order fixed. " : ""}Query completed. ${result.total.toLocaleString()} row${result.total === 1 ? "" : "s"}.`);
  } catch (error) { setStatus(error, true); }
  finally { setRunning(false); }
}

async function cancelQuery() {
  try { await invoke("cancel_query"); setStatus("Query cancelled."); }
  catch (error) { setStatus(error, true); }
}

function renderResults(result) {
  const head = $("resultsTable").querySelector("thead"), body = $("resultsTable").querySelector("tbody");
  head.replaceChildren(); body.replaceChildren();
  if (result.columns.length) {
    const tr = document.createElement("tr");
    for (const column of result.columns) { const th = document.createElement("th"); th.textContent = column; th.title = column; tr.append(th); }
    head.append(tr);
  }
  const preview = result.rows.slice(0, PREVIEW_LIMIT);
  if (!preview.length) { const tr = document.createElement("tr"), td = document.createElement("td"); td.className = "empty-state"; td.textContent = "The query returned no rows."; td.colSpan = Math.max(1, result.columns.length); tr.append(td); body.append(tr); }
  for (const row of preview) {
    const tr = document.createElement("tr");
    result.columns.forEach((_, index) => {
      const td = document.createElement("td"), value = row[index] ?? "";
      td.title = value;
      if (isSalesforceRecordId(value)) {
        const link = document.createElement("a"); link.href = "#"; link.className = "record-link"; link.textContent = value; link.title = `Open Salesforce record ${value}`;
        link.addEventListener("click", async event => { event.preventDefault(); try { await invoke("open_record", { recordId: value }); } catch (error) { setStatus(error, true); } });
        td.append(link);
      } else td.textContent = value;
      tr.append(td);
    });
    body.append(tr);
  }
  $("countText").textContent = result.total > PREVIEW_LIMIT ? `Showing ${PREVIEW_LIMIT} of ${result.total.toLocaleString()}` : `${result.total.toLocaleString()} row${result.total === 1 ? "" : "s"}`;
  $("copyButton").disabled = !result.columns.length;
  $("sheetButton").disabled = !result.columns.length;
}

async function copyTable() {
  if (!state.result) return;
  await navigator.clipboard.writeText(formatTsv(state.result.columns, state.result.textColumns, state.result.rows));
  setStatus(`Copied ${state.result.total.toLocaleString()} row${state.result.total === 1 ? "" : "s"} to the clipboard.`);
}

async function openInGoogleSheet() {
  if (!state.result) return;
  try {
    await navigator.clipboard.writeText(formatTsv(state.result.columns, state.result.textColumns, state.result.rows));
    await invoke("open_new_google_sheet");
    setStatus(`Copied ${state.result.total.toLocaleString()} row${state.result.total === 1 ? "" : "s"}. Paste into the new Google Sheet with ${navigator.platform.startsWith("Mac") ? "⌘V" : "Ctrl+V"}.`);
  } catch (error) { setStatus(error, true); }
}

function objectCacheKey() { return "schema:objects:v1"; }
function fieldCacheKey(object) { return `schema:fields:v1:${object}`; }

async function loadObjects(force) {
  const cached = !force && cacheRead(objectCacheKey());
  if (cached) { state.objects = cached; renderObjects(); $("schemaStatus").textContent = `${cached.length} cached objects`; }
  try {
    $("schemaStatus").textContent = "Loading objects…";
    const objects = await invoke("list_objects");
    state.objects = objects; cacheWrite(objectCacheKey(), objects); renderObjects();
    $("schemaStatus").textContent = `${objects.length} objects`;
  } catch (error) {
    $("schemaStatus").textContent = cached ? "Refresh failed; using cache" : "Schema unavailable";
    if (!cached) setStatus(error, true);
  }
}

function renderObjects() {
  const query = $("objectSearch").value, selected = $("objectList").value;
  const objects = rankSchemaItems(state.objects.filter(item => !hideSystemObjects() || !isHiddenSchemaObject(item)), query, state.objectUsage);
  $("objectList").replaceChildren(...objects.map(item => { const option = document.createElement("option"); option.value = item.apiName; option.textContent = `${item.label} — ${item.apiName}`; option.title = item.apiName; return option; }));
  if (objects.some(item => item.apiName === selected)) $("objectList").value = selected;
}

async function selectObject() {
  const object = $("objectList").value;
  if (!object) return;
  recordObjectUse(object);
  $("fieldSearch").disabled = false; state.selectedField = null; updateFieldButtons();
  const cached = cacheRead(fieldCacheKey(object));
  if (cached) { state.fields = cached; renderFields(); $("schemaStatus").textContent = `${cached.length} cached fields`; }
  try {
    $("schemaStatus").textContent = `Loading ${object} fields…`;
    const fields = await requestFields(object, true);
    if ($("objectList").value !== object) return;
    state.fields = fields; cacheWrite(fieldCacheKey(object), fields); renderFields(); $("schemaStatus").textContent = `${fields.length} fields`;
  } catch (error) { $("schemaStatus").textContent = cached ? "Refresh failed; using cache" : "Fields unavailable"; if (!cached) setStatus(error, true); }
}

function cachedFields(object) {
  if (!object) return null;
  const key = object.toLowerCase();
  if (state.fieldMetadata.has(key)) return state.fieldMetadata.get(key);
  const cached = cacheRead(fieldCacheKey(object));
  if (cached) state.fieldMetadata.set(key, cached);
  return cached;
}

async function requestFields(object, force = false) {
  const key = object.toLowerCase();
  if (!force) { const cached = cachedFields(object); if (cached) return cached; }
  if (state.fieldRequests.has(key)) return state.fieldRequests.get(key);
  const request = invoke("describe_object", { objectApiName: object }).then(fields => {
    state.fieldMetadata.set(key, fields); cacheWrite(fieldCacheKey(object), fields); return fields;
  }).finally(() => state.fieldRequests.delete(key));
  state.fieldRequests.set(key, request);
  return request;
}

async function fieldsForCompletion(context) {
  if (context.schemaKind !== "field" || !context.objectName) return [];
  return resolveRelationshipFields(context.objectName, context.relationshipPath, requestFields);
}

function renderFields() {
  const fields = rankSchemaItems(state.fields, $("fieldSearch").value);
  $("fieldList").replaceChildren(...fields.map(item => {
    const row = document.createElement("div"); row.className = "field-row"; row.dataset.apiName = item.apiName; row.title = `${item.apiName}\nType: ${item.type}\nFilterable: ${item.filterable}\nSortable: ${item.sortable}\nRelationship: ${item.relationshipName ?? "None"}`;
    const name = document.createElement("strong"), detail = document.createElement("small"); name.textContent = `${item.label} — ${item.apiName}`; detail.textContent = [item.type, item.calculated ? "formula" : "", item.nillable ? "" : "required", item.referenceTo.length ? `→ ${item.referenceTo.join(", ")}` : ""].filter(Boolean).join(" • "); row.append(name, detail);
    row.addEventListener("click", () => selectField(item, row)); row.addEventListener("dblclick", insertSelectedField); return row;
  }));
}

function selectField(field, row) { state.selectedField = field; document.querySelectorAll(".field-row.selected").forEach(item => item.classList.remove("selected")); row.classList.add("selected"); updateFieldButtons(); }
function updateFieldButtons() { const disabled = !state.selectedField; $("insertFieldButton").disabled = disabled; $("copyFieldButton").disabled = disabled; $("copyFieldLabelButton").disabled = disabled; }
function insertSelectedField() { if (!state.selectedField) return; const start = editor.selectionStart, end = editor.selectionEnd; editor.setRangeText(state.selectedField.apiName, start, end, "end"); editor.focus(); }

function textareaCaretRect(textarea) {
  const mirror = document.createElement("div");
  const marker = document.createElement("span");
  const style = getComputedStyle(textarea);
  const rect = textarea.getBoundingClientRect();
  const copiedProperties = ["boxSizing", "borderLeftWidth", "borderRightWidth", "borderTopWidth", "borderBottomWidth", "paddingLeft", "paddingRight", "paddingTop", "paddingBottom", "fontFamily", "fontSize", "fontStyle", "fontWeight", "letterSpacing", "lineHeight", "textAlign", "textIndent", "textTransform", "wordSpacing", "tabSize"];
  Object.assign(mirror.style, { position: "fixed", visibility: "hidden", pointerEvents: "none", overflow: "hidden", whiteSpace: "pre", left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
  for (const property of copiedProperties) mirror.style[property] = style[property];
  mirror.textContent = textarea.value.slice(0, textarea.selectionStart);
  marker.textContent = "\u200b";
  mirror.append(marker);
  document.body.append(mirror);
  mirror.scrollLeft = textarea.scrollLeft;
  mirror.scrollTop = textarea.scrollTop;
  const markerRect = marker.getBoundingClientRect();
  const lineHeight = Number.parseFloat(style.lineHeight) || Number.parseFloat(style.fontSize) * 1.5;
  const caretRect = { left: markerRect.left, bottom: markerRect.top + lineHeight };
  mirror.remove();
  return caretRect;
}

function closeCompletions() { state.completion.requestId += 1; $("completionPanel").classList.add("hidden"); state.completion.items = []; }
async function updateCompletions(explicit = false) {
  const requestId = ++state.completion.requestId;
  const context = completionContext(editor.value, editor.selectionStart);
  if (!explicit && !context.fragment) return closeCompletions();
  let fields = [];
  try { fields = await fieldsForCompletion(context); } catch { fields = []; }
  if (requestId !== state.completion.requestId) return;
  const items = completionItems(context, state.objects, fields, state.objectUsage);
  if (!items.length) return closeCompletions();
  state.completion = { items, index: 0, context, requestId }; renderCompletions();
}
function renderCompletions() {
  const panel = $("completionPanel"); panel.replaceChildren(...state.completion.items.map((item, index) => { const row = document.createElement("div"); row.className = `completion-item${index === state.completion.index ? " selected" : ""}`; row.textContent = item.label; if (item.detail) { const small = document.createElement("small"); small.textContent = item.detail; row.append(small); } row.addEventListener("mousedown", event => { event.preventDefault(); acceptCompletion(index); }); return row; }));
  const position = completionPanelPosition(textareaCaretRect(editor), window.innerWidth, window.innerHeight);
  panel.style.left = `${position.left}px`; panel.style.top = `${position.top}px`; panel.style.width = `${position.width}px`; panel.style.maxHeight = `${position.maxHeight}px`; panel.classList.remove("hidden");
}
function acceptCompletion(index = state.completion.index) { const item = state.completion.items[index], context = state.completion.context; if (!item || !context) return; editor.setRangeText(item.insertion, context.start, context.end, "end"); if (item.cursorOffset !== null) editor.setSelectionRange(context.start + item.cursorOffset, context.start + item.cursorOffset); recordObjectUse(item.kind === "object" ? item.insertion : context.objectName); closeCompletions(); editor.focus(); }

async function configureShortcut(shortcut) {
  try { await unregisterAll(); await register(shortcut, async event => { if (event.state === "Pressed") { const window = getCurrentWindow(); await window.show(); await window.unminimize(); await window.setFocus(); editor.focus(); } }); localStorage.setItem("globalShortcut", shortcut); }
  catch (error) { setStatus(`Global shortcut could not be registered: ${error}`, true); }
}

$("connectButton").addEventListener("click", connectOrCancel); $("signOutButton").addEventListener("click", signOut); $("runButton").addEventListener("click", runQuery); $("cancelButton").addEventListener("click", cancelQuery); $("copyButton").addEventListener("click", copyTable); $("sheetButton").addEventListener("click", openInGoogleSheet);
$("toggleSchemaButton").addEventListener("click", () => $("schemaSidebar").classList.toggle("collapsed")); $("refreshSchemaButton").addEventListener("click", () => loadObjects(true));
$("objectSearch").addEventListener("input", renderObjects); $("objectList").addEventListener("change", selectObject); $("fieldSearch").addEventListener("input", renderFields); $("insertFieldButton").addEventListener("click", insertSelectedField); $("copyFieldButton").addEventListener("click", async () => { if (state.selectedField) { await navigator.clipboard.writeText(state.selectedField.apiName); $("schemaStatus").textContent = `Copied ${state.selectedField.apiName}`; } });
$("copyFieldLabelButton").addEventListener("click", async () => { if (state.selectedField) { await navigator.clipboard.writeText(state.selectedField.label); $("schemaStatus").textContent = `Copied ${state.selectedField.label}`; } });
$("detailsButton").addEventListener("click", () => { $("errorDetails").textContent = state.lastError; $("errorDialog").showModal(); }); $("copyErrorButton").addEventListener("click", () => navigator.clipboard.writeText(state.lastError));
$("settingsButton").addEventListener("click", () => { $("shortcutSelect").value = localStorage.getItem("globalShortcut") ?? "Control+Alt+S"; $("hideSystemObjects").checked = hideSystemObjects(); $("settingsDialog").showModal(); }); $("saveSettingsButton").addEventListener("click", async () => { await configureShortcut($("shortcutSelect").value); localStorage.setItem(HIDE_SYSTEM_OBJECTS_KEY, String($("hideSystemObjects").checked)); renderObjects(); $("settingsDialog").close(); setStatus("Settings saved."); });
editor.addEventListener("input", () => updateCompletions(false)); editor.addEventListener("click", closeCompletions);
editor.addEventListener("keydown", event => {
  const panelOpen = !$("completionPanel").classList.contains("hidden");
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") { event.preventDefault(); runQuery(); return; }
  if (event.ctrlKey && event.key === " ") { event.preventDefault(); updateCompletions(true); return; }
  if (!panelOpen) return;
  if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); const delta = event.key === "ArrowDown" ? 1 : -1; state.completion.index = Math.max(0, Math.min(state.completion.items.length - 1, state.completion.index + delta)); renderCompletions(); }
  else if (event.key === "Tab") { event.preventDefault(); acceptCompletion(); }
  else if (event.key === "Enter") closeCompletions();
  else if (event.key === "Escape") { event.preventDefault(); closeCompletions(); }
});
window.addEventListener("keydown", event => { if ((event.metaKey || event.ctrlKey) && event.altKey && event.key.toLowerCase() === "b") { event.preventDefault(); $("schemaSidebar").classList.toggle("collapsed"); } });

configureShortcut(localStorage.getItem("globalShortcut") ?? "Control+Alt+S");
restoreConnection();
