import SwiftUI
import UIKit

// Controlled motion beside a real UIKit target. The timers change only fixture
// appearance; the tap count can change only through the button's touch action.
final class ScreenGuardProbeController: UIViewController {
    private let animation = UILabel()
    private let facts = UILabel()
    private let state = UILabel()
    private let target = UIButton(type: .system)
    private let move = UIButton(type: .system)
    private let cover = UIButton(type: .system)
    private let reset = UIButton(type: .system)
    private let overlay = UILabel()
    private var ticker: Timer?
    private var pending: Timer?
    private var tick = 0
    private var taps = 0
    private var moved = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        facts.textColor = .black; facts.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        state.textColor = .black; state.font = .systemFont(ofSize: 15)
        animation.textColor = .white; animation.textAlignment = .center
        animation.numberOfLines = 2; animation.font = .monospacedSystemFont(ofSize: 19, weight: .bold)
        target.setTitle("TARGET", for: .normal); target.backgroundColor = .systemBlue
        target.setTitleColor(.white, for: .normal)
        target.addAction(
            UIAction { [weak self] _ in
                self?.taps += 1; self?.refresh()
            }, for: .touchUpInside)
        for (button, title) in [(move, "Move in 8s"), (cover, "Cover in 8s"), (reset, "Reset fixture")] {
            button.setTitle(title, for: .normal); view.addSubview(button)
        }
        move.addAction(UIAction { [weak self] _ in self?.arm(cover: false) }, for: .touchUpInside)
        cover.addAction(UIAction { [weak self] _ in self?.arm(cover: true) }, for: .touchUpInside)
        reset.addAction(
            UIAction { [weak self] _ in
                self?.pending?.invalidate(); self?.moved = false; self?.overlay.isHidden = true
                self?.state.text = "Ready"; self?.view.setNeedsLayout()
            }, for: .touchUpInside)
        for child in [facts, state, animation, target, overlay] { view.addSubview(child) }
        overlay.text = "BLOCKED"; overlay.textAlignment = .center; overlay.textColor = .white
        overlay.backgroundColor = .black; overlay.isUserInteractionEnabled = true; overlay.isHidden = true
        state.text = "Ready"; refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            self.animation.backgroundColor = UIColor(
                hue: CGFloat(self.tick % 300) / 300, saturation: 0.85, brightness: 0.9, alpha: 1)
            self.animation.text = "AUTOPLAY FIXTURE\nFrame \(self.tick)"
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); ticker?.invalidate(); pending?.invalidate()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        facts.frame = CGRect(x: 20, y: top + 10, width: view.bounds.width - 40, height: 32)
        state.frame = CGRect(x: 20, y: top + 48, width: view.bounds.width - 40, height: 28)
        animation.frame = CGRect(x: 20, y: top + 95, width: 220, height: 140)
        target.frame = CGRect(x: moved ? view.bounds.width - 140 : 40, y: top + 310, width: 100, height: 60)
        overlay.frame = target.frame.insetBy(dx: -8, dy: -8)
        move.frame = CGRect(x: 20, y: top + 430, width: 150, height: 48)
        cover.frame = CGRect(x: view.bounds.width - 170, y: top + 430, width: 150, height: 48)
        reset.frame = CGRect(x: 20, y: top + 510, width: 200, height: 48)
    }
    private func arm(cover: Bool) {
        pending?.invalidate(); state.text = cover ? "Cover armed (8s)" : "Move armed (8s)"
        pending = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self else { return }
            if cover { self.overlay.isHidden = false } else { self.moved = true; self.view.setNeedsLayout() }
            self.state.text = cover ? "Target covered" : "Target moved"
        }
    }
    private func refresh() { facts.text = "Screen Guard Probe · Taps \(taps)" }
    deinit { ticker?.invalidate(); pending?.invalidate() }
}
