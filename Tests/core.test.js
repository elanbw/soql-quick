import test from "node:test";
import assert from "node:assert/strict";
import { completionContext, completionItems, completionPanelPosition, formulaSafeCell, formatTsv, frecencyScore, isHiddenSchemaObject, isSalesforceRecordId, mainQueryObject, matchQuality, rankSchemaItems, recordUsage, relationshipTarget, reorderSoqlClauses, resolveRelationshipFields, schemaMatchScore } from "../src/core.js";

test("Salesforce record IDs are recognized without linking ordinary values", () => {
  assert.equal(isSalesforceRecordId("0015g00000ABCDe"), true);
  assert.equal(isSalesforceRecordId("0015g00000ABCDeAAH"), true);
  assert.equal(isSalesforceRecordId("0015g00000ABCD!"), false);
  assert.equal(isSalesforceRecordId("Example Account"), false);
  assert.equal(isSalesforceRecordId(""), false);
});

test("TSV escaping and formula injection protection", () => {
  assert.equal(formulaSafeCell("a\tb\nc", true), "a\\tb\\nc");
  assert.equal(formulaSafeCell("=SUM(A1:A2)", true), "'=SUM(A1:A2)");
  assert.equal(formulaSafeCell("-12.5", false), "-12.5");
  assert.equal(formatTsv(["Name", "Amount"], [true, false], [["Example", "3"], ["Missing"]]), "Name\tAmount\nExample\t3\nMissing\t");
});

test("completion context ignores quoted strings and identifies schema position", () => {
  assert.deepEqual(completionContext("SELECT Id FROM Acc", 18).schemaKind, "object");
  const context = completionContext("SELECT Na FROM Account", 9);
  assert.equal(context.schemaKind, "field"); assert.equal(context.fragment, "Na"); assert.equal(context.objectName, "Account");
  assert.equal(completionContext("SELECT Id FROM Account WHERE Name = 'cou", 40).allowsTerms, false);
  assert.deepEqual(completionContext("SELECT Account.Owner.Na FROM Contact", 23).relationshipPath, ["Account", "Owner"]);
});

test("main query object ignores subquery FROM clauses", () => {
  assert.equal(mainQueryObject("SELECT Id, (SELECT Id FROM Contacts) FROM Account"), "Account");
  assert.equal(mainQueryObject("SELECT Id FROM Annual_Project_Record__c"), "Annual_Project_Record__c");
  assert.equal(mainQueryObject("SELECT 'FROM Contact' value FROM Account"), "Account");
});

test("relationship targets require a single unambiguous reference", () => {
  const fields = [
    { relationshipName: "Account__r", referenceTo: ["Account"] },
    { relationshipName: "Who", referenceTo: ["Contact", "Lead"] },
  ];
  assert.equal(relationshipTarget(fields, "account__R"), "Account");
  assert.equal(relationshipTarget(fields, "Who"), null);
  assert.equal(relationshipTarget(fields, "Missing"), null);
});

test("relationship fields resolve across multiple unambiguous levels", async () => {
  const metadata = new Map([
    ["Contact", [{ relationshipName: "Account", referenceTo: ["Account"] }]],
    ["Account", [{ relationshipName: "Owner", referenceTo: ["User"] }]],
    ["User", [{ apiName: "Name", label: "Full Name", type: "string" }]],
  ]);
  const loaded = [];
  const fields = await resolveRelationshipFields("Contact", ["Account", "Owner"], async object => { loaded.push(object); return metadata.get(object) ?? []; });
  assert.equal(fields[0].apiName, "Name");
  assert.deepEqual(loaded, ["Contact", "Account", "User"]);
  const polymorphic = await resolveRelationshipFields("Task", ["Who"], async object => object === "Task" ? [{ relationshipName: "Who", referenceTo: ["Contact", "Lead"] }] : []);
  assert.deepEqual(polymorphic, []);
});

