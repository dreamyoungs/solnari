enum SingleLineText {
  static func normalized(_ value: String) -> String {
    guard let lineBreak = value.firstIndex(where: \.isNewline) else { return value }
    return String(value[..<lineBreak])
  }
}
