import Foundation

enum BackendTime {
  static func milliseconds(from duration: Duration) -> Int {
    let components = duration.components
    let seconds = components.seconds * 1_000
    let attoseconds = components.attoseconds / 1_000_000_000_000_000
    return Int(clamping: seconds + attoseconds)
  }
}
