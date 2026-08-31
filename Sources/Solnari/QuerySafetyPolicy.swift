import Foundation

enum QuerySafetyPolicy {
  private static let readOnlyStarts = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN"]
  private static let mutatingKeywords: Set<String> = [
    "ALTER", "ANALYZE", "ATTACH", "BEGIN", "CALL", "COMMIT", "COPY", "CREATE", "DELETE",
    "DETACH", "DO", "DROP", "GRANT", "INSERT", "INTO", "LOAD", "LOCK", "MERGE", "PRAGMA",
    "REINDEX", "RELEASE", "RENAME", "REPLACE", "RESET", "REVOKE", "ROLLBACK", "SAVEPOINT",
    "SET", "TRUNCATE", "UPDATE", "VACUUM",
  ]

  static func validate(sql: String, accessLevel: DatabaseAccessLevel) throws {
    switch accessLevel {
    case .readWrite:
      return
    case .migration:
      throw SolnariDatabaseError.queryNotAllowedForAccessLevel
    case .readOnly:
      let statements = SQLTokenScanner(sql: sql).statements()
      guard statements.count == 1, let first = statements[0].first,
        readOnlyStarts.contains(first), mutatingKeywords.isDisjoint(with: statements[0])
      else {
        throw SolnariDatabaseError.queryNotAllowedForAccessLevel
      }
    }
  }
}

private struct SQLTokenScanner {
  private let characters: [Character]

  init(sql: String) {
    characters = Array(sql)
  }

  func statements() -> [[String]] {
    var result: [[String]] = []
    var tokens: [String] = []
    var index = 0

    func finishStatement() {
      if !tokens.isEmpty {
        result.append(tokens)
        tokens.removeAll(keepingCapacity: true)
      }
    }

    while index < characters.count {
      let character = characters[index]
      if character == "-", peek(index + 1) == "-" {
        index = skipLine(from: index + 2)
      } else if character == "#" {
        index = skipLine(from: index + 1)
      } else if character == "/", peek(index + 1) == "*" {
        index = skipBlockComment(from: index + 2)
      } else if character == "'" || character == "\"" || character == "`" {
        index = skipQuoted(from: index + 1, quote: character)
      } else if character == "$", let delimiter = dollarQuoteDelimiter(at: index) {
        index = skipDollarQuote(from: index + delimiter.count, delimiter: delimiter)
      } else if character == ";" {
        finishStatement()
        index += 1
      } else if character.isLetter || character == "_" {
        let start = index
        index += 1
        while index < characters.count,
          characters[index].isLetter || characters[index].isNumber || characters[index] == "_"
        {
          index += 1
        }
        tokens.append(String(characters[start..<index]).uppercased())
      } else {
        index += 1
      }
    }
    finishStatement()
    return result
  }

  private func peek(_ index: Int) -> Character? {
    characters.indices.contains(index) ? characters[index] : nil
  }

  private func skipLine(from start: Int) -> Int {
    var index = start
    while index < characters.count, characters[index] != "\n" { index += 1 }
    return index
  }

  private func skipBlockComment(from start: Int) -> Int {
    var index = start
    while index < characters.count {
      if characters[index] == "*", peek(index + 1) == "/" { return index + 2 }
      index += 1
    }
    return index
  }

  private func skipQuoted(from start: Int, quote: Character) -> Int {
    var index = start
    while index < characters.count {
      if characters[index] == quote {
        if peek(index + 1) == quote {
          index += 2
          continue
        }
        return index + 1
      }
      if characters[index] == "\\", quote != "\"" { index += 1 }
      index += 1
    }
    return index
  }

  private func dollarQuoteDelimiter(at start: Int) -> [Character]? {
    var index = start + 1
    while index < characters.count,
      characters[index].isLetter || characters[index].isNumber || characters[index] == "_"
    {
      index += 1
    }
    guard index < characters.count, characters[index] == "$" else { return nil }
    return Array(characters[start...index])
  }

  private func skipDollarQuote(from start: Int, delimiter: [Character]) -> Int {
    var index = start
    while index + delimiter.count <= characters.count {
      if Array(characters[index..<(index + delimiter.count)]) == delimiter {
        return index + delimiter.count
      }
      index += 1
    }
    return index
  }
}
