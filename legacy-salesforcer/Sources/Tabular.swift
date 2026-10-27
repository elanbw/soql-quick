import Foundation

enum TSVFormatter {
    static func cell(_ value: String, isText: Bool) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        if isText, let first = escaped.first, "=+-@".contains(first) {
            escaped = "'" + escaped
        }
        return escaped
    }

    static func table(columns: [String], textColumns: [Bool], rows: [[String]]) -> String {
        func formatted(_ value: String, at index: Int) -> String {
            cell(value, isText: index < textColumns.count && textColumns[index])
        }
        var lines = [columns.enumerated().map { formatted($0.element, at: $0.offset) }.joined(separator: "\t")]
        lines.append(contentsOf: rows.map { row in
            columns.indices.map { index in
                formatted(index < row.count ? row[index] : "", at: index)
            }.joined(separator: "\t")
        })
        return lines.joined(separator: "\n")
    }
}
