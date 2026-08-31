import AppKit
import Foundation

enum QueryCellValue: Hashable, Sendable {
  case integer(Int)
  case decimal(Double)
  case boolean(Bool)
  case text(String)
  case null

  var displayValue: String {
    switch self {
    case .integer(let value): String(value)
    case .decimal(let value): String(value)
    case .boolean(let value): value ? "true" : "false"
    case .text(let value): value
    case .null: "NULL"
    }
  }

  var jsonValue: Any {
    switch self {
    case .integer(let value): value
    case .decimal(let value): value
    case .boolean(let value): value
    case .text(let value): value
    case .null: NSNull()
    }
  }

  var sqlValue: String {
    switch self {
    case .integer(let value): String(value)
    case .decimal(let value): String(value)
    case .boolean(let value): value ? "TRUE" : "FALSE"
    case .text(let value): "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    case .null: "NULL"
    }
  }
}

struct QueryTableData: Hashable, Sendable {
  let columns: [String]
  let rows: [[QueryCellValue]]
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
  case csv = "CSV"
  case tsv = "TSV"
  case json = "JSON"
  case jsonLines = "JSON Lines"
  case markdown = "Markdown"
  case sqlInsert = "SQL INSERT"

  var id: String { rawValue }

  var fileExtension: String {
    switch self {
    case .csv: "csv"
    case .tsv: "tsv"
    case .json: "json"
    case .jsonLines: "jsonl"
    case .markdown: "md"
    case .sqlInsert: "sql"
    }
  }

  var symbol: String {
    switch self {
    case .csv, .tsv: "tablecells"
    case .json, .jsonLines: "curlybraces"
    case .markdown: "text.document"
    case .sqlInsert: "cylinder.split.1x2"
    }
  }
}

enum ResultExporter {
  static func string(from table: QueryTableData, format: ExportFormat) -> String {
    switch format {
    case .csv:
      delimited(table, separator: ",", quoteValues: true)
    case .tsv:
      delimited(table, separator: "\t", quoteValues: false)
    case .json:
      json(table, lines: false)
    case .jsonLines:
      json(table, lines: true)
    case .markdown:
      markdown(table)
    case .sqlInsert:
      sqlInsert(table)
    }
  }

  @MainActor
  static func copy(_ table: QueryTableData, format: ExportFormat) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string(from: table, format: format), forType: .string)
  }

  @MainActor
  static func save(_ table: QueryTableData, format: ExportFormat, panelTitle: String) throws -> URL?
  {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "solnari-result.\(format.fileExtension)"
    panel.title = panelTitle

    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    try string(from: table, format: format).write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private static func delimited(_ table: QueryTableData, separator: Character, quoteValues: Bool)
    -> String
  {
    let header = table.columns.map {
      escapeDelimited($0, separator: separator, quoteValues: quoteValues)
    }.joined(separator: String(separator))
    let rows = table.rows.map { row in
      row.map { escapeDelimited($0.displayValue, separator: separator, quoteValues: quoteValues) }
        .joined(separator: String(separator))
    }
    return ([header] + rows).joined(separator: "\n")
  }

  private static func escapeDelimited(_ value: String, separator: Character, quoteValues: Bool)
    -> String
  {
    let normalized =
      quoteValues
      ? value
      : value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    let needsQuotes =
      quoteValues
      && (normalized.contains(separator) || normalized.contains("\"") || normalized.contains("\n")
        || normalized.contains("\r"))
    guard needsQuotes else { return normalized }
    return "\"\(normalized.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func json(_ table: QueryTableData, lines: Bool) -> String {
    let objects = table.rows.map { row in
      Dictionary(uniqueKeysWithValues: zip(table.columns, row.map(\.jsonValue)))
    }

    if lines {
      return objects.compactMap { object in
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
      }
      .joined(separator: "\n")
    }

    guard
      let data = try? JSONSerialization.data(
        withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  private static func markdown(_ table: QueryTableData) -> String {
    let header = "| " + table.columns.map(escapeMarkdown).joined(separator: " | ") + " |"
    let separator = "| " + table.columns.map { _ in "---" }.joined(separator: " | ") + " |"
    let rows = table.rows.map { row in
      "| " + row.map { escapeMarkdown($0.displayValue) }.joined(separator: " | ") + " |"
    }
    return ([header, separator] + rows).joined(separator: "\n")
  }

  private static func escapeMarkdown(_ value: String) -> String {
    value
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\n", with: "<br>")
  }

  private static func sqlInsert(_ table: QueryTableData) -> String {
    let columns = table.columns.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: ", ")
    return table.rows.map { row in
      "INSERT INTO \"query_result\" (\(columns)) VALUES (\(row.map(\.sqlValue).joined(separator: ", ")));"
    }
    .joined(separator: "\n")
  }
}
