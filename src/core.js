export const PREVIEW_LIMIT = 100;

export function isSalesforceRecordId(value) {
  return /^[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?$/.test(String(value ?? ""));
}

export function completionPanelPosition(caretRect, viewportWidth, viewportHeight, panelWidth = 410, maxPanelHeight = 250) {
  const margin = 8;
  const gap = 6;
  const width = Math.min(panelWidth, Math.max(0, viewportWidth - margin * 2));
  const left = Math.max(margin, Math.min(caretRect.left, viewportWidth - width - margin));
  const top = caretRect.bottom + gap;
  const maxHeight = Math.max(0, Math.min(maxPanelHeight, viewportHeight - top - margin));
  return { left, top, width, maxHeight };
}

const clauses = ["SELECT", "FROM", "WHERE", "WITH", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "OFFSET", "FOR VIEW", "FOR REFERENCE", "FOR UPDATE", "NULLS FIRST", "NULLS LAST", "ASC", "DESC", "TYPEOF", "WHEN", "THEN", "ELSE", "END", "USING SCOPE"];
const operators = ["AND", "OR", "NOT", "IN", "NOT IN", "LIKE", "INCLUDES", "EXCLUDES"];
const functions = ["COUNT", "COUNT_DISTINCT", "SUM", "AVG", "MIN", "MAX", "CALENDAR_MONTH", "CALENDAR_QUARTER", "CALENDAR_YEAR", "DAY_IN_MONTH", "DAY_IN_WEEK", "DAY_IN_YEAR", "DAY_ONLY", "FISCAL_MONTH", "FISCAL_QUARTER", "FISCAL_YEAR", "HOUR_IN_DAY", "WEEK_IN_MONTH", "WEEK_IN_YEAR", "CONVERTCURRENCY", "FORMAT", "TOLABEL", "GROUPING", "DISTANCE", "GEOLOCATION"];

export function formulaSafeCell(value, isText) {
  let escaped = String(value ?? "").replaceAll("\\", "\\\\").replaceAll("\t", "\\t").replaceAll("\r\n", "\\n").replaceAll("\n", "\\n").replaceAll("\r", "\\n");
  if (isText && /^[=+\-@]/.test(escaped)) escaped = `'${escaped}`;
  return escaped;
}

export function formatTsv(columns, textColumns, rows) {
  const line = row => columns.map((_, index) => formulaSafeCell(row[index] ?? "", Boolean(textColumns[index]))).join("\t");
  return [line(columns), ...rows.map(line)].join("\n");
}

// Index-based so the masked string stays aligned with the original (UTF-16 code units).
function maskQuoted(text) {
  let result = "", quoted = false, escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === "'" && !escaped) { quoted = false; result += "'"; }
      else result += " ";
      escaped = character === "\\" && !escaped;
    } else {
      if (character === "'") quoted = true;
      result += character;
      escaped = false;
    }
  }
  return result;
}

function insideQuote(text) {
  let quoted = false, escaped = false;
  for (const character of text) {
    if (character === "'" && !escaped) quoted = !quoted;
    escaped = character === "\\" && !escaped;
  }
  return quoted;
}

export function completionContext(text, cursor) {
  const safeCursor = Math.max(0, Math.min(cursor, text.length));
  const prefix = text.slice(0, safeCursor);
  const match = prefix.match(/[A-Za-z0-9_]+$/);
  const fragment = match?.[0] ?? "";
  const start = safeCursor - fragment.length;
  const relationshipMatch = prefix.slice(0, start).match(/(?:[A-Za-z_][A-Za-z0-9_]*\.)+$/);
  const relationshipPath = relationshipMatch ? relationshipMatch[0].slice(0, -1).split(".") : [];
  const before = maskQuoted(prefix.slice(0, start)).toUpperCase();
  const clauseMatches = [...before.matchAll(/\b(ORDER\s+BY|GROUP\s+BY|SELECT|FROM|WHERE|HAVING|LIMIT|OFFSET|WITH)\b/gi)];
  const lastClause = clauseMatches.at(-1)?.[1].replace(/\s+/g, " ").toUpperCase();
  let schemaKind = "none";
  if (lastClause === "FROM") schemaKind = "object";
  if (["SELECT", "WHERE", "GROUP BY", "HAVING", "ORDER BY"].includes(lastClause)) schemaKind = "field";
  const objectName = mainQueryObject(text);
  const quoted = insideQuote(prefix);
  return { schemaKind: quoted ? "none" : schemaKind, fragment, start, end: safeCursor, objectName, relationshipPath, allowsTerms: !quoted && schemaKind !== "object" };
}

