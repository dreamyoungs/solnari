import Foundation

enum ResultCellQueryAction: Int, CaseIterable, Sendable {
  case equal
  case notEqual
  case contains
  case startsWith
  case endsWith
  case isNull
  case isNotNull
  case deleteMatching
}

enum SQLObjectQueryBuilder {
  static func selectAll(
    from object: SchemaObject,
    engine: DatabaseEngine,
    limit: Int = 200
  ) -> String {
    let safeLimit = min(max(limit, 1), 1_000)
    return """
      SELECT *
      FROM \(qualifiedName(for: object, engine: engine))
      LIMIT \(safeLimit);
      """
  }

  static func qualifiedName(for object: SchemaObject, engine: DatabaseEngine) -> String {
    "\(quote(object.schema, engine: engine)).\(quote(object.name, engine: engine))"
  }

  static func inferredSourceObject(
    from sql: String,
    objects: [SchemaObject],
    engine: DatabaseEngine
  ) -> SchemaObject? {
    guard matches(#"^\s*SELECT\b"#, in: sql),
      matchCount(of: #"\bFROM\b"#, in: sql) == 1,
      !matches(#"\bJOIN\b"#, in: sql)
    else { return nil }

    let nameOccurrences = Dictionary(grouping: objects, by: { $0.name.lowercased() })
    let matches = objects.filter { object in
      let qualified = qualifiedName(for: object, engine: engine)
      if followsFrom(qualified, in: sql) { return true }

      guard nameOccurrences[object.name.lowercased()]?.count == 1 else { return false }
      return followsFrom(quote(object.name, engine: engine), in: sql)
        || (isSafeUnquotedIdentifier(object.name) && followsFrom(object.name, in: sql))
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
  }

  static func selectMatching(
    from object: SchemaObject,
    column: String,
    value: QueryCellValue,
    action: ResultCellQueryAction,
    engine: DatabaseEngine,
    limit: Int = 200
  ) -> String? {
    guard
      let condition = condition(
        column: column,
        value: value,
        action: action,
        engine: engine
      )
    else { return nil }
    let safeLimit = min(max(limit, 1), 1_000)
    return """
      SELECT *
      FROM \(qualifiedName(for: object, engine: engine))
      WHERE \(condition)
      LIMIT \(safeLimit);
      """
  }

  static func deleteMatching(
    from object: SchemaObject,
    column: String,
    value: QueryCellValue,
    engine: DatabaseEngine
  ) -> String? {
    guard
      let condition = condition(
        column: column,
        value: value,
        action: .equal,
        engine: engine
      )
    else { return nil }
    return """
      -- Review before running: this query may delete multiple rows.
      DELETE FROM \(qualifiedName(for: object, engine: engine))
      WHERE \(condition);
      """
  }

  private static func condition(
    column: String,
    value: QueryCellValue,
    action: ResultCellQueryAction,
    engine: DatabaseEngine
  ) -> String? {
    let quotedColumn = quote(column, engine: engine)
    switch action {
    case .equal:
      return value == .null
        ? "\(quotedColumn) IS NULL"
        : comparison(
          quotedColumn, operator: "=", value: value)
    case .notEqual:
      return value == .null
        ? "\(quotedColumn) IS NOT NULL"
        : comparison(
          quotedColumn, operator: "<>", value: value)
    case .contains, .startsWith, .endsWith:
      guard case .text(let text) = value else { return nil }
      return likeCondition(column: quotedColumn, value: text, action: action, engine: engine)
    case .isNull:
      return "\(quotedColumn) IS NULL"
    case .isNotNull:
      return "\(quotedColumn) IS NOT NULL"
    case .deleteMatching:
      return nil
    }
  }

  private static func comparison(
    _ column: String,
    operator: String,
    value: QueryCellValue
  ) -> String? {
    guard case .binary = value else {
      return "\(column) \(`operator`) \(value.sqlValue)"
    }
    return nil
  }

  private static func likeCondition(
    column: String,
    value: String,
    action: ResultCellQueryAction,
    engine: DatabaseEngine
  ) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    let pattern: String
    switch action {
    case .contains: pattern = "%\(escaped)%"
    case .startsWith: pattern = "\(escaped)%"
    case .endsWith: pattern = "%\(escaped)"
    default: pattern = escaped
    }
    let literal = "'\(pattern.replacingOccurrences(of: "'", with: "''"))'"
    let escapeClause =
      switch engine {
      case .postgresql: "ESCAPE E'\\\\'"
      case .mysql: "ESCAPE '\\\\'"
      case .sqlite: "ESCAPE '\\'"
      }
    return "\(column) LIKE \(literal) \(escapeClause)"
  }

  private static func followsFrom(_ identifier: String, in sql: String) -> Bool {
    let escapedIdentifier = NSRegularExpression.escapedPattern(for: identifier)
    return matches(#"\bFROM\s+"# + escapedIdentifier + #"(?=\s|;|$)"#, in: sql)
  }

  private static func matches(_ pattern: String, in sql: String) -> Bool {
    matchCount(of: pattern, in: sql) > 0
  }

  private static func matchCount(of pattern: String, in sql: String) -> Int {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return 0 }
    return expression.numberOfMatches(
      in: sql,
      range: NSRange(sql.startIndex..., in: sql)
    )
  }

  private static func isSafeUnquotedIdentifier(_ identifier: String) -> Bool {
    identifier.range(of: #"^[A-Za-z_][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
  }

  private static func quote(_ identifier: String, engine: DatabaseEngine) -> String {
    switch engine {
    case .mysql:
      return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    case .postgresql, .sqlite:
      return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
  }
}
