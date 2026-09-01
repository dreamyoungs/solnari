import Testing

@testable import Solnari

struct GoogleCloudSQLDiscoveryServiceTests {
  @Test("Node backend가 반환한 Cloud SQL instance 목록을 그대로 전달한다")
  func instancesLoadThroughNodeBoundary() async throws {
    let requestedProjects = Recorder<String>()
    let service = GoogleCloudSQLDiscoveryService(
      instanceLoader: { project in
        await requestedProjects.record(project)
        return [
          CloudSQLInstanceSummary(
            name: "orders",
            region: "asia-northeast3",
            engine: .postgresql,
            state: "RUNNABLE"
          )
        ]
      },
      databaseLoader: { _, _ in [] }
    )

    let instances = try await service.instances(project: "Sample-Project")

    #expect(await requestedProjects.lastValue == "sample-project")
    #expect(instances.map(\.name) == ["orders"])
    #expect(instances.first?.engine == .postgresql)
  }

  @Test("선택한 instance의 database 목록은 Node backend에서 불러온다")
  func databasesLoadThroughNodeBoundary() async throws {
    let requestedValues = Recorder<[String]>()
    let service = GoogleCloudSQLDiscoveryService(
      instanceLoader: { _ in [] },
      databaseLoader: { project, instance in
        await requestedValues.record([project, instance])
        return ["analytics", "app", "postgres"]
      }
    )

    let databases = try await service.databases(
      project: "sample-project",
      instance: "primary"
    )

    #expect(await requestedValues.lastValue == ["sample-project", "primary"])
    #expect(databases == ["analytics", "app", "postgres"])
  }

  @Test("잘못된 project와 instance identifier는 Node로 보내지 않는다")
  func identifiersAreValidatedBeforeNodeRequest() async {
    let service = GoogleCloudSQLDiscoveryService(
      instanceLoader: { _ in [] },
      databaseLoader: { _, _ in [] }
    )

    await #expect(throws: CloudSQLDiscoveryError.self) {
      try await service.instances(project: "not valid")
    }
    await #expect(throws: CloudSQLDiscoveryError.self) {
      try await service.databases(project: "sample-project", instance: "../../unsafe")
    }
    await #expect(throws: CloudSQLDiscoveryError.self) {
      try await service.users(project: "sample-project", instance: "../../unsafe")
    }
  }

  @Test("IAM database user 후보도 Node backend에서 불러온다")
  func usersLoadThroughNodeBoundary() async throws {
    let requestedValues = Recorder<[String]>()
    let service = GoogleCloudSQLDiscoveryService(
      instanceLoader: { _ in [] },
      databaseLoader: { _, _ in [] },
      userLoader: { project, instance in
        await requestedValues.record([project, instance])
        return [CloudSQLUserSummary(name: "developer@example.com", type: "CLOUD_IAM_USER")]
      }
    )

    let users = try await service.users(project: "sample-project", instance: "primary")

    #expect(await requestedValues.lastValue == ["sample-project", "primary"])
    #expect(users.map(\.name) == ["developer@example.com"])
    #expect(users.allSatisfy { $0.isIAMUser })
  }
}

private actor Recorder<Value: Sendable> {
  private(set) var lastValue: Value?

  func record(_ value: Value) {
    lastValue = value
  }
}
