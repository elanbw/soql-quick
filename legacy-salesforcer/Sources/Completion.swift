import AppKit
import Foundation

enum CompletionKind: String {
    case object = "Object"
    case field = "Field"
    case keyword = "Keyword"
    case function = "Function"
    case operation = "Operator"
}

struct CompletionContext: Equatable {
    enum SchemaKind: Equatable { case object, field, none }
    let schemaKind: SchemaKind
    let fragment: String
    let replacementRange: NSRange
    let objectName: String?
    let allowsTerms: Bool
}

struct CompletionItem: Equatable {
    let kind: CompletionKind
    let displayText: String
    let insertionText: String
    let secondaryText: String?
    let toolTip: String?
    let cursorOffset: Int?
    let score: Int
}

enum SOQLCompletion {
    private static let clauses = [
        "SELECT", "FROM", "WHERE", "WITH", "GROUP BY", "HAVING", "ORDER BY",
        "LIMIT", "OFFSET", "FOR VIEW", "FOR REFERENCE", "FOR UPDATE", "NULLS FIRST", "NULLS LAST",
        "ASC", "DESC", "TYPEOF", "WHEN", "THEN", "ELSE", "END", "USING SCOPE"
    ]
    private static let operators = [
        "AND", "OR", "NOT", "IN", "NOT IN", "LIKE", "INCLUDES", "EXCLUDES"
    ]
    private static let functions = [
        "COUNT", "COUNT_DISTINCT", "SUM", "AVG", "MIN", "MAX",
        "CALENDAR_MONTH", "CALENDAR_QUARTER", "CALENDAR_YEAR", "DAY_IN_MONTH", "DAY_IN_WEEK",
        "DAY_IN_YEAR", "DAY_ONLY", "FISCAL_MONTH", "FISCAL_QUARTER", "FISCAL_YEAR",
        "HOUR_IN_DAY", "WEEK_IN_MONTH", "WEEK_IN_YEAR", "CONVERTCURRENCY", "FORMAT", "TOLABEL",
        "GROUPING", "DISTANCE", "GEOLOCATION"
    ]

    static func context(in text: String, cursor: Int) -> CompletionContext {
        let ns = text as NSString
        let safeCursor = min(max(cursor, 0), ns.length)
        let prefix = ns.substring(to: safeCursor)
        let fragmentRange = identifierRange(in: ns, cursor: safeCursor)
        let fragment = ns.substring(with: fragmentRange)
        let beforeFragment = (prefix as NSString).substring(to: max(0, prefix.utf16.count - fragment.utf16.count))
        let upperBefore = maskQuotedStrings(beforeFragment).uppercased()

        let topObject = firstCapture(#"(?is)\bFROM\s+([A-Z_][A-Z0-9_]*)"#, in: maskQuotedStrings(text))
        let lastClause = lastClauseMatch(in: upperBefore)
        let schemaKind: CompletionContext.SchemaKind
        switch lastClause {
        case "FROM": schemaKind = .object
        case "SELECT", "WHERE", "GROUP BY", "HAVING", "ORDER BY": schemaKind = .field
        default: schemaKind = .none
        }
        let inQuotedString = isInsideQuotedString(prefix)
        return CompletionContext(
            schemaKind: inQuotedString ? .none : schemaKind,
            fragment: fragment,
            replacementRange: fragmentRange,
            objectName: topObject,
            allowsTerms: !inQuotedString && schemaKind != .object
        )
    }

    static func termItems(for context: CompletionContext) -> [CompletionItem] {
        guard context.allowsTerms else { return [] }
        var values: [CompletionItem] = []
        values += clauses.compactMap { term($0, kind: .keyword, fragment: context.fragment) }
        values += operators.compactMap { term($0, kind: .operation, fragment: context.fragment) }
        values += functions.compactMap { name in
            guard let score = matchScore(name, fragment: context.fragment) else { return nil }
            let insertion = "\(name)()"
            return CompletionItem(kind: .function, displayText: "\(name)()", insertionText: insertion, secondaryText: nil, toolTip: nil, cursorOffset: name.utf16.count + 1, score: score)
        }
        return values
    }

    static func schemaItem(apiName: String, label: String, detail: String, kind: CompletionKind, fragment: String) -> CompletionItem? {
        let apiScore = matchScore(apiName, fragment: fragment)
        let labelScore = matchScore(label, fragment: fragment).map { $0 - 5 }
        guard let score = [apiScore, labelScore].compactMap({ $0 }).max() else { return nil }
        let secondaryText = kind == .field ? "\(apiName) · \(detail)" : apiName
        return CompletionItem(kind: kind, displayText: label, insertionText: apiName, secondaryText: secondaryText, toolTip: apiName, cursorOffset: nil, score: score + 20)
    }

    static func sorted(_ items: [CompletionItem], limit: Int = 40) -> [CompletionItem] {
        Array(items.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.displayText.localizedCaseInsensitiveCompare($1.displayText) == .orderedAscending
        }.prefix(limit))
    }

