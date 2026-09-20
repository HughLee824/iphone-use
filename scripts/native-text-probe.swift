// Development-only iOS Probe. Build as an ordinary app, never a test Runner.
// No network, clipboard or text-injection API. Visible editing buttons load a
// disposable seed/selection; sample buttons only clear and set an expected value.
import SwiftUI
import UIKit

@main struct NativeTextProbeApp: App {
    var body: some Scene { WindowGroup { TextProbe().ignoresSafeArea(.keyboard) } }
}

private struct TextProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TextProbeController { TextProbeController() }
    func updateUIViewController(_ controller: TextProbeController, context: Context) {}
}

private final class TextProbeController: UIViewController, UITextViewDelegate {
    private let input = UITextView()
    private let received = UILabel()
    private let facts = UILabel()
    private var expected = ""
    private var selected = "none"
    private var edits = 0
    private var focusEvents = 0
    private let samples: [(String, String)] = [
        ("ASCII", "ASCII-BEGIN|0123456789|ABCDEFGHIJKLMNOPQRSTUVWXYZ|abcdefghijklmnopqrstuvwxyz|Ab7!? @# end|ASCII-END"),
        ("中文", "中文开始｜这是一段用于真机验收的受控长文本。我们检查每个汉字、数字和标点是否完整保留，不发送消息，也不提交表单。第一段结束；第二段继续：苹果原生通道负责执行，外部代理核对截图，剪贴板在确认后恢复。编号一二三四五六七八九十，数字0123456789，结束标记｜中文结束"),
        ("组合", "组合开始|e\u{301}|é|👩🏽‍💻|👨‍👩‍👧‍👦|🇨🇳|1️⃣|❤️|组合结束"),
        ("起始", "头🙂尾")
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
        let title = UILabel(); title.text = "AgentSoma Text Probe"; title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)
        let buttons = UIStackView(); buttons.distribution = .fillEqually
        for (name, value) in samples {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.select(name, expected: value) }, for: .touchUpInside)
            buttons.addArrangedSubview(button)
        }
        buttons.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(buttons)
        input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.backgroundColor = .secondarySystemBackground
        input.layer.cornerRadius = 8
        input.autocorrectionType = .no; input.autocapitalizationType = .none
        input.smartQuotesType = .no; input.smartDashesType = .no; input.smartInsertDeleteType = .no
        input.delegate = self
        input.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(input)
        let editingButtons = UIStackView(); editingButtons.distribution = .fillEqually
        let editingLabel = UILabel(); editingLabel.text = "Load edit fixture: 头🙂尾"; editingLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(editingLabel)
        for mode in ["replace", "append", "insert", "clear"] {
            let button = UIButton(type: .system); button.setTitle(mode, for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.prepareEditing(mode) }, for: .touchUpInside)
            editingButtons.addArrangedSubview(button)
        }
        editingButtons.heightAnchor.constraint(equalToConstant: 36).isActive = true
        stack.addArrangedSubview(editingButtons)
        facts.numberOfLines = 0; facts.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        stack.addArrangedSubview(facts)
        received.numberOfLines = 0; received.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        stack.addArrangedSubview(received)
        let unfocus = UIButton(type: .system); unfocus.setTitle("End editing (no submit)", for: .normal)
        unfocus.addAction(UIAction { [weak self] _ in self?.input.resignFirstResponder() }, for: .touchUpInside)
        stack.addArrangedSubview(unfocus)
        refresh()
    }

    private func select(_ name: String, expected: String) {
        // A visible sample button explicitly resets only this disposable field.
        selected = name; self.expected = expected; input.text = ""; edits = 0
        input.becomeFirstResponder(); refresh()
    }
    private func prepareEditing(_ mode: String) {
        // This visible fixture setup seeds only the disposable field. The edited
        // result must arrive through the device input path; never preload it.
        input.text = "头🙂尾"; edits = 0
        selected = mode
        switch mode {
        case "replace": expected = "替换🙂"
        case "append": expected = "头🙂尾追加"
        case "insert": expected = "头插入尾"
        default: expected = ""
        }
        input.becomeFirstResponder()
        input.selectedRange = mode == "append" ? NSRange(location: 0, length: 1) : NSRange(location: 1, length: 2)
        refresh()
    }
    func textViewDidChange(_ textView: UITextView) { edits += 1; refresh() }
    func textViewDidChangeSelection(_ textView: UITextView) { refresh() }
    func textViewDidBeginEditing(_ textView: UITextView) { focusEvents += 1; refresh() }
    func textViewDidEndEditing(_ textView: UITextView) { refresh() }
    private func refresh() {
        let text = input.text ?? ""
        // Byte equality deliberately distinguishes canonical-equivalent Unicode.
        let exact = selected != "none" && Array(text.utf8) == Array(expected.utf8)
        facts.text = "Sample: \(selected)\nUTF8: \(text.utf8.count)/\(expected.utf8.count)  Scalars: \(text.unicodeScalars.count)/\(expected.unicodeScalars.count)\n\(exact ? "EXACT UTF-8 MATCH" : "NOT MATCHED")\nEdits: \(edits)  Focus: \(focusEvents)  Active: \(input.isFirstResponder)\nSelection UTF16: \(input.selectedRange.location),\(input.selectedRange.length)"
        facts.textColor = exact ? .systemGreen : .label
        received.text = "Received (complete):\n" + (text.isEmpty ? "<empty>" : text)
    }
}
