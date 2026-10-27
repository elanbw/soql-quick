import Foundation

func expect(_ actual: String, _ expected: String, _ label: String) {
    guard actual == expected else {
        fputs("\(label): expected \(expected.debugDescription), got \(actual.debugDescription)\n", stderr)
        exit(1)
    }
}

expect(TSVFormatter.cell("a\tb\nc", isText: true), "a\\tb\\nc", "tabs and newlines")
expect(TSVFormatter.cell("=SUM(A1:A2)", isText: true), "'=SUM(A1:A2)", "formula protection")
expect(TSVFormatter.cell("-12.5", isText: false), "-12.5", "numeric negative")
expect(
    TSVFormatter.table(columns: ["Name", "Amount"], textColumns: [true, false], rows: [["Example", "3"], ["Missing"]]),
    "Name\tAmount\nExample\t3\nMissing\t",
    "table shape"
)
print("TSV unit tests passed.")

let objects = [
    SchemaObject(apiName: "Zebra__c", label: "Zebra", custom: true, queryable: true),
    SchemaObject(apiName: "Account", label: "Account", custom: false, queryable: true)
]
if !SchemaHelpers.matches("annual", label: "Annual Project Record", apiName: "Annual_Project_Record__c") { exit(1) }
if !SchemaHelpers.matches("__c", label: "Zebra", apiName: "Zebra__c") { exit(1) }
if SchemaHelpers.matches("contact", label: "Account", apiName: "Account") { exit(1) }
if !SchemaHelpers.isFresh(Date().addingTimeInterval(-60)) { exit(1) }
if SchemaHelpers.isFresh(Date().addingTimeInterval(-90000)) { exit(1) }
expect(SchemaHelpers.insert("Name", in: "SELECT  FROM Account", range: NSRange(location: 7, length: 0)), "SELECT Name FROM Account", "field insertion")
expect(SchemaHelpers.insert("Name", in: "SELECT Id FROM Account", range: NSRange(location: 7, length: 2)), "SELECT Name FROM Account", "field replacement")
print("Schema helper tests passed for \(objects.count) synthetic objects.")

let objectContext = SOQLCompletion.context(in: "SELECT Id\nFROM Acc", cursor: 18)
if objectContext.schemaKind != .object || objectContext.fragment != "Acc" { exit(1) }
let selectContext = SOQLCompletion.context(in: "SELECT Na FROM Account", cursor: 9)
if selectContext.schemaKind != .field || selectContext.fragment != "Na" || selectContext.objectName != "Account" { exit(1) }
let whereContext = SOQLCompletion.context(in: "SELECT Id FROM Account WHERE Cre", cursor: 32)
if whereContext.schemaKind != .field || whereContext.fragment != "Cre" { exit(1) }
let quotedContext = SOQLCompletion.context(in: "SELECT Id FROM Account WHERE Name = 'cou", cursor: 40)
if quotedContext.allowsTerms || quotedContext.schemaKind != .none { exit(1) }
let countItems = SOQLCompletion.termItems(for: SOQLCompletion.context(in: "SELECT count_d FROM Account", cursor: 14))
guard let countDistinct = countItems.first(where: { $0.displayText == "COUNT_DISTINCT()" }) else { exit(1) }
expect(countDistinct.insertionText, "COUNT_DISTINCT()", "aggregate snippet")
if countDistinct.cursorOffset != "COUNT_DISTINCT".utf16.count + 1 { exit(1) }
guard let fieldItem = SOQLCompletion.schemaItem(apiName: "CreatedDate", label: "Created Date", detail: "datetime", kind: .field, fragment: "Cre") else { exit(1) }
if fieldItem.score <= countDistinct.score { exit(1) }
expect(fieldItem.displayText, "Created Date", "field completion label")
expect(fieldItem.insertionText, "CreatedDate", "field completion insertion")
expect(fieldItem.secondaryText ?? "", "CreatedDate · datetime", "field completion API name and type")
expect(fieldItem.toolTip ?? "", "CreatedDate", "field completion tooltip")
guard let objectItem = SOQLCompletion.schemaItem(apiName: "Annual_Project_Record__c", label: "Annual Project Record", detail: "Salesforce object", kind: .object, fragment: "Annual") else { exit(1) }
expect(objectItem.displayText, "Annual Project Record", "object completion label")
expect(objectItem.insertionText, "Annual_Project_Record__c", "object completion insertion")
expect(objectItem.secondaryText ?? "", "Annual_Project_Record__c", "object completion API name")
if countDistinct.secondaryText != nil || countDistinct.toolTip != nil { exit(1) }
guard let clauseItem = SOQLCompletion.termItems(for: SOQLCompletion.context(in: "SEL", cursor: 3)).first(where: { $0.displayText == "SELECT" }) else { exit(1) }
if clauseItem.secondaryText != nil || clauseItem.toolTip != nil { exit(1) }
print("SOQL completion context, ranking, and snippet tests passed.")

let cacheEnvelope = SchemaCacheEnvelope(version: 1, fetchedAt: Date(), value: objects)
let cacheData = try JSONEncoder.schemaEncoder.encode(cacheEnvelope)
let decodedCache = try JSONDecoder.schemaDecoder.decode(SchemaCacheEnvelope<[SchemaObject]>.self, from: cacheData)
if decodedCache.value != objects { exit(1) }
if (try? JSONDecoder.schemaDecoder.decode(SchemaCacheEnvelope<[SchemaObject]>.self, from: Data("not json".utf8))) != nil { exit(1) }
print("Schema cache tests passed.")

var pipeCompletionDelivered = false
func startPipeCaptureRegression() {
    let task = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let capture = ProcessPipeCapture(stdout: stdout, stderr: stderr)
    task.executableURL = URL(fileURLWithPath: "/usr/bin/seq")
    task.arguments = ["1", "20000"]
    task.standardOutput = stdout
    task.standardError = stderr
    task.terminationHandler = { _ in
        capture.notify { output, _ in
            pipeCompletionDelivered = output.count > 65_536
        }
    }
    try! task.run()
}
startPipeCaptureRegression()
let pipeDeadline = Date().addingTimeInterval(5)
while !pipeCompletionDelivered && RunLoop.current.run(mode: .default, before: pipeDeadline) && Date() < pipeDeadline {}
if !pipeCompletionDelivered { exit(1) }
print("Large subprocess pipe completion test passed.")
