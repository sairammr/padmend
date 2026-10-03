import Foundation
import PadmendCore

public struct Settings: Codable, Sendable {
    public var tracker: TrackerConfig
    public var pointer: PointerConfig
    public var gesture: GestureConfig
    /// Whether takeover should start automatically.
    public var enabledAtLaunch: Bool
    /// Drop the click macOS synthesises from a contact this program judged to
    /// be sensor noise.
    public var suppressPhantomClicks: Bool
    /// What a three-finger swipe should do.
    public var threeFingerSwipes: Bool
    /// What a four-finger swipe should do.
    public var fourFingerSwipes: Bool

    public init(tracker: TrackerConfig = .default,
                pointer: PointerConfig = .default,
                gesture: GestureConfig = .default,
                enabledAtLaunch: Bool = true,
                suppressPhantomClicks: Bool = true,
                threeFingerSwipes: Bool = true,
                fourFingerSwipes: Bool = true) {
        self.tracker = tracker
        self.pointer = pointer
        self.gesture = gesture
        self.enabledAtLaunch = enabledAtLaunch
        self.suppressPhantomClicks = suppressPhantomClicks
        self.threeFingerSwipes = threeFingerSwipes
        self.fourFingerSwipes = fourFingerSwipes
    }

    public static let `default` = Settings()
}

/// Where the dead map and settings live on disk.
public enum Store {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("padmend", isDirectory: true)
    }

    public static var deadMapURL: URL {
        directory.appendingPathComponent("deadmap.json")
    }

    public static var settingsURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static func save(_ map: DeadMap) throws {
        try write(encoder.encode(map), to: deadMapURL)
    }

    public static func loadDeadMap() -> DeadMap? {
        guard let data = try? Data(contentsOf: deadMapURL) else { return nil }
        return try? JSONDecoder().decode(DeadMap.self, from: data)
    }

    public static func save(_ settings: Settings) throws {
        try write(encoder.encode(settings), to: settingsURL)
    }

    public static func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return settings
    }

    public static func removeDeadMap() throws {
        guard FileManager.default.fileExists(atPath: deadMapURL.path) else { return }
        try FileManager.default.removeItem(at: deadMapURL)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