test("schema object classifier uses structure and administrative label fallbacks", () => {
  assert.equal(isHiddenSchemaObject({ apiName: "acme__Task__c", label: "Task" }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "AccountHistory", label: "Account History" }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "Notice__e", label: "Notice" }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "Custom_Process__c", label: "Process Instance" }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "DecisionTableParameter", label: "Decision Table Parameter", custom: false }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "ExpressionSetVersion", label: "Expression Set Version", custom: false }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "CalculationMatrixRow", label: "Calculation Matrix Row", custom: false }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "LightningUsageByPageMetrics", label: "Lightning Usage By Page Metrics", custom: false }), true);
  assert.equal(isHiddenSchemaObject({ apiName: "Decision_Table__c", label: "Decision Table", custom: true }), false);
  assert.equal(isHiddenSchemaObject({ apiName: "Annual_Project_Record__c", label: "Annual Project Record" }), false);
  assert.equal(isHiddenSchemaObject({ apiName: "Account", label: "Account" }), false);
});

const DAY = 86_400_000;
const names = items => items.map(item => item.apiName);

test("match quality tiers: exact > prefix > word segment > initials > substring > fuzzy", () => {
  const exact = matchQuality("Account", "account");
  const stem = matchQuality("Account__c", "account");
  const prefix = matchQuality("AccountContactRelation", "account");
  const segment = matchQuality("Primary_Account__c", "account");
  const initials = matchQuality("Annual_Project_Record__c", "apr");
  const substring = matchQuality("Subaccount__c", "account");
  const fuzzy = matchQuality("Implementation_Notes__c", "imnt");
  assert.ok(exact > stem && stem > prefix && prefix > segment && segment > initials && initials > substring && substring > fuzzy && fuzzy > 0);
  assert.equal(matchQuality("Contact", "xyz"), null);
  assert.equal(matchQuality("Contact", "q"), null);
});

test("word boundaries include CamelCase, underscores, spaces, and digits", () => {
  assert.ok(matchQuality("CreatedDate", "date") >= 600);
  assert.ok(matchQuality("Primary_Account__c", "acc") >= 600);
  assert.ok(matchQuality("Grade 3 Score", "score") >= 600);
  assert.ok(matchQuality("Q3Revenue__c", "rev") >= 600);
  assert.ok(matchQuality("URLField__c", "field") >= 600);
  assert.ok(matchQuality("Primary_Account__c", "primacc") >= 500);
});

test("shorter matches outrank longer ones within a tier", () => {
  assert.ok(matchQuality("Name", "na") > matchQuality("Name_Of_The_Partner_Org__c", "na"));
});

test("schema match uses API name and label and requires every search term", () => {
  assert.ok(schemaMatchScore({ apiName: "Implementaion__c", label: "Implementation Status" }, "impl") >= 850);
  assert.ok(schemaMatchScore({ apiName: "Custom_1__c", label: "Owner Region" }, "region") > 0);
  assert.ok(schemaMatchScore({ apiName: "Annual_Project_Record__c", label: "Annual Project Record" }, "project rec") > 0);
  assert.equal(schemaMatchScore({ apiName: "Annual_Project_Record__c", label: "Annual Project Record" }, "project contact"), null);
});

test("frecency weights use count by recency buckets", () => {
  const now = 100 * DAY;
  assert.equal(frecencyScore({ count: 3, lastUsed: now - 60_000 }, now), 12);
  assert.equal(frecencyScore({ count: 2, lastUsed: now - 3 * DAY }, now), 4);
  assert.equal(frecencyScore({ count: 2, lastUsed: now - 10 * DAY }, now), 2);
  assert.equal(frecencyScore({ count: 4, lastUsed: now - 60 * DAY }, now), 2);
  assert.equal(frecencyScore(null, now), 0);
});

test("usage records are case-insensitive, weighted, and pruned to the newest entries", () => {
  let usage = recordUsage({}, "Contact", 1);
  usage = recordUsage(usage, "contact", 2, 2);
  assert.deepEqual(usage, { contact: { count: 3, lastUsed: 2 } });
  usage = recordUsage(usage, "Account", 3, 1, 2);
  usage = recordUsage(usage, "Case", 4, 1, 2);
  assert.deepEqual(Object.keys(usage).sort(), ["account", "case"]);
  assert.deepEqual(recordUsage(usage, "  ", 5), usage);
});

