import SwiftUI
import UIKit

// Ordinary form shortcuts. These handlers only navigate focus or end editing;
// text and selection edits are performed by UIKit's standard text editor.
final class KeyboardProbeInput: UITextView {
    var navigate: ((Bool) -> Void)?
    var escape: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(moveFocus(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(moveFocus(_:))),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(endEditingKey))
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }
    @objc private func moveFocus(_ command: UIKeyCommand) {
        navigate?(command.modifierFlags.contains(.shift))
    }
    @objc private func endEditingKey() { escape?() }
}

final class KeyboardProbeController: UIViewController, UITextViewDelegate {
    private let controls = UIStackView(), fixtures = UIStackView()
    private let first = KeyboardProbeInput(), second = KeyboardProbeInput(), facts = UILabel()
    private var edits = 0, focuses = 0, escapes = 0, tabs = 0, backTabs = 0
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        for row in [controls, fixtures] {
            row.distribution = .fillEqually; row.spacing = 4; view.addSubview(row)
        }
        for (name, mask) in [
            ("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft),
            ("Right", .landscapeRight)
        ] {
            add(name, to: controls) { [weak self] in
                self?.setNeedsUpdateOfSupportedInterfaceOrientations()
                self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
        }
        add("Close", to: controls) { [weak self] in
            self?.view.endEditing(true); self?.dismiss(animated: true)
        }
        add("Seed", to: fixtures) { [weak self] in self?.seed(lines: false) }
        add("Lines", to: fixtures) { [weak self] in self?.seed(lines: true) }
        add("Focus 1", to: fixtures) { [weak self] in self?.first.becomeFirstResponder() }
        add("Focus 2", to: fixtures) { [weak self] in self?.second.becomeFirstResponder() }
        first.accessibilityIdentifier = "keyboard.first"; second.accessibilityIdentifier = "keyboard.second"
        for input in [first, second] {
            input.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
            input.backgroundColor = .secondarySystemBackground; input.layer.cornerRadius = 8
            input.autocorrectionType = .no; input.autocapitalizationType = .none
            input.smartQuotesType = .no; input.smartDashesType = .no; input.smartInsertDeleteType = .no
            input.delegate = self; view.addSubview(input)
            input.navigate = { [weak self, weak input] backwards in
                guard let self, let input else { return }
                if backwards { self.backTabs += 1 } else { self.tabs += 1 }
                (input === self.first ? self.second : self.first).becomeFirstResponder(); self.refresh()
            }
            input.escape = { [weak self] in
                guard let self else { return }; self.escapes += 1; self.view.endEditing(true); self.refresh()
            }
        }
        first.text = "头🙂尾"; second.text = "二号"
        facts.font = .monospacedSystemFont(ofSize: 12, weight: .regular); facts.numberOfLines = 0
        view.addSubview(facts)
        refresh()
    }
    private func add(_ name: String, to row: UIStackView, action: @escaping () -> Void) {
        let button = UIButton(type: .system); button.setTitle(name, for: .normal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); row.addArrangedSubview(button)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 12, dy: 4)
        controls.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 34)
        fixtures.frame = CGRect(x: area.minX, y: area.minY + 38, width: area.width, height: 30)
        first.frame = CGRect(x: area.minX, y: area.minY + 74, width: area.width, height: 82)
        second.frame = CGRect(x: area.minX, y: area.minY + 162, width: area.width, height: 38)
        facts.frame = CGRect(x: area.minX, y: area.minY + 206, width: area.width, height: 130)
        refresh()
    }
    private func seed(lines: Bool) {
        first.text = lines ? "头🙂尾\nABCD\n1234" : "头🙂尾"; second.text = "二号"; edits = 0
        first.becomeFirstResponder(); first.selectedRange = NSRange(location: lines ? 7 : 3, length: 0)
        refresh()
    }
    func textViewDidChange(_ textView: UITextView) { edits += 1; refresh() }
    func textViewDidChangeSelection(_ textView: UITextView) { refresh() }
    func textViewDidBeginEditing(_ textView: UITextView) { focuses += 1; refresh() }
    func textViewDidEndEditing(_ textView: UITextView) { refresh() }
    private func refresh() {
        let active = first.isFirstResponder ? 1 : second.isFirstResponder ? 2 : 0
        let orientation = view.window?.windowScene?.interfaceOrientation.rawValue ?? 0
        func visible(_ input: UITextView) -> String { input.text.replacingOccurrences(of: "\n", with: "\\n") }
        facts.text =
            "Active \(active) / Focus \(focuses) / Edits \(edits) / UIKit \(orientation)\n"
            + "Selection1 UTF16: \(first.selectedRange.location),\(first.selectedRange.length)\n"
            + "Tab \(tabs) / ShiftTab \(backTabs) / Escape \(escapes)\n"
            + "Value1: \(visible(first))\nValue2: \(visible(second))"
    }
}
