import Foundation

/// Snapshot of the live transcription produced by the broadcast extension.
struct BroadcastSnapshot: Codable, Equatable {
    enum Status: String, Codable { case running, stopped, error }

    struct Segment: Codable, Equatable {
        var id: Int
        var text: String
        var isFinal: Bool
    }

    var sessionID: String
    var status: Status
    var message: String?
    var segments: [Segment]
    var updatedAt: Date
}

/// File + Darwin-notification channel between the extension and the app.
enum BroadcastChannel {
    static let notificationName = "com.zwords.live.broadcast.changed"

    static var snapshotURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("broadcast.json")
    }

    static func write(_ snapshot: BroadcastSnapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true
        )
    }

    static func read() -> BroadcastSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BroadcastSnapshot.self, from: data)
    }
}
