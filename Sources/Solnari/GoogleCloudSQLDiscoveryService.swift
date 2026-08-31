import Foundation

struct CloudSQLInstanceSummary: Identifiable, Hashable, Sendable {
  let name: String
  let region: String
  let engine: DatabaseEngine
  let state: String

  var id: String { name }
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
  typealias TokenLoader = @Sendable () async throws -> String
  typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private struct InstancesResponse: Decodable {
    struct Instance: Decodable {
      let name: String
      let region: String?
      let databaseVersion: String
      let state: String?
    }

    let items: [Instance]?
  }

  private struct DatabasesResponse: Decodable {
    struct Database: Decodable {
      let name: String
    }

    let items: [Database]?
  }

  private let tokenLoader: TokenLoader
  private let dataLoader: DataLoader

  init(
    tokenLoader: @escaping TokenLoader = GoogleCloudSQLDiscoveryService.loadADCAccessToken,
    dataLoader: @escaping DataLoader = GoogleCloudSQLDiscoveryService.loadData
  ) {
    self.tokenLoader = tokenLoader
    self.dataLoader = dataLoader
  }

  func instances(project: String) async throws -> [CloudSQLInstanceSummary] {
    let project = try validatedProject(project)
    let response: InstancesResponse = try await request(
      project: project,
      path: "/v1/projects/\(project)/instances",
      queryItems: [
        URLQueryItem(name: "filter", value: "instanceType:CLOUD_SQL_INSTANCE"),
        URLQueryItem(name: "maxResults", value: "1000"),
      ]
    )
    return (response.items ?? []).compactMap { instance in
      let engine: DatabaseEngine
      if instance.databaseVersion.hasPrefix("POSTGRES_") {
        engine = .postgresql
      } else if instance.databaseVersion.hasPrefix("MYSQL_") {
        engine = .mysql
      } else {
        return nil
      }
      return CloudSQLInstanceSummary(
        name: instance.name,
        region: instance.region ?? "",
        engine: engine,
        state: instance.state ?? "UNKNOWN"
      )
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func databases(project: String, instance: String) async throws -> [String] {
    let project = try validatedProject(project)
    guard
      let encodedInstance = instance.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
      ), !encodedInstance.isEmpty
    else {
      throw CloudSQLDiscoveryError.invalidResponse
    }
    let response: DatabasesResponse = try await request(
      project: project,
      path: "/v1/projects/\(project)/instances/\(encodedInstance)/databases",
      queryItems: []
    )
    return (response.items ?? []).map(\.name).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }

  private func request<Response: Decodable>(
    project: String,
    path: String,
    queryItems: [URLQueryItem]
  ) async throws -> Response {
    let token: String
    do {
      token = try await tokenLoader()
    } catch {
      throw CloudSQLDiscoveryError.authenticationUnavailable
    }
    guard !token.isEmpty else { throw CloudSQLDiscoveryError.authenticationUnavailable }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "sqladmin.googleapis.com"
    components.percentEncodedPath = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw CloudSQLDiscoveryError.invalidResponse }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(project, forHTTPHeaderField: "X-Goog-User-Project")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await dataLoader(request)
    guard data.count <= 8_388_608 else { throw CloudSQLDiscoveryError.invalidResponse }
    switch response.statusCode {
    case 200..<300:
      return try JSONDecoder().decode(Response.self, from: data)
    case 401:
      throw CloudSQLDiscoveryError.authenticationUnavailable
    case 403:
      throw CloudSQLDiscoveryError.permissionDenied
    case 404:
      throw CloudSQLDiscoveryError.apiUnavailable
    default:
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

  private static func loadADCAccessToken() async throws -> String {
    let executable = try ExecutableResolver.resolve(
      name: "gcloud",
      environmentKey: "SOLNARI_GCLOUD"
    )
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["auth", "application-default", "print-access-token", "--quiet"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let result: (Int32, Data) = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        continuation.resume(
          returning: (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile()))
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
    guard result.0 == 0, result.1.count <= 16_384 else {
      throw CloudSQLDiscoveryError.authenticationUnavailable
    }
    let token = String(decoding: result.1, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw CloudSQLDiscoveryError.authenticationUnavailable }
    return token
  }

  private static func loadData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw CloudSQLDiscoveryError.invalidResponse
    }
    return (data, response)
  }
}
