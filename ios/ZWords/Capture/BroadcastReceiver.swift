import Foundation

/// Listens for caption updates written by the broadcast extension.
@MainActor
final class BroadcastReceiver {
    var onSnapshot: ((BroadcastSnapshot) -> Void)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let receiver = Unmanaged<BroadcastReceiver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { receiver.read() }
                }
            },
            BroadcastChannel.notificationName as CFString, nil, .deliverImmediately)
        read()
    }

    func read() {
        guard let snapshot = BroadcastChannel.read() else { return }
        onSnapshot?(snapshot)
    }
}
