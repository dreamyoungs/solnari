import Foundation

struct GoogleCloudIdentity: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case applicationDefaultCredentials
    case activeGcloudSuggestion
  }

  let email: String
  let source: Source

  init(email: String, source: Source = .applicationDefaultCredentials) {
    self.email = email
    self.source = source
  }

  var isServiceAccount: Bool {
    email.lowercased().hasSuffix(".gserviceaccount.com")
  }

  func databaseUsername(for engine: DatabaseEngine) -> String {
    let normalized = email.lowercased()
    switch engine {
    case .postgresql:
      return isServiceAccount
        ? String(normalized.dropLast(".gserviceaccount.com".count)) : normalized
    case .mysql:
      return normalized.split(separator: "@", maxSplits: 1).first.map(String.init) ?? normalized
    case .sqlite:
      return ""
    }
  }
}

actor GoogleCloudIdentityResolver {
  private struct CredentialMetadata: Decodable {
    let type: String?
    let account: String?
    let clientEmail: String?
    let serviceAccountImpersonationURL: String?

    enum CodingKeys: String, CodingKey {
      case type
      case account
      case clientEmail = "client_email"
      case serviceAccountImpersonationURL = "service_account_impersonation_url"
    }
  }

  private struct UserInfo: Decodable {
    let email: String?
    let emailVerified: Bool?

    enum CodingKeys: String, CodingKey {
      case email
      case emailVerified = "email_verified"
    }
  }

  func resolve() async -> GoogleCloudIdentity? {
    if let identity = identityFromCredentialConfiguration() {
      return identity
    }
    do {
      let token = try await applicationDefaultAccessToken()
      if let identity = try await identityFromUserInfo(accessToken: token) {
        return identity
      }
    } catch {
      // 이메일 scope가 없는 기존 ADC는 아래의 명시적인 gcloud 계정 제안으로 처리한다.
    }
    guard usesStandardUserADC(), let account = try? await activeGcloudAccount() else {
      return nil
    }
    return GoogleCloudIdentity(email: account, source: .activeGcloudSuggestion)
  }

  private func identityFromCredentialConfiguration() -> GoogleCloudIdentity? {
    guard let url = credentialConfigurationURL(),
      let data = try? Data(contentsOf: url),
      let metadata = try? JSONDecoder().decode(CredentialMetadata.self, from: data)
    else { return nil }

    if let email = metadata.clientEmail, !email.isEmpty {
      return GoogleCloudIdentity(email: email)
    }
    if let account = metadata.account, account.contains("@") {
      return GoogleCloudIdentity(email: account)
    }
    guard let rawURL = metadata.serviceAccountImpersonationURL,
      let url = URL(string: rawURL),
      var component = url.pathComponents.last?.removingPercentEncoding
    else { return nil }
    if component.hasSuffix(":generateAccessToken") {
      component.removeLast(":generateAccessToken".count)
    }
    return component.contains("@") ? GoogleCloudIdentity(email: component) : nil
  }

  private func credentialConfigurationURL() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let configuredPath = environment["GOOGLE_APPLICATION_CREDENTIALS"],
      !configuredPath.isEmpty
    {
      return URL(fileURLWithPath: configuredPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/gcloud/application_default_credentials.json")
  }

  private func applicationDefaultAccessToken() async throws -> String {
    try await gcloudOutput(
      arguments: ["auth", "application-default", "print-access-token", "--quiet"])
  }

  private func activeGcloudAccount() async throws -> String {
    let account = try await gcloudOutput(
      arguments: [
        "auth", "list", "--filter=status:ACTIVE", "--format=value(account)", "--quiet",
      ])
    guard account.contains("@") else {
      throw SolnariDatabaseError.transportFailed("The active gcloud account is unavailable.")
    }
    return account
  }

  private func usesStandardUserADC() -> Bool {
    guard ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"] == nil,
      let url = credentialConfigurationURL(),
      let data = try? Data(contentsOf: url),
      let metadata = try? JSONDecoder().decode(CredentialMetadata.self, from: data)
    else { return false }
    return metadata.type == "authorized_user"
  }

  private func gcloudOutput(arguments: [String]) async throws -> String {
    let executable = try ExecutableResolver.resolve(
      name: "gcloud", environmentKey: "SOLNARI_GCLOUD")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
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
    guard result.0 == 0 else {
      throw SolnariDatabaseError.transportFailed("ADC is unavailable.")
    }
    let value = String(decoding: result.1, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw SolnariDatabaseError.transportFailed("gcloud returned an empty value.")
    }
    return value
  }

  private func identityFromUserInfo(accessToken: String) async throws -> GoogleCloudIdentity? {
    guard let url = URL(string: "https://openidconnect.googleapis.com/v1/userinfo") else {
      return nil
    }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      data.count <= 16_384
    else { return nil }
    let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
    guard userInfo.emailVerified != false, let email = userInfo.email, !email.isEmpty else {
      return nil
    }
    return GoogleCloudIdentity(email: email)
  }
}
