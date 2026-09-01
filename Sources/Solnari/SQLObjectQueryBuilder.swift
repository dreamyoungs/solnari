import Foundation

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

  private static func quote(_ identifier: String, engine: DatabaseEngine) -> String {
    switch engine {
    case .mysql:
      return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    case .postgresql, .sqlite:
      return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
  }
}
