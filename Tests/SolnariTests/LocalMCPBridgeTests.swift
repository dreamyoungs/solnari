import Darwin
import Foundation
import Testing

@testable import Solnari

struct LocalMCPBridgeTests {
  @Test("로컬 MCP 브리지는 사용자 전용 소켓으로 한 요청을 교환한다")
  func exchangesOneRequestOverUserOnlySocket() throws {
    let identifier = UUID().uuidString.prefix(8)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("smcp-\(identifier)", isDirectory: true)
    let socketURL = directory.appendingPathComponent("bridge.sock")
    defer { try? FileManager.default.removeItem(at: directory) }

    let bridge = try LocalMCPBridge(socketURL: socketURL) { request in
      MCPBridgeResponse.success(
        id: request.id,
        resultJSON: #"{"status":"ready"}"#
      )
    }
    bridge.start()
    defer { bridge.stop() }

    let permissions = try #require(
      FileManager.default.attributesOfItem(atPath: socketURL.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o777 == 0o600)
    let directoryPermissions = try #require(
      FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    )
    #expect(directoryPermissions.intValue & 0o777 == 0o700)

    let request = MCPBridgeRequest(
      id: "test-request",
      method: "status",
      paramsJSON: "{}"
    )
    let response = try exchange(request, socketPath: socketURL.path)

    #expect(response.id == request.id)
    #expect(response.ok)
    #expect(response.resultJSON == #"{"status":"ready"}"#)
    #expect(response.error == nil)
  }

  private func exchange(_ request: MCPBridgeRequest, socketPath: String) throws
    -> MCPBridgeResponse
  {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    defer { Darwin.close(descriptor) }

    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) {
      Darwin.setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        $0,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        socketPath.withCString { source in
          _ = Darwin.strlcpy(destination, source, capacity)
        }
      }
    }
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    guard connected == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }

    var requestData = try JSONEncoder().encode(request)
    requestData.append(0x0A)
    try requestData.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          bytes.count - written
        )
        guard count > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        written += count
      }
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while responseData.count <= 2_500_000 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count > 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      responseData.append(buffer, count: count)
      if let newline = responseData.firstIndex(of: 0x0A) {
        return try JSONDecoder().decode(
          MCPBridgeResponse.self,
          from: responseData.prefix(upTo: newline)
        )
      }
    }
    throw MCPAccessError.responseTooLarge
  }
}
