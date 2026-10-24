import SwiftUI
import UIKit

final class DoubleTapProbeController: UIViewController, UITextViewDelegate {
    private let controls = UIStackView(), target = UILabel(), text = UITextView(), facts = UILabel()
    private var doubles = 0, singles = 0
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        controls.distribution = .fillEqually; view.addSubview(controls)
        for (name, mask) in [
            ("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft),
            ("Right", .landscapeRight)
        ] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(
                UIAction { [weak self] _ in
                    self?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                }, for: .touchUpInside)
            controls.addArrangedSubview(button)
        }
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        controls.addArrangedSubview(close)
        target.text = "Double tap here"; target.textAlignment = .center
        target.backgroundColor = .systemTeal; target.isUserInteractionEnabled = true; view.addSubview(target)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleHit))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleHit))
        single.require(toFail: double)
        target.addGestureRecognizer(double); target.addGestureRecognizer(single)
        text.text = "alpha bravo charlie"; text.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        text.isEditable = false; text.isSelectable = true; text.delegate = self
        text.backgroundColor = .secondarySystemBackground; view.addSubview(text)
        facts.font = .monospacedSystemFont(ofSize: 13, weight: .regular); facts.numberOfLines = 0
        view.addSubview(facts)
        refresh()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 12, dy: 4)
        controls.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 34)
        target.frame = CGRect(x: area.minX, y: area.minY + 46, width: area.width, height: 72)
        text.frame = CGRect(x: area.minX, y: area.minY + 132, width: area.width, height: 60)
        facts.frame = CGRect(x: area.minX, y: area.minY + 206, width: area.width, height: 100)
        refresh()
    }
    @objc private func doubleHit() { doubles += 1; refresh() }
    @objc private func singleHit() { singles += 1; refresh() }
    func textViewDidChangeSelection(_ textView: UITextView) { refresh() }
    private func refresh() {
        let range = text.selectedRange, value = text.text as NSString? ?? ""
        let selected =
            range.location <= value.length && range.length <= value.length - range.location
            ? value.substring(with: range) : ""
        facts.text =
            """
            Double \(doubles) / Single \(singles) / UIKit\
             \(view.window?.windowScene?.interfaceOrientation.rawValue ?? 0)\n
            """
            + "Selection UTF16: \(range.location),\(range.length)\nSelected: \(selected)"
    }
}
