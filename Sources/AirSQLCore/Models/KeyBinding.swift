/// A shortcut chosen in Settings ▸ Keys: a key and its modifiers as AppKit's raw flags. An empty key: no shortcut.
public struct KeyBinding: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: UInt

    public init(key: String, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers
    }
}
