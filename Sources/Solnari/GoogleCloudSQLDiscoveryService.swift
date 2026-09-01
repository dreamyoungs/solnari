import Foundation

struct CloudSQLInstanceSummary: Identifiable, Hashable, Codable, Sendable {
  let name: String
  let region: String
  let engine: DatabaseEngine
  let state: String

  var id: String { name }
}

struct CloudSQLUserSummary: Identifiable, Hashable, Codable, Sendable {
  let name: String
  let type: String

  var id: String { "\(type):\(name)" }
  var isIAMUser: Bool { type.hasPrefix("CLOUD_IAM") && type != "CLOUD_IAM_GROUP" }
}

enum CloudSQLDiscoveryError: LocalizedError, Sendable {
  case invalidProject
  case authenticationUnavailable
  case permissionDenied
  case apiUnavailable
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidProject: "Enter a valid Google Cloud project ID."
    case .authenticationUnavailable: "Application Default Credentials are unavailable."
    case .permissionDenied: "The ADC account cannot list Cloud SQL resources in this project."
    case .apiUnavailable: "The Cloud SQL Admin API is unavailable for this project."
    case .invalidResponse: "Cloud SQL returned an unexpected response."
    }
  }
}

actor GoogleCloudSQLDiscoveryService {
  typealias InstanceLoader = @Sendable (String) async throws -> [CloudSQLInstanceSummary]
  typealias DatabaseLoader = @Sendable (String, String) async throws -> [String]
  typealias UserLoader = @Sendable (String, String) async throws -> [CloudSQLUserSummary]

  private struct ProjectParameters: Codable, Sendable {
    let project: String
  }

  private struct DatabaseParameters: Codable, Sendable {
    let project: String
    let instance: String
  }

  private let instanceLoader: InstanceLoader
  private let databaseLoader: DatabaseLoader
  private let userLoader: UserLoader

  init(
    instanceLoader: @escaping InstanceLoader = GoogleCloudSQLDiscoveryService.loadInstances,
    databaseLoader: @escaping DatabaseLoader = GoogleCloudSQLDiscoveryService.loadDatabases,
    userLoader: @escaping UserLoader = GoogleCloudSQLDiscoveryService.loadUsers
  ) {
    self.instanceLoader = instanceLoader
    self.databaseLoader = databaseLoader
    self.userLoader = userLoader
  }

  func instances(project: String) async throws -> [CloudSQLInstanceSummary] {
    let project = try validatedProject(project)
    do {
      return try await instanceLoader(project)
    } catch let error as NodeBackendError {
      throw Self.discoveryError(from: error)
    } catch {
      throw CloudSQLDiscoveryError.invalidResponse
    }
  }

  func databases(project: String, instance: String) async throws -> [String] {
    let project = try validatedProject(project)
    guard
      instance.range(
        of: "^[A-Za-z0-9_-]{1,98}$",
        options: .regularExpression
      ) != nil
    else {
      throw CloudSQLDiscoveryError.invalidResponse
    }
    do {
      return try await databaseLoader(project, instance)
    } catch let error as NodeBackendError {
      throw Self.discoveryError(from: error)
    } catch {
      throw CloudSQLDiscoveryError.invalidResponse
    }
  }

  func users(project: String, instance: String) async throws -> [CloudSQLUserSummary] {
    let project = try validatedProject(project)
    guard
      instance.range(
        of: "^[A-Za-z0-9_-]{1,98}$",
        options: .regularExpression
      ) != nil
    else {
      throw CloudSQLDiscoveryError.invalidResponse
    }
    do {
      return try await userLoader(project, instance)
    } catch let error as NodeBackendError {
      throw Self.discoveryError(from: error)
    } catch {
      throw CloudSQLDiscoveryError.invalidResponse
    }
  }

  private func validatedProject(_ value: String) throws -> String {
    let project = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard
      project.range(
        of: "^[a-z][a-z0-9-]{4,28}[a-z0-9]$",
        options: .regularExpression
      ) != nil
    else {
      throw CloudSQLDiscoveryError.invalidProject
    }
    return project
  }

  private static func loadInstances(_ project: String) async throws
    -> [CloudSQLInstanceSummary]
  {
    try await NodeBackendClient.shared.call(
      method: "cloudSql.instances",
      params: ProjectParameters(project: project)
    )
  }

  private static func loadDatabases(_ project: String, _ instance: String) async throws
    -> [String]
  {
    try await NodeBackendClient.shared.call(
      method: "cloudSql.databases",
      params: DatabaseParameters(project: project, instance: instance)
    )
  }

  private static func loadUsers(_ project: String, _ instance: String) async throws
    -> [CloudSQLUserSummary]
  {
    try await NodeBackendClient.shared.call(
      method: "cloudSql.users",
      params: DatabaseParameters(project: project, instance: instance)
    )
  }

  private static func discoveryError(from error: NodeBackendError) -> CloudSQLDiscoveryError {
    guard case .backend(let code, _) = error else { return .authenticationUnavailable }
    return switch code {
    case "GOOGLE_PERMISSION_DENIED": .permissionDenied
    case "GOOGLE_API_UNAVAILABLE": .apiUnavailable
    case "GOOGLE_AUTHENTICATION_UNAVAILABLE": .authenticationUnavailable
    default: .invalidResponse
    }
  }
}