test("empty schema search promotes frecent objects then sorts alphabetically by label", () => {
  const now = 100 * DAY;
  const objects = [{ apiName: "Opportunity", label: "Opportunity" }, { apiName: "Case", label: "Case" }, { apiName: "Account", label: "Account" }, { apiName: "Contact", label: "Contact" }, { apiName: "Lead", label: "lead" }];
  assert.deepEqual(names(rankSchemaItems(objects, "")), ["Account", "Case", "Contact", "Lead", "Opportunity"]);
  const usage = { opportunity: { count: 1, lastUsed: now - 60 * DAY }, contact: { count: 2, lastUsed: now - 1000 } };
  assert.deepEqual(names(rankSchemaItems(objects, "  ", usage, now)), ["Contact", "Opportunity", "Account", "Case", "Lead"]);
  assert.deepEqual(names(rankSchemaItems(objects, "", usage, now, 1)), ["Contact", "Account", "Case", "Lead", "Opportunity"]);
});

test("schema search ranks by relevance instead of pinning recent objects", () => {
  const now = 100 * DAY;
  const objects = [
    { apiName: "Primary_Account__c", label: "Primary Account" },
    { apiName: "AccountContactRelation", label: "Account Contact Relationship" },
    { apiName: "Account", label: "Account" },
    { apiName: "Contact", label: "Contact" },
    { apiName: "Account_Plan__c", label: "Account Plan" },
  ];
  const usage = { contact: { count: 50, lastUsed: now }, primary_account__c: { count: 50, lastUsed: now } };
  const ranked = names(rankSchemaItems(objects, "acc", usage, now));
  assert.equal(ranked[0], "Account");
  assert.ok(!ranked.includes("Contact"));
  assert.equal(ranked.at(-1), "Primary_Account__c");
  const tie = [{ apiName: "Site_B__c", label: "Site B" }, { apiName: "Site_A__c", label: "Site A" }];
  assert.deepEqual(names(rankSchemaItems(tie, "site")), ["Site_A__c", "Site_B__c"]);
  assert.deepEqual(names(rankSchemaItems(tie, "site", { site_b__c: { count: 1, lastUsed: now } }, now)), ["Site_B__c", "Site_A__c"]);
  assert.ok(matchQuality("Alpha__c", "c") < 400);
});

test("field search finds the misspelled Implementaion field by its prefix", () => {
  const fields = [
    { apiName: "Simple_Flag__c", label: "Simple Flag" },
    { apiName: "Implementaion__c", label: "Implementation" },
    { apiName: "Last_Implementation_Date__c", label: "Last Implementation Date" },
  ];
  assert.deepEqual(names(rankSchemaItems(fields, "impl")), ["Implementaion__c", "Last_Implementation_Date__c", "Simple_Flag__c"]);
});

test("schema completions outrank terms and functions place the cursor inside parentheses", () => {
  const context = completionContext("SELECT Cre FROM Account", 10);
  const items = completionItems(context, [], [{ apiName: "CreatedDate", label: "Created Date", type: "datetime" }]);
  assert.equal(items[0].insertion, "CreatedDate");
  const functions = completionItems(completionContext("SELECT count_d FROM Account", 14));
  const count = functions.find(item => item.label === "COUNT_DISTINCT()");
  assert.equal(count.cursorOffset, "COUNT_DISTINCT".length + 1);
});

test("editor completions rank schema items by word-boundary matches ahead of similar keywords", () => {
  const fields = [
    { apiName: "Account__c", label: "Account", type: "reference" },
    { apiName: "Primary_Account__c", label: "Primary Account", type: "reference" },
    { apiName: "Implementaion__c", label: "Implementation", type: "picklist" },
    { apiName: "Industry", label: "Industry", type: "picklist" },
  ];
  const acc = completionItems(completionContext("SELECT acc FROM Contact", 10), [], fields).map(item => item.insertion);
  assert.deepEqual(acc.slice(0, 2), ["Account__c", "Primary_Account__c"]);
  const impl = completionItems(completionContext("SELECT impl FROM Account", 11), [], fields).map(item => item.insertion);
  assert.equal(impl[0], "Implementaion__c");
  const inItems = completionItems(completionContext("SELECT Id FROM Account WHERE Industry in", 41), [], fields).map(item => item.insertion);
  assert.equal(inItems[0], "IN");
  assert.equal(inItems[1], "Industry");
  const byLabel = completionItems(completionContext("SELECT Id FROM Account WHERE impleme", 37), [], [{ apiName: "Custom_7__c", label: "Implementation Stage", type: "string" }]);
  assert.equal(byLabel[0].insertion, "Custom_7__c");
});