export function mainQueryObject(text) {
  const masked = maskQuoted(text);
  let depth = 0;
  for (let index = 0; index < masked.length; index += 1) {
    if (masked[index] === "(") { depth += 1; continue; }
    if (masked[index] === ")") { depth = Math.max(0, depth - 1); continue; }
    if (depth !== 0 || (index > 0 && /[A-Za-z0-9_]/.test(masked[index - 1])) || !/^FROM\b/i.test(masked.slice(index))) continue;
    const match = masked.slice(index + 4).match(/^\s+([A-Za-z_][A-Za-z0-9_]*)/);
    if (match) return match[1];
  }
  return null;
}

// Top-level SOQL clauses in canonical order. Each entry's rank is its slot; FOR VIEW and FOR REFERENCE share one.
const clauseOrder = [
  [/^SELECT$/, 0], [/^FROM$/, 1], [/^USING SCOPE$/, 2], [/^WHERE$/, 3], [/^WITH$/, 4], [/^GROUP BY$/, 5], [/^HAVING$/, 6],
  [/^ORDER BY$/, 7], [/^LIMIT$/, 8], [/^OFFSET$/, 9], [/^FOR (?:VIEW|REFERENCE)$/, 10], [/^UPDATE (?:TRACKING|VIEWSTAT)$/, 11], [/^FOR UPDATE$/, 12],
];
const topLevelClausePattern = /FOR\s+(?:VIEW|REFERENCE|UPDATE)|UPDATE\s+(?:TRACKING|VIEWSTAT)|USING\s+SCOPE|GROUP\s+BY|ORDER\s+BY|SELECT|FROM|WHERE|WITH|HAVING|LIMIT|OFFSET/gi;

// Masks quoted text and everything inside parentheses; returns null when quotes or parentheses are unbalanced.
function maskNested(text) {
  if (insideQuote(text)) return null;
  const masked = maskQuoted(text);
  let result = "", depth = 0;
  for (let index = 0; index < masked.length; index += 1) {
    const character = masked[index];
    if (character === "(") depth += 1;
    else if (character === ")") { depth -= 1; if (depth < 0) return null; }
    result += depth > 0 || character === ")" ? " " : character;
  }
  return depth === 0 ? result : null;
}

export function reorderSoqlClauses(text) {
  const masked = maskNested(text);
  if (masked === null) return text;
  const clauses = [];
  for (const match of masked.matchAll(topLevelClausePattern)) {
    const before = masked[match.index - 1] ?? "", after = masked[match.index + match[0].length] ?? "";
    if (/[A-Za-z0-9_.]/.test(before) || /[A-Za-z0-9_.]/.test(after)) continue;
    const name = match[0].toUpperCase().replace(/\s+/g, " ");
    clauses.push({ index: match.index, rank: clauseOrder.find(([pattern]) => pattern.test(name))[1] });
  }
  if (!clauses.length || text.slice(0, clauses[0].index).trim()) return text;
  const ranks = clauses.map(clause => clause.rank);
  if (new Set(ranks).size !== ranks.length) return text;
  if (ranks.every((rank, index) => index === 0 || rank > ranks[index - 1])) return text;
  const segments = clauses.map((clause, index) => ({ rank: clause.rank, text: text.slice(clause.index, clauses[index + 1]?.index ?? text.length).trim() }));
  return segments.sort((a, b) => a.rank - b.rank).map(segment => segment.text).join(text.includes("\n") ? "\n" : " ");
}

export function relationshipTarget(fields, relationshipName) {
  const field = fields.find(item => item.relationshipName?.toLowerCase() === relationshipName.toLowerCase());
  return field?.referenceTo?.length === 1 ? field.referenceTo[0] : null;
}

export async function resolveRelationshipFields(rootObject, relationshipPath, loadFields) {
  if (!rootObject) return [];
  let object = rootObject;
  for (const segment of relationshipPath) {
    const fields = await loadFields(object);
    object = relationshipTarget(fields, segment);
    if (!object) return [];
  }
  return loadFields(object);
}

