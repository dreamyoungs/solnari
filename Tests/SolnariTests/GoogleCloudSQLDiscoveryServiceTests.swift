import Foundation
import Testing

@testable import Solnari

struct GoogleCloudSQLDiscoveryServiceTests {
  @Test("프로젝트 instance 목록에서 engine과 region을 안전하게 해석한다")
  func instancesDecodeWithoutPuttingTheTokenInTheURL() async throws {
    let recorder = RequestRecorder()
    let responseData = Data(
      """
      {
        "items": [
          {"name":"orders","region":"asia-northeast3","databaseVersion":"POSTGRES_17","state":"RUNNABLE"},
          {"name":"catalog","region":"us-central1","databaseVersion":"MYSQL_8_0","state":"RUNNABLE"},
          {"name":"ignored","region":"us-central1","databaseVersion":"SQLSERVER_2022_STANDARD","state":"RUNNABLE"}
        ]
      }
      """.utf8
    )
    let service = GoogleCloudSQLDiscoveryService(
      tokenLoader: { "secret-access-token" },
      dataLoader: { request in
        await recorder.record(request)
        return (responseData, Self.response(for: request, statusCode: 200))
      }
    )

    let instances = try await service.instances(project: "sample-project")
    let request = try #require(await recorder.lastRequest)

    #expect(instances.map(\.name) == ["catalog", "orders"])
    #expect(instances.first(where: { $0.name == "orders" })?.engine == .postgresql)
    #expect(instances.first(where: { $0.name == "orders" })?.region == "asia-northeast3")
    #expect(request.url?.absoluteString.contains("secret-access-token") == false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-access-token")
    #expect(request.value(forHTTPHeaderField: "X-Goog-User-Project") == "sample-project")
  }

  @Test("선택한 instance의 database 이름을 정렬해 반환한다")
  func databasesAreSorted() async throws {
    let responseData = Data(
      """
      {"items":[{"name":"postgres"},{"name":"app"},{"name":"analytics"}]}
      """.utf8
    )
    let service = GoogleCloudSQLDiscoveryService(
      tokenLoader: { "token" },
      dataLoader: { request in
        (responseData, Self.response(for: request, statusCode: 200))
      }
    )

    let databases = try await service.databases(
      project: "sample-project",
      instance: "primary"
    )

    #expect(databases == ["analytics", "app", "postgres"])
  }

  @Test("권한 없음과 잘못된 project ID를 fail closed로 구분한다")
  func failuresAreFailClosed() async {
    let service = GoogleCloudSQLDiscoveryService(
      tokenLoader: { "token" },
      dataLoader: { request in
        (Data(), Self.response(for: request, statusCode: 403))
      }
    )

    await #expect(throws: CloudSQLDiscoveryError.self) {
      try await service.instances(project: "sample-project")
    }
    await #expect(throws: CloudSQLDiscoveryError.self) {
      try await service.instances(project: "not valid")
    }
  }

  private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
  }
}

private actor RequestRecorder {
  private(set) var lastRequest: URLRequest?

  func record(_ request: URLRequest) {
    lastRequest = request
  }
}