test("object completions use usage as a soft boost", () => {
  const now = 100 * DAY;
  const objects = [{ apiName: "Annual_Project_Record__c", label: "Annual Project Record" }, { apiName: "Annual_Goal__c", label: "Annual Goal" }];
  const context = completionContext("SELECT Id FROM annual", 21);
  assert.equal(completionItems(context, objects, [], {}, now)[0].insertion, "Annual_Goal__c");
  assert.equal(completionItems(context, objects, [], { annual_project_record__c: { count: 2, lastUsed: now } }, now)[0].insertion, "Annual_Project_Record__c");
});

test("completion popup stays below the caret and within viewport boundaries", () => {
  assert.deepEqual(completionPanelPosition({ left: 240, bottom: 180 }, 1200, 720), { left: 240, top: 186, width: 410, maxHeight: 250 });
  assert.deepEqual(completionPanelPosition({ left: 1180, bottom: 660 }, 1200, 720), { left: 782, top: 666, width: 410, maxHeight: 46 });
  assert.deepEqual(completionPanelPosition({ left: -30, bottom: 700 }, 360, 720), { left: 8, top: 706, width: 344, maxHeight: 6 });
});

test("completion popup uses caret coordinates supplied after editor scrolling", () => {
  const scrolledCaret = { left: 125, bottom: 94 };
  assert.equal(completionPanelPosition(scrolledCaret, 900, 600).top, 100);
  assert.equal(completionPanelPosition(scrolledCaret, 900, 600).left, 125);
});

test("clause reordering moves top-level clauses into canonical SOQL order", () => {
  assert.equal(reorderSoqlClauses("FROM Account WHERE Name != null SELECT Id, Name LIMIT 5"), "SELECT Id, Name FROM Account WHERE Name != null LIMIT 5");
  assert.equal(reorderSoqlClauses("from Account select Id order by Name desc nulls last limit 10 where Name like 'A%'"), "select Id from Account where Name like 'A%' order by Name desc nulls last limit 10");
  assert.equal(reorderSoqlClauses("SELECT Id FROM Account OFFSET 10 LIMIT 5"), "SELECT Id FROM Account LIMIT 5 OFFSET 10");
  assert.equal(reorderSoqlClauses("SELECT Name, COUNT(Id) FROM Account HAVING COUNT(Id) > 1 GROUP BY ROLLUP(Name)"), "SELECT Name, COUNT(Id) FROM Account GROUP BY ROLLUP(Name) HAVING COUNT(Id) > 1");
  assert.equal(reorderSoqlClauses("SELECT Id FROM Account WITH SECURITY_ENFORCED WHERE Name != null"), "SELECT Id FROM Account WHERE Name != null WITH SECURITY_ENFORCED");
  assert.equal(reorderSoqlClauses("SELECT Id FROM Account FOR VIEW LIMIT 1 USING SCOPE mine"), "SELECT Id FROM Account USING SCOPE mine LIMIT 1 FOR VIEW");
  assert.equal(reorderSoqlClauses("SELECT Id FROM KnowledgeArticleVersion UPDATE VIEWSTAT WHERE PublishStatus = 'Online'"), "SELECT Id FROM KnowledgeArticleVersion WHERE PublishStatus = 'Online' UPDATE VIEWSTAT");
  assert.equal(reorderSoqlClauses("SELECT Id FROM Account FOR UPDATE LIMIT 1"), "SELECT Id FROM Account LIMIT 1 FOR UPDATE");
});

