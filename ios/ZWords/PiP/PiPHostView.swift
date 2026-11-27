import SwiftUI
import UIKit

/// Hosts the AVSampleBufferDisplayLayer that feeds Picture in Picture.
struct PiPHostView: UIViewRepresentable {
    let pip: CaptionPiP

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.layer.addSublayer(pip.displayLayer)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    final class HostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}
