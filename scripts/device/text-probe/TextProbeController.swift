import SwiftUI
import UIKit

final class TextProbeController: UIViewController, UITextViewDelegate {
    private let input = UITextView()
    private var animationTimer: Timer?
    deinit { animationTimer?.invalidate() }
    private let received = UILabel()
    private let facts = UILabel()
    private var expected = ""
    private var selected = "none"
    private var edits = 0
    private var focusEvents = 0
    private let samples: [(String, String)] = [
        (
            "ASCII",
            """
            ASCII-BEGIN|0123456789|ABCDEFGHIJKLMNOPQRSTUVWXYZ|abcdefghijklmnopqrstuvwxyz|Ab7!? @# end|ASCII-END
            """
        ),
        (
            "中文",
            """
            中文开始｜这是一段用于真机验收的受控长文本。我们检查每个汉字、数字和标点是否完整保留，不发送消息，也不提交表单。第一段结束；第二段继续：苹果原生通道负责执行，外部代理核对截图，剪贴板在确认后恢\
            复。编号一二三四五六七八九十，数字0123456789，结束标记｜中文结束
            """
        ), ("组合", "组合开始|e\u{301}|é|👩🏽‍💻|👨‍👩‍👧‍👦|🇨🇳|1️⃣|❤️|组合结束"), ("起始", "头🙂尾"), ("多行", " 首🙂行\n\n尾e\u{301} \n"),
        ("CRLF", " 首🙂行\r\n\r\n尾e\u{301} \r\n")
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
        let title = UILabel()
        title.text = "iPhone-use Text Probe"
        title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)
        addDynamicProbe(to: stack)
        addSampleButtons(to: stack)
        configureInput(in: stack)
        let editingButtons = UIStackView()
        editingButtons.distribution = .fillEqually
        let editingLabel = UILabel()
        editingLabel.text = "Load edit fixture: 头🙂尾"
        editingLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(editingLabel)
        for mode in ["replace", "append", "insert", "clear"] {
            let button = UIButton(type: .system)
            button.setTitle(mode, for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.prepareEditing(mode) }, for: .touchUpInside)
            editingButtons.addArrangedSubview(button)
        }
        editingButtons.heightAnchor.constraint(equalToConstant: 36).isActive = true
        stack.addArrangedSubview(editingButtons)
        facts.numberOfLines = 0
        facts.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        stack.addArrangedSubview(facts)
        received.numberOfLines = 0
        received.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        stack.addArrangedSubview(received)
        let unfocus = UIButton(type: .system)
        unfocus.setTitle("End editing (no submit)", for: .normal)
        unfocus.addAction(UIAction { [weak self] _ in self?.input.resignFirstResponder() }, for: .touchUpInside)
        stack.addArrangedSubview(unfocus)
        addWorkflows(to: stack)
        refresh()
    }

    private func addDynamicProbe(to stack: UIStackView) {
        if ProcessInfo.processInfo.arguments.contains("--dynamic-text-probe") {
            // A visible, bounded animation beside a separately protected editor.
            // The delayed mutation proves excluding animation never masks text.
            input.tintColor =
                ProcessInfo.processInfo.arguments.contains("--red-caret")
                ? .systemRed : UIColor(red: 7 / 255, green: 193 / 255, blue: 96 / 255, alpha: 1)
            let row = UIStackView()
            row.distribution = .fillEqually
            let animation = UILabel()
            animation.textAlignment = .center
            animation.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
            row.addArrangedSubview(animation)
            let change = UIButton(type: .system)
            change.setTitle("Change field in 8s", for: .normal)
            change.addAction(
                UIAction { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        self?.input.text = "字段已经变化"
                        self?.refresh()
                    }
                }, for: .touchUpInside)
            row.addArrangedSubview(change)
            row.heightAnchor.constraint(equalToConstant: 60).isActive = true
            stack.addArrangedSubview(row)
            var frame = 0
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak animation] _ in
                frame += 1
                animation?.text = "VIDEO \(frame)"
                animation?.backgroundColor = frame.isMultiple(of: 2) ? .systemCyan : .systemOrange
            }
        }
    }

    private func addWorkflows(to stack: UIStackView) {
        let pinch = UIButton(type: .system)
        pinch.setTitle("Pinch workflow", for: .normal)
        pinch.addAction(
            UIAction { [weak self] _ in
                let controller = PinchProbeController()
                controller.modalPresentationStyle = .fullScreen
                self?.present(controller, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(pinch)
        let doubleTap = UIButton(type: .system)
        doubleTap.setTitle("Double tap workflow", for: .normal)
        doubleTap.addAction(
            UIAction { [weak self] _ in
                let controller = DoubleTapProbeController()
                controller.modalPresentationStyle = .fullScreen
                self?.present(controller, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(doubleTap)
        let keyboard = UIButton(type: .system)
        keyboard.setTitle("Keyboard workflow", for: .normal)
        keyboard.addAction(
            UIAction { [weak self] _ in
                let controller = KeyboardProbeController()
                controller.modalPresentationStyle = .fullScreen
                self?.present(controller, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(keyboard)
        let search = UIButton(type: .system)
        search.setTitle("Local search workflow", for: .normal)
        search.addAction(
            UIAction { [weak self] _ in
                let navigation = UINavigationController(rootViewController: SearchProbeController())
                navigation.modalPresentationStyle = .fullScreen
                self?.present(navigation, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(search)
        let gestures = UIButton(type: .system)
        gestures.setTitle("Gesture workflow", for: .normal)
        gestures.addAction(
            UIAction { [weak self] _ in
                let navigation = UINavigationController(rootViewController: GestureProbeController())
                navigation.modalPresentationStyle = .fullScreen
                self?.present(navigation, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(gestures)
        addMediaWorkflows(to: stack)
    }

    private func select(_ name: String, expected: String) {
        // A visible sample button explicitly resets only this disposable field.
        selected = name
        self.expected = expected
        input.text = ""
        edits = 0
        input.becomeFirstResponder()
        refresh()
    }
    private func prepareEditing(_ mode: String) {
        // This visible fixture setup seeds only the disposable field. The edited
        // result must arrive through the device input path; never preload it.
        input.text = "头🙂尾"
        edits = 0
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
    func textViewDidChange(_ textView: UITextView) {
        edits += 1
        refresh()
    }
    func textViewDidChangeSelection(_ textView: UITextView) { refresh() }
    func textViewDidBeginEditing(_ textView: UITextView) {
        focusEvents += 1
        refresh()
    }
    func textViewDidEndEditing(_ textView: UITextView) { refresh() }
    private func refresh() {
        let text = input.text ?? ""
        // Byte equality deliberately distinguishes canonical-equivalent Unicode.
        let exact = selected != "none" && Array(text.utf8) == Array(expected.utf8)
        facts.text = """
            Sample: \(selected)\nUTF8: \(text.utf8.count)/\(expected.utf8.count)  Scalars:\
             \(text.unicodeScalars.count)/\(expected.unicodeScalars.count)\n\
            \(exact ? "EXACT UTF-8 MATCH" : "NOT MATCHED")\nEdits: \(edits)  Focus: \(focusEvents) \
             Active: \(input.isFirstResponder)\nSelection UTF16: \(input.selectedRange.location)\
            ,\(input.selectedRange.length)
            """
        facts.textColor = exact ? .systemGreen : .label
        received.text = "Received (complete):\n" + (text.isEmpty ? "<empty>" : text)
    }
    private func addMediaWorkflows(to stack: UIStackView) {
        let video = UIButton(type: .system)
        video.setTitle("Video workflow", for: .normal)
        video.addAction(
            UIAction { [weak self] _ in
                let controller = PreviewMotionProbeController()
                controller.modalPresentationStyle = .fullScreen
                self?.present(controller, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(video)
        let rotation = UIButton(type: .system)
        rotation.setTitle("Rotation workflow", for: .normal)
        rotation.addAction(
            UIAction { [weak self] _ in
                let controller = RotationProbeController()
                controller.modalPresentationStyle = .fullScreen
                self?.present(controller, animated: true)
            }, for: .touchUpInside)
        stack.addArrangedSubview(rotation)
    }

    private func configureInput(in stack: UIStackView) {
        input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.backgroundColor = .secondarySystemBackground
        input.layer.cornerRadius = 8
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.smartQuotesType = .no
        input.smartDashesType = .no
        input.smartInsertDeleteType = .no
        input.delegate = self
        input.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(input)
    }

    private func addSampleButtons(to stack: UIStackView) {
        let buttons = UIStackView()
        buttons.distribution = .fillEqually
        for (name, value) in samples {
            let button = UIButton(type: .system)
            button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.select(name, expected: value) }, for: .touchUpInside)
            buttons.addArrangedSubview(button)
        }
        buttons.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(buttons)
    }

}