const hiddenLabelPrefixes = ["Apex ", "Asana ", "Apsona ", "Rollup ", "Flow ", "History:", "Process ", "Permission Set", "Setup ", "Platform Event"];
const hiddenStandardApiFamilies = [
  /^(?:AI|ML)(?:Application|Insight|Model|Prediction|Recommendation|Record)/i,
  /^ActionLink/i,
  /^Attr(?:ibute)?(?:Category|Definition|Picklist)/i,
  /^(?:AuraDefinition|Lightning(?:Exit|ExperienceTheme|Onboarding|Toggle|Usage))/i,
  /^(?:ApexTest|AsyncApex|CronJob|CronTrigger)/i,
  /^(?:AuthorizationForm|DataUse)/i,
  /^(?:BatchData|BatchJob|BatchProcess)/i,
  /^(?:CalcMatrix|CalcProc|CalculationMatrix|CalculationProcedure)/i,
  /^(?:DecisionMatrix|DecisionTable|DecisionTbl)/i,
  /^(?:ExpressionFilter|ExpressionSet|ExpsSet)/i,
  /^FlowOrchestration/i,
  /^IntegrationProvider/i,
  /^ManagedContent/i,
  /^(?:Prompt|Recommendation)/i,
  /^(?:TenantUsage|UserProv|VerificationHistory)/i,
  /^(?:ExternalDataSrc|ExternalDataSource|ExternalDataUserAuth|ExternalEvent)/i,
  /^(?:AppDefinition|AppMenuItem|NavigationMenu|PlatformAction|Publisher|SearchLayout)/i,
  /^(?:EntityDefinition|EntityParticle|FieldDefinition|PicklistValueInfo|RelationshipDomain|RelationshipInfo)/i,
  /^(?:FieldPermissions|ObjectPermissions|SetupAssistant|SetupAudit|SetupEntityAccess|UserEntityAccess|UserFieldAccess|UserSetupEntityAccess)/i,
  /^(?:AuthConfig|AuthProvider|ConnectedApplication|IdentityProvider|IdpEvent|LoginEvent|LoginGeo|LoginHistory|LoginIp|LogoutEvent|OauthToken|OAuthToken|SessionPerm)/i,
  /^(?:DuplicateRule|DuplicateRecord|MatchingRule|MatchingInformation)/i,
];

export function isHiddenSchemaObject(object) {
  const apiName = String(object?.apiName ?? "");
  const label = String(object?.label ?? "").toLowerCase();
  const namespaced = /^[A-Za-z][A-Za-z0-9]*__[A-Za-z0-9_]+__(?:c|mdt|e|b)$/i.test(apiName);
  const supportFamily = /(?:History|Share|Feed|ChangeEvent)$/i.test(apiName);
  const specialCustomType = /__(?:mdt|e|b)$/i.test(apiName);
  const administrativeLabel = hiddenLabelPrefixes.some(prefix => label.startsWith(prefix.toLowerCase()));
  const standardInternal = object?.custom === false && hiddenStandardApiFamilies.some(pattern => pattern.test(apiName));
  return namespaced || supportFamily || specialCustomType || administrativeLabel || standardInternal;
}

// Ranking is modeled on the user's Cardinal fork (Everything-style search):
// matching is case-insensitive and every whitespace-separated term must match;
// usage history is a frecency score (weighted use count scaled by recency
// buckets) that promotes items in the unsearched list and nudges ties.
// Unlike Cardinal, typed text is ranked by match quality as well:
// exact > prefix > word/segment prefix > segment initials > substring > fuzzy.
const DAY_MS = 86_400_000;
const LABEL_PENALTY = 10;
const SCHEMA_CONTEXT_BONUS = 50;
const MAX_USAGE_BOOST = 50;

