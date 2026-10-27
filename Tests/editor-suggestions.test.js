import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { completionContext, completionItems } from "../src/core.js";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");

test("query editor and schema searches opt out of OS/browser word suggestions", () => {
  for (const id of ["queryEditor", "objectSearch", "fieldSearch"]) {
    const tag = html.match(new RegExp(`<(?:textarea|input)[^>]*id="${id}"[^>]*>`))?.[0];
    assert.ok(tag, `${id} element exists`);
    for (const attr of ['autocomplete="off"', 'autocorrect="off"', 'autocapitalize="off"', 'spellcheck="false"', 'writingsuggestions="false"']) {
      assert.ok(tag.includes(attr), `${id} has ${attr}`);
    }
  }
});

test("app completions only offer schema names and SOQL terms", () => {
  const fields = [{ apiName: "Implementaion__c", label: "Implementation", type: "picklist" }, { apiName: "Name", label: "Account Name", type: "string" }];
  const text = "SELECT Id FROM Account WHERE impl";
  const items = completionItems(completionContext(text, text.length), [], fields);
  assert.ok(items.length > 0);
  assert.ok(items.some(item => item.insertion === "Implementaion__c"));
  for (const item of items) assert.ok(["field", "keyword", "operator", "function"].includes(item.kind), `unexpected kind ${item.kind}`);
  assert.ok(!items.some(item => /implementing/i.test(item.label) || /implementing/i.test(item.insertion)));
});
