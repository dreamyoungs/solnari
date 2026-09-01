import Darwin
import Foundation

struct MCPBridgeRequest: Codable, Sendable {
  let id: String
  let method: String
  let paramsJSON: String?
}

struct MCPBridgeResponse: Codable, Sendable {
  let id: String
  let ok: Bool
  let resultJSON: String?
  let error: String?

  static func success(id: String, resultJSON: String) -> MCPBridgeResponse {
    MCPBridgeResponse(id: id, ok: true, resultJSON: resultJSON, error: nil)
  }

  static func failure(id: String, message: String) -> MCPBridgeResponse {
    MCPBridgeResponse(id: id, ok: false, resultJSON: nil, error: message)
  }
}

final class LocalMCPBridge: @unchecked Sendable {
  typealias RequestHandler = @Sendable (MCPBridgeRequest) async -> MCPBridgeResponse

  static var defaultSocketURL: URL {
    let applicationSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return
      applicationSupport
      .appendingPathComponent("Solnari", isDirectory: true)
      .appendingPathComponent("mcp.sock", isDirectory: false)
  }

  private let socketURL: URL
  private let handler: RequestHandler
  private let listenerDescriptor: Int32
  private let acceptQueue = DispatchQueue(label: "com.dreamyoungs.solnari.mcp.accept")
  private let clientQueue = DispatchQueue(
    label: "com.dreamyoungs.solnari.mcp.clients",
    attributes: .concurrent
  )
  private let stateLock = NSLock()
  private var isStopped = false
  private var clientDescriptors: Set<Int32> = []

  init(
    socketURL: URL = LocalMCPBridge.defaultSocketURL,
    handler: @escaping RequestHandler
  ) throws {
    self.socketURL = socketURL
    self.handler = handler

    let directory = socketURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if FileManager.default.fileExists(atPath: socketURL.path) {
      try FileManager.default.removeItem(at: socketURL)
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTSOCK)
    }
    listenerDescriptor = descriptor

    do {
      try Self.bind(descriptor: descriptor, path: socketURL.path)
      guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
      }
      guard Darwin.listen(descriptor, 8) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
      }
      _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    } catch {
      Darwin.close(descriptor)
      try? FileManager.default.removeItem(at: socketURL)
      throw error
    }
  }

  deinit {
    stop()
  }

  func start() {
    acceptQueue.async { [weak self] in
      self?.acceptConnections()
    }
  }

  func stop() {
    stateLock.lock()
    guard !isStopped else {
      stateLock.unlock()
      return
    }
    isStopped = true
    let clients = clientDescriptors
    clientDescriptors.removeAll()
    stateLock.unlock()

    Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
    Darwin.close(listenerDescriptor)
    for descriptor in clients {
      Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
    try? FileManager.default.removeItem(at: socketURL)
  }

  private func acceptConnections() {
    while !stopped {
      let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
      if descriptor < 0 {
        if errno == EINTR { continue }
        return
      }
      _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      var timeout = timeval(tv_sec: 60, tv_usec: 0)
      _ = withUnsafePointer(to: &timeout) {
        Darwin.setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_RCVTIMEO,
          $0,
          socklen_t(MemoryLayout<timeval>.size)
        )
      }
      _ = withUnsafePointer(to: &timeout) {
        Darwin.setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_SNDTIMEO,
          $0,
          socklen_t(MemoryLayout<timeval>.size)
        )
      }
      registerClient(descriptor)
      clientQueue.async { [weak self] in
        self?.receiveRequest(from: descriptor)
      }
    }
  }

  private func receiveRequest(from descriptor: Int32) {
    guard let data = readLine(from: descriptor, maximumBytes: 1_048_576) else {
      closeClient(descriptor)
      return
    }

    let request: MCPBridgeRequest
    do {
      request = try JSONDecoder().decode(MCPBridgeRequest.self, from: data)
    } catch {
      write(
        MCPBridgeResponse.failure(id: "invalid", message: "The MCP bridge request is invalid."),
        to: descriptor
      )
      closeClient(descriptor)
      return
    }

    Task { [weak self] in
      guard let self else { return }
      let response = await handler(request)
      write(response, to: descriptor)
      closeClient(descriptor)
    }
  }

  private func readLine(from descriptor: Int32, maximumBytes: Int) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count <= maximumBytes {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count <= 0 { return nil }
      data.append(buffer, count: count)
      if let newline = data.firstIndex(of: 0x0A) {
        return data.prefix(upTo: newline)
      }
    }
    return nil
  }

  private func write(_ response: MCPBridgeResponse, to descriptor: Int32) {
    guard var data = try? JSONEncoder().encode(response), data.count <= 2_500_000 else { return }
    data.append(0x0A)
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          bytes.count - written
        )
        if count <= 0 { return }
        written += count
      }
    }
  }

  private var stopped: Bool {
    stateLock.withLock { isStopped }
  }

  private func registerClient(_ descriptor: Int32) {
    stateLock.withLock {
      guard !isStopped else {
        Darwin.close(descriptor)
        return
      }
      clientDescriptors.insert(descriptor)
    }
  }

  private func closeClient(_ descriptor: Int32) {
    let shouldClose = stateLock.withLock {
      clientDescriptors.remove(descriptor) != nil
    }
    guard shouldClose else { return }
    Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }

  private static func bind(descriptor: Int32, path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else {
      throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: path])
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        path.withCString { source in
          _ = Darwin.strlcpy(destination, source, capacity)
        }
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, length)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
