// Development-only iOS Probe. Build as an ordinary app, never a test Runner.
// No network, clipboard or text-injection API. Visible editing buttons load a
// disposable seed/selection; sample buttons only clear and set an expected value.
import SwiftUI
import UIKit

@main struct NativeTextProbeApp: App {
    var body: some Scene { WindowGroup { TextProbe().ignoresSafeArea(.keyboard) } }
}

private struct TextProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        if ProcessInfo.processInfo.arguments.contains("--preview-scroll-probe") {
            return PreviewScrollProbeController()
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-motion-probe") {
            return PreviewMotionProbeController()
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-rotation-probe") {
            return RotationProbeController()
        }
        return ProcessInfo.processInfo.arguments.contains("--screen-guard-probe")
            ? ScreenGuardProbeController() : TextProbeController()
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