function wordSegments(value) {
  const starts = [];
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index], previous = value[index - 1], next = value[index + 1];
    if (!/[A-Za-z0-9]/.test(character)) continue;
    const boundary = index === 0 || !/[A-Za-z0-9]/.test(previous)
      || (/[A-Z]/.test(character) && /[a-z0-9]/.test(previous))
      || (/[A-Z]/.test(character) && /[A-Z]/.test(previous) && /[a-z]/.test(next ?? ""))
      || (/[0-9]/.test(character) !== /[0-9]/.test(previous));
    if (boundary) starts.push(index);
  }
  return starts.map((start, index) => {
    let end = start;
    const limit = starts[index + 1] ?? value.length;
    while (end < limit && /[A-Za-z0-9]/.test(value[end])) end += 1;
    return [start, end];
  });
}

function segmentChain(lower, segments, needle, needleIndex = 0, segmentIndex = 0, used = 0) {
  if (needleIndex === needle.length) return used > 1;
  for (let current = segmentIndex; current < segments.length; current += 1) {
    const [start, end] = segments[current];
    let length = 0;
    while (needleIndex + length < needle.length && start + length < end && lower[start + length] === needle[needleIndex + length]) length += 1;
    for (let take = length; take >= 1; take -= 1) if (segmentChain(lower, segments, needle, needleIndex + take, current + 1, used + 1)) return true;
  }
  return false;
}

function fuzzyScore(lower, segments, needle) {
  const starts = new Set(segments.map(([start]) => start));
  let first = -1;
  for (const [start] of segments) if (lower[start] === needle[0]) { first = start; break; }
  if (first < 0) return null;
  let position = first + 1, gaps = 0;
  for (const character of needle.slice(1)) {
    const found = lower.indexOf(character, position);
    if (found < 0) return null;
    if (found > position && !starts.has(found)) gaps += found - position;
    position = found + 1;
  }
  return Math.max(1, 200 - gaps * 5);
}

// Match quality of one candidate string for one search term (higher is better), or null when it does not match.
export function matchQuality(candidate, term) {
  const value = String(candidate ?? ""), needle = String(term ?? "").toLowerCase();
  if (!needle) return 0;
  if (!value) return null;
  const lower = value.toLowerCase(), stem = lower.replace(/__[a-z]+$/, "");
  const lengthPenalty = Math.max(0, Math.min(stem.length - needle.length, 30));
  if (lower === needle) return 1000;
  if (stem === needle) return 950;
  if (lower.startsWith(needle)) return 900 - lengthPenalty;
  // Custom suffixes such as __c and __r are not words the user types toward.
  const segments = wordSegments(value.slice(0, stem.length));
  const segmentIndex = segments.findIndex(([start], index) => index > 0 && lower.startsWith(needle, start));
  if (segmentIndex > 0) return 700 - Math.min(segmentIndex * 5, 25) - lengthPenalty;
  if (needle.length > 1 && segmentChain(lower, segments, needle)) return 550 - lengthPenalty;
  const at = lower.indexOf(needle);
  if (at >= 0) return 400 - Math.min(at, 30) - lengthPenalty;
  if (needle.length < 2) return null;
  const fuzzy = fuzzyScore(lower, segments, needle);
  return fuzzy === null ? null : Math.max(1, fuzzy - lengthPenalty);
}

function searchTerms(query) {
  return String(query ?? "").trim().split(/\s+/).filter(Boolean);
}

// Best match of a schema item ({ apiName, label }) across its API name and label; every term must match.
export function schemaMatchScore(item, query) {
  const terms = searchTerms(query);
  if (!terms.length) return 0;
  let total = 0;
  for (const term of terms) {
    const api = matchQuality(item?.apiName, term), label = matchQuality(item?.label, term);
    if (api === null && label === null) return null;
    total += Math.max(api ?? -Infinity, label === null ? -Infinity : label - LABEL_PENALTY);
  }
  return total / terms.length;
}

function recencyWeight(ageMs) {
  if (ageMs < DAY_MS) return 4;
  if (ageMs < 7 * DAY_MS) return 2;
  if (ageMs < 30 * DAY_MS) return 1;
  return 0.5;
}

function usageEntry(usage, apiName) {
  return usage?.[String(apiName ?? "").toLowerCase()] ?? null;
}

// Cardinal-style frecency: weighted use count scaled by how recently the item was last used.
export function frecencyScore(entry, now = Date.now()) {
  if (!entry?.count) return 0;
  return entry.count * recencyWeight(Math.max(0, now - (entry.lastUsed ?? 0)));
}

