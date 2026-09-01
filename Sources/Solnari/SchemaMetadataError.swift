import Foundation

enum SchemaMetadataStage: String, Sendable {
  case columns = "Columns"
  case indexes = "Indexes"
  case constraints = "Constraints"
  case definition = "Definition"
}

enum SchemaMetadataFailureReason: Sendable {
  case permissionDenied
  case incompatibleQuery
  case cancelled
  case databaseRejected
}

struct SchemaMetadataError: LocalizedError, Sendable {
  let stage: SchemaMetadataStage
  let reason: SchemaMetadataFailureReason
  let sqlState: String?

  var messageKey: String {
    switch reason {
    case .permissionDenied:
      "The database account cannot read this schema metadata."
    case .incompatibleQuery:
      "Solnari's metadata query is not compatible with this PostgreSQL server."
    case .cancelled:
      "The schema metadata query was cancelled."
    case .databaseRejected:
      "The database rejected the schema metadata query."
    }
  }

  var diagnosticCode: String {
    sqlState.map { "SQLSTATE \($0)" } ?? "SCHEMA-METADATA"
  }

  var errorDescription: String? {
    "\(messageKey) · \(stage.rawValue) · \(diagnosticCode)"
  }
}