    private static func term(_ value: String, kind: CompletionKind, fragment: String) -> CompletionItem? {
        guard let score = matchScore(value, fragment: fragment) else { return nil }
        return CompletionItem(kind: kind, displayText: value, insertionText: value, secondaryText: nil, toolTip: nil, cursorOffset: nil, score: score)
    }

    private static func matchScore(_ candidate: String, fragment: String) -> Int? {
        if fragment.isEmpty { return 10 }
        if candidate.caseInsensitiveCompare(fragment) == .orderedSame { return 100 }
        if candidate.lowercased().hasPrefix(fragment.lowercased()) { return 80 - min(candidate.count - fragment.count, 20) }
        if candidate.localizedCaseInsensitiveContains(fragment) { return 40 }
        return nil
    }

    private static func identifierRange(in text: NSString, cursor: Int) -> NSRange {
        var start = cursor
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        while start > 0 {
            let scalar = UnicodeScalar(text.character(at: start - 1))!
            if !allowed.contains(scalar) { break }
            start -= 1
        }
        return NSRange(location: start, length: cursor - start)
    }

    private static func lastClauseMatch(in text: String) -> String? {
        let pattern = #"(?is)\b(ORDER\s+BY|GROUP\s+BY|SELECT|FROM|WHERE|HAVING|LIMIT|OFFSET|WITH)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].uppercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func maskQuotedStrings(_ text: String) -> String {
        var result = ""; var quoted = false; var escaped = false
        for character in text {
            if quoted {
                if character == "'" && !escaped { quoted = false; result.append("'") }
                else { result.append(" ") }
                escaped = character == "\\" && !escaped
            } else {
                if character == "'" { quoted = true }
                result.append(character)
                escaped = false
            }
        }
        return result
    }

    private static func isInsideQuotedString(_ text: String) -> Bool {
        var quoted = false; var escaped = false
        for character in text {
            if character == "'" && !escaped { quoted.toggle() }
            escaped = character == "\\" && !escaped
        }
        return quoted
    }
}

final class QueryTextView: NSTextView {
    var handleCompletionKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if handleCompletionKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class CompletionPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private var items: [CompletionItem] = []
    var accept: ((CompletionItem) -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .popUpMenu; panel.hasShadow = true; panel.isOpaque = true; panel.backgroundColor = .controlBackgroundColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion")); column.width = 388
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(doubleClick)
        let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.documentView = table
        panel.contentView?.addSubview(scroll)
    }

    var isVisible: Bool { panel.isVisible }
    func show(_ newItems: [CompletionItem], at screenPoint: NSPoint, parent: NSWindow?) {
        items = newItems; table.reloadData()
        guard !items.isEmpty else { close(); return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let height = min(CGFloat(items.count) * table.rowHeight + 4, 240)
        panel.setContentSize(NSSize(width: 390, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: screenPoint.x, y: screenPoint.y))
        panel.orderFront(nil)
    }
    func close() { panel.orderOut(nil); items = []; table.reloadData() }
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(table.selectedRow, 0)
        let next = min(max(current + delta, 0), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
    }
    func acceptSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]; close(); accept?(item)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("completionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let label = NSTextField(labelWithString: ""); label.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(label); c.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            return c
        }()
        let item = items[row]
        let text = NSMutableAttributedString(string: item.displayText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)])
        if let secondaryText = item.secondaryText {
            text.append(NSAttributedString(string: " · \(secondaryText)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        cell.textField?.attributedStringValue = text
        cell.textField?.toolTip = item.toolTip
        return cell
    }
    @objc private func doubleClick() { acceptSelected() }
}