export function recordUsage(usage, apiName, now = Date.now(), weight = 1, limit = 50) {
  const key = String(apiName ?? "").trim().toLowerCase();
  const next = { ...(usage ?? {}) };
  if (!key) return next;
  const previous = next[key] ?? { count: 0, lastUsed: 0 };
  next[key] = { count: previous.count + weight, lastUsed: now };
  const keys = Object.keys(next);
  if (keys.length > limit) keys.sort((a, b) => next[b].lastUsed - next[a].lastUsed).slice(limit).forEach(item => delete next[item]);
  return next;
}

function usageBoost(frecency) {
  return frecency > 0 ? Math.min(MAX_USAGE_BOOST, 15 * Math.log2(1 + frecency)) : 0;
}

function byLabel(a, b) {
  return String(a.label ?? "").localeCompare(String(b.label ?? ""), undefined, { sensitivity: "base" }) || String(a.apiName ?? "").localeCompare(String(b.apiName ?? ""));
}

// Orders schema objects or fields for a search box. With text: relevance, then a capped usage boost, then label.
// Without text: up to `promoteLimit` frecent items first (Cardinal's history promotion), then alphabetical by label.
export function rankSchemaItems(items, query = "", usage = {}, now = Date.now(), promoteLimit = 5) {
  const scored = items.map(item => ({ item, frecency: frecencyScore(usageEntry(usage, item.apiName), now) }));
  if (!searchTerms(query).length) {
    const promoted = scored.filter(entry => entry.frecency > 0)
      .sort((a, b) => b.frecency - a.frecency || (usageEntry(usage, b.item.apiName).lastUsed - usageEntry(usage, a.item.apiName).lastUsed) || byLabel(a.item, b.item))
      .slice(0, promoteLimit).map(entry => entry.item);
    const rest = items.filter(item => !promoted.includes(item)).sort(byLabel);
    return [...promoted, ...rest];
  }
  return scored.map(entry => ({ ...entry, score: schemaMatchScore(entry.item, query) }))
    .filter(entry => entry.score !== null)
    .map(entry => ({ ...entry, total: entry.score + usageBoost(entry.frecency) }))
    .sort((a, b) => b.total - a.total || b.frecency - a.frecency || byLabel(a.item, b.item))
    .map(entry => entry.item);
}

function termItem(value, kind, fragment) {
  const score = matchQuality(value, fragment);
  return score === null ? null : { kind, label: kind === "function" ? `${value}()` : value, insertion: kind === "function" ? `${value}()` : value, detail: "", cursorOffset: kind === "function" ? value.length + 1 : null, score };
}

export function completionItems(context, objects = [], fields = [], usage = {}, now = Date.now()) {
  const items = [];
  if (context.allowsTerms) {
    for (const item of clauses.map(value => termItem(value, "keyword", context.fragment))) if (item) items.push(item);
    for (const item of operators.map(value => termItem(value, "operator", context.fragment))) if (item) items.push(item);
    for (const item of functions.map(value => termItem(value, "function", context.fragment))) if (item) items.push(item);
  }
  const source = context.schemaKind === "object" ? objects : context.schemaKind === "field" ? fields : [];
  for (const item of source) {
    const score = schemaMatchScore(item, context.fragment);
    if (score === null) continue;
    const boost = context.schemaKind === "object" ? usageBoost(frecencyScore(usageEntry(usage, item.apiName), now)) : 0;
    items.push({ kind: context.schemaKind, label: item.label, insertion: item.apiName, detail: context.schemaKind === "field" ? `${item.apiName} · ${item.type}` : item.apiName, cursorOffset: null, score: score + SCHEMA_CONTEXT_BONUS + boost });
  }
  return items.sort((a, b) => b.score - a.score || a.label.localeCompare(b.label)).slice(0, 40);
}

export function cacheRead(key, maxAgeMs = 86_400_000, now = Date.now()) {
  try {
    const envelope = JSON.parse(localStorage.getItem(key));
    if (envelope.version !== 1 || now - envelope.fetchedAt >= maxAgeMs) return null;
    return envelope.value;
  } catch { return null; }
}

export function cacheWrite(key, value) {
  localStorage.setItem(key, JSON.stringify({ version: 1, fetchedAt: Date.now(), value }));
}