test("clause reordering leaves already-ordered and unsafe queries unchanged", () => {
  for (const query of [
    "SELECT Id, Name FROM Account WHERE Name != null ORDER BY Name ASC NULLS FIRST LIMIT 5 OFFSET 2",
    "SELECT Id FROM Account WHERE Name = 'x' WITH SECURITY_ENFORCED GROUP BY Id HAVING COUNT(Id) > 0 ORDER BY Id LIMIT 1 FOR REFERENCE",
    "SELECT Id FROM Account LIMIT 5 WHERE Name = 'a' LIMIT 3",
    "SELECT Id FROM Account WHERE Id != null FROM Contact",
    "Id, Name FROM Account SELECT Id",
    "FROM Account SELECT Name WHERE Name = 'unterminated",
    "FROM Account SELECT (SELECT Id FROM Contacts",
    "",
    "Name",
  ]) assert.equal(reorderSoqlClauses(query), query);
});

test("clause reordering ignores keywords in subqueries, strings, and identifiers", () => {
  assert.equal(reorderSoqlClauses("FROM Account SELECT Id, (SELECT Id FROM Contacts WHERE Email != null ORDER BY Name LIMIT 2) LIMIT 5"), "SELECT Id, (SELECT Id FROM Contacts WHERE Email != null ORDER BY Name LIMIT 2) FROM Account LIMIT 5");
  assert.equal(reorderSoqlClauses("WHERE Id IN (SELECT AccountId FROM Contact WHERE LastName = 'Smith') FROM Account SELECT Id"), "SELECT Id FROM Account WHERE Id IN (SELECT AccountId FROM Contact WHERE LastName = 'Smith')");
  assert.equal(reorderSoqlClauses("FROM Account WHERE Name = 'Select From Where ORDER BY \\' LIMIT' SELECT Id"), "SELECT Id FROM Account WHERE Name = 'Select From Where ORDER BY \\' LIMIT'");
  assert.equal(reorderSoqlClauses("FROM Opportunity SELECT From__c, Order__r.Name, Limit_Amount__c, Account.Group__c WHERE Offset__c > 1 AND Order__r.Where__c = null"), "SELECT From__c, Order__r.Name, Limit_Amount__c, Account.Group__c FROM Opportunity WHERE Offset__c > 1 AND Order__r.Where__c = null");
  assert.equal(reorderSoqlClauses("FROM Order SELECT Id ORDER BY OrderNumber"), "SELECT Id FROM Order ORDER BY OrderNumber");
  assert.equal(reorderSoqlClauses("FROM Event SELECT TYPEOF What WHEN Account THEN Phone ELSE Name END WHERE Id != null"), "SELECT TYPEOF What WHEN Account THEN Phone ELSE Name END FROM Event WHERE Id != null");
  assert.equal(reorderSoqlClauses("SELECT Id FROM Account WHERE Name IN ('a', 'b') ORDER BY Name"), "SELECT Id FROM Account WHERE Name IN ('a', 'b') ORDER BY Name");
});

test("clause reordering preserves clause text and uses newlines for multiline input", () => {
  assert.equal(reorderSoqlClauses("FROM Account\nWHERE Name != null\n  AND Type = 'x'\nselect Id,\n  Name\n"), "select Id,\n  Name\nFROM Account\nWHERE Name != null\n  AND Type = 'x'");
  assert.equal(reorderSoqlClauses("  from   Account   select  Id  "), "select  Id from   Account");
  assert.equal(reorderSoqlClauses("FROM Account ORDER\n  BY Name SELECT Id"), "SELECT Id\nFROM Account\nORDER\n  BY Name");
});

test("completion context uses the FROM object when SELECT is typed after FROM", () => {
  const text = "FROM Account WHERE Name != null SELECT Na";
  const context = completionContext(text, text.length);
  assert.equal(context.schemaKind, "field"); assert.equal(context.fragment, "Na"); assert.equal(context.objectName, "Account");
  assert.equal(completionContext("FROM Acc SELECT Id", 8).schemaKind, "object");
  assert.equal(mainQueryObject("FROM Contact SELECT Id, (SELECT Id FROM Cases)"), "Contact");
  assert.equal(mainQueryObject("SELECT From__c FROM Account"), "Account");
});
