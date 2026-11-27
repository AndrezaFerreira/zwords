import ReplayKit
import SwiftUI

struct ControlBar: View {
    @EnvironmentObject private var engine: CaptionEngine
    @ObservedObject var pip: CaptionPiP

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // iPhone audio (system-wide broadcast)
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(engine.isDeviceAudioActive ? Color.red.opacity(0.15) : Color(.secondarySystemBackground))
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(engine.isDeviceAudioActive ? .red : .primary)
                        .allowsHitTesting(false)
                    BroadcastPicker()
                }
                .frame(width: 56, height: 56)
                Text(engine.isDeviceAudioActive ? "Parar iPhone" : "iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Legendar áudio do iPhone")

            // Microphone
            VStack(spacing: 6) {
                Button {
                    Task { await engine.toggleMic() }
                } label: {
                    ZStack {
                        Circle().fill(engine.isMicRunning ? Color.red : Color.accentColor)
                        Image(systemName: engine.isMicRunning ? "stop.fill" : "mic.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 72, height: 72)
                    .symbolEffect(.pulse, isActive: engine.isMicRunning)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .medium), trigger: engine.isMicRunning)
                Text(engine.isMicRunning ? "Ouvindo" : "Microfone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(engine.isMicRunning ? "Parar microfone" : "Legendar microfone")

            // Floating captions (PiP)
            VStack(spacing: 6) {
                Button {
                    engine.togglePiP()
                } label: {
                    ZStack {
                        Circle().fill(pip.isActive ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.title3)
                            .foregroundStyle(pip.isPossible || pip.isActive ? Color.primary : Color.secondary)
                    }
                    .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .disabled(!pip.isPossible && !pip.isActive)
                Text("Flutuante")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Legenda flutuante")
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// System broadcast picker (the only way to capture other apps' audio),
/// with its own icon hidden so it can sit under a SwiftUI label.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = TransparentBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.showsMicrophoneButton = false
        if let bundleID = Bundle.main.bundleIdentifier {
            picker.preferredExtension = bundleID + ".broadcast"
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

final class TransparentBroadcastPicker: RPSystemBroadcastPickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let button as UIButton in subviews {
            button.frame = bounds
            button.setImage(nil, for: .normal)
            button.setImage(nil, for: .highlighted)
            button.imageView?.isHidden = true
        }
    }
}
