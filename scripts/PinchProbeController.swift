import SwiftUI
import UIKit

final class PinchProbeController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let controls = UIStackView(), facts = UILabel(), scroll = UIScrollView(), canvas = UIView()
    private var began = 0, ended = 0, cancelled = 0, peakTouches = 0
    private var beginCenter = CGPoint.zero, lastCenter = CGPoint.zero
    private var lastTap = CGPoint.zero, requestedOrientation = "none"
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        controls.distribution = .fillEqually; view.addSubview(controls)
        let tapTrace = UITapGestureRecognizer(target: self, action: #selector(recordTap(_:)))
        tapTrace.cancelsTouchesInView = false; tapTrace.delegate = self; view.addGestureRecognizer(tapTrace)
        for (name, mask) in [
            ("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft),
            ("Right", .landscapeRight)
        ] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(
                UIAction { [weak self] _ in
                    self?.requestedOrientation = name; self?.refresh()
                    self?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                }, for: .touchUpInside)
            controls.addArrangedSubview(button)
        }
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        controls.addArrangedSubview(close)
        facts.font = .monospacedSystemFont(ofSize: 13, weight: .regular); facts.numberOfLines = 0
        view.addSubview(facts)
        scroll.delegate = self; scroll.minimumZoomScale = 0.5; scroll.maximumZoomScale = 4
        scroll.bouncesZoom = false; scroll.backgroundColor = .secondarySystemBackground
        scroll.contentInsetAdjustmentBehavior = .never; view.addSubview(scroll)
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 600); scroll.addSubview(canvas)
        scroll.contentSize = canvas.bounds.size
        for row in 0..<6 {
            for column in 0..<6 {
                let label = UILabel(frame: CGRect(x: column * 100, y: row * 100, width: 98, height: 98))
                label.text = "\(row),\(column)"; label.textAlignment = .center
                label.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
                label.backgroundColor = (row + column) % 2 == 0 ? .systemTeal : .systemYellow
                canvas.addSubview(label)
            }
        }
        // Observe the standard UIScrollView recognizer. UIKit alone applies zoom.
        scroll.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
        refresh()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 12, dy: 4)
        controls.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 34)
        facts.frame = CGRect(x: area.minX, y: area.minY + 38, width: area.width, height: 98)
        scroll.frame = CGRect(
            x: area.minX, y: area.minY + 142, width: area.width, height: max(80, area.height - 142))
        refresh()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { refresh() }
    @objc private func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
        peakTouches = max(peakTouches, gesture.numberOfTouches)
        if gesture.state == .began { began += 1; beginCenter = gesture.location(in: view) }
        if gesture.numberOfTouches == 2 { lastCenter = gesture.location(in: view) }
        if gesture.state == .ended { ended += 1 }
        if gesture.state == .cancelled { cancelled += 1 }
        refresh()
        if gesture.state == .ended || gesture.state == .cancelled {
            // UIKit still exposes the ending touches inside its action callback.
            // Read the recognizer again after reset; do not manufacture an active count of zero.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refresh() }
        }
    }
    @objc private func recordTap(_ gesture: UITapGestureRecognizer) {
        lastTap = gesture.location(in: view); refresh()
    }
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
    private func refresh() {
        facts.text = String(
            format:
                """
                Zoom %.3f / UIKit %d\nBegan %d / ended %d / cancelled %d\nPeak touches %d / active\
                 %d\nCenter %.1f,%.1f -> %.1f,%.1f\nTap %.1f,%.1f / Request %@
                """,
            Double(scroll.zoomScale),
            view.window?.windowScene?.interfaceOrientation.rawValue ?? 0, began, ended, cancelled,
            peakTouches,
            scroll.pinchGestureRecognizer?.numberOfTouches ?? 0, beginCenter.x, beginCenter.y, lastCenter.x,
            lastCenter.y, lastTap.x, lastTap.y, requestedOrientation)
    }
}
