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
        if ProcessInfo.processInfo.arguments.contains("--preview-scroll-probe") { return PreviewScrollProbeController() }
        if ProcessInfo.processInfo.arguments.contains("--preview-motion-probe") { return PreviewMotionProbeController() }
        if ProcessInfo.processInfo.arguments.contains("--preview-rotation-probe") { return RotationProbeController() }
        return ProcessInfo.processInfo.arguments.contains("--screen-guard-probe") ? ScreenGuardProbeController() : TextProbeController()
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private final class TextProbeController: UIViewController, UITextViewDelegate {
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
        ("ASCII", "ASCII-BEGIN|0123456789|ABCDEFGHIJKLMNOPQRSTUVWXYZ|abcdefghijklmnopqrstuvwxyz|Ab7!? @# end|ASCII-END"),
        ("中文", "中文开始｜这是一段用于真机验收的受控长文本。我们检查每个汉字、数字和标点是否完整保留，不发送消息，也不提交表单。第一段结束；第二段继续：苹果原生通道负责执行，外部代理核对截图，剪贴板在确认后恢复。编号一二三四五六七八九十，数字0123456789，结束标记｜中文结束"),
        ("组合", "组合开始|e\u{301}|é|👩🏽‍💻|👨‍👩‍👧‍👦|🇨🇳|1️⃣|❤️|组合结束"),
        ("起始", "头🙂尾"),
        ("多行", " 首🙂行\n\n尾e\u{301} \n"),
        ("CRLF", " 首🙂行\r\n\r\n尾e\u{301} \r\n")
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
        let title = UILabel(); title.text = "iPhone-use Text Probe"; title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)
        if ProcessInfo.processInfo.arguments.contains("--dynamic-text-probe") {
            // A visible, bounded animation beside a separately protected editor.
            // The delayed mutation proves excluding animation never masks text.
            input.tintColor = ProcessInfo.processInfo.arguments.contains("--red-caret")
                ? .systemRed : UIColor(red: 7/255, green: 193/255, blue: 96/255, alpha: 1)
            let row = UIStackView(); row.distribution = .fillEqually
            let animation = UILabel(); animation.textAlignment = .center
            animation.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
            row.addArrangedSubview(animation)
            let change = UIButton(type: .system); change.setTitle("Change field in 8s", for: .normal)
            change.addAction(UIAction { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.input.text = "字段已经变化"; self?.refresh()
                }
            }, for: .touchUpInside)
            row.addArrangedSubview(change)
            row.heightAnchor.constraint(equalToConstant: 60).isActive = true
            stack.addArrangedSubview(row)
            var frame = 0
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak animation] _ in
                frame += 1; animation?.text = "VIDEO \(frame)"
                animation?.backgroundColor = frame.isMultiple(of: 2) ? .systemCyan : .systemOrange
            }
        }
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
        let pinch = UIButton(type: .system); pinch.setTitle("Pinch workflow", for: .normal)
        pinch.addAction(UIAction { [weak self] _ in
            let controller = PinchProbeController(); controller.modalPresentationStyle = .fullScreen
            self?.present(controller, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(pinch)
        let doubleTap = UIButton(type: .system); doubleTap.setTitle("Double tap workflow", for: .normal)
        doubleTap.addAction(UIAction { [weak self] _ in
            let controller = DoubleTapProbeController(); controller.modalPresentationStyle = .fullScreen
            self?.present(controller, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(doubleTap)
        let keyboard = UIButton(type: .system); keyboard.setTitle("Keyboard workflow", for: .normal)
        keyboard.addAction(UIAction { [weak self] _ in
            let controller = KeyboardProbeController(); controller.modalPresentationStyle = .fullScreen
            self?.present(controller, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(keyboard)
        let search = UIButton(type: .system); search.setTitle("Local search workflow", for: .normal)
        search.addAction(UIAction { [weak self] _ in
            let navigation = UINavigationController(rootViewController: SearchProbeController())
            navigation.modalPresentationStyle = .fullScreen
            self?.present(navigation, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(search)
        let gestures = UIButton(type: .system); gestures.setTitle("Gesture workflow", for: .normal)
        gestures.addAction(UIAction { [weak self] _ in
            let navigation = UINavigationController(rootViewController: GestureProbeController())
            navigation.modalPresentationStyle = .fullScreen
            self?.present(navigation, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(gestures)
        let video = UIButton(type: .system); video.setTitle("Video workflow", for: .normal)
        video.addAction(UIAction { [weak self] _ in
            let controller = PreviewMotionProbeController(); controller.modalPresentationStyle = .fullScreen
            self?.present(controller, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(video)
        let rotation = UIButton(type: .system); rotation.setTitle("Rotation workflow", for: .normal)
        rotation.addAction(UIAction { [weak self] _ in
            let controller = RotationProbeController(); controller.modalPresentationStyle = .fullScreen
            self?.present(controller, animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(rotation)
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

// Ordinary UIKit search/navigation. Results are local strings; there is no network
// request, clipboard access or injection endpoint. Only Return invokes search.
private final class SearchProbeController: UIViewController, UITextFieldDelegate {
    private let query = UITextField()
    private let facts = UILabel()
    private var edits = 0
    private var searches = 0
    private let catalog = ["苹果", "苹果派", "香蕉", "香蕉面包", "橙子"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Local search"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(close))
        navigationItem.backButtonTitle = "返回修改"
        view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
        let instructions = UILabel(); instructions.numberOfLines = 0
        instructions.text = "输入中文查询，再按 Return 搜索。\n仅查询本地列表，不发送消息。"
        stack.addArrangedSubview(instructions)
        query.placeholder = "例如：苹果"
        query.font = .systemFont(ofSize: 18)
        query.borderStyle = .roundedRect
        query.autocorrectionType = .no; query.autocapitalizationType = .none
        query.smartQuotesType = .no; query.smartDashesType = .no
        query.returnKeyType = .search
        query.delegate = self
        query.addTarget(self, action: #selector(changed), for: .editingChanged)
        query.addTarget(self, action: #selector(refresh), for: [.editingDidBegin, .editingDidEnd])
        query.heightAnchor.constraint(equalToConstant: 48).isActive = true
        stack.addArrangedSubview(query)
        facts.numberOfLines = 0; facts.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        stack.addArrangedSubview(facts)
        let data = UILabel(); data.numberOfLines = 0
        data.text = "Local catalog:\n" + catalog.joined(separator: " / ")
        stack.addArrangedSubview(data)
        refresh()
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func changed() { edits += 1; refresh() }
    @objc private func refresh() {
        let text = query.text ?? ""
        facts.text = "Query (complete): \(text)\nUTF8: \(text.utf8.count)\nEdits: \(edits)  Searches: \(searches)\nActive: \(query.isFirstResponder)"
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        searches += 1
        let text = query.text ?? ""
        query.resignFirstResponder(); refresh()
        let matches = text.isEmpty ? [] : catalog.filter { $0.contains(text) }
        let result = UIViewController(); result.title = "Local results"
        result.view.backgroundColor = .systemBackground
        let label = UILabel(); label.numberOfLines = 0; label.font = .systemFont(ofSize: 18)
        label.text = "Query (complete): \(text)\nUTF8: \(text.utf8.count)\nSearches: \(searches)\nMatches: \(matches.count)\n\n" + (matches.isEmpty ? "No local matches" : matches.joined(separator: "\n"))
        label.translatesAutoresizingMaskIntoConstraints = false; result.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: result.view.safeAreaLayoutGuide.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: result.view.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: result.view.trailingAnchor, constant: -18)
        ])
        navigationController?.pushViewController(result, animated: true)
        return false
    }
}

// Real UIKit context menu and in-app drag/drop. Visible counters change only
// from the corresponding UIKit callbacks, never from a control endpoint.
private final class GestureProbeController: UIViewController, UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    private let facts = UILabel()
    private let destination = UILabel()
    private var menuChoices = 0
    private var drops = 0
    private var dragStarts = 0
    private var dragEnds = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Gesture Probe"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(close))
        view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28)
        ])
        let menu = box("Long press: open menu", color: .systemBlue)
        menu.addInteraction(UIContextMenuInteraction(delegate: self))
        stack.addArrangedSubview(menu)
        let source = box("Drag token: SOMA", color: .systemOrange)
        let drag = UIDragInteraction(delegate: self); drag.isEnabled = true
        source.addInteraction(drag); stack.addArrangedSubview(source)
        destination.text = "Drop token here"
        destination.textAlignment = .center; destination.backgroundColor = .secondarySystemBackground
        destination.isUserInteractionEnabled = true; destination.layer.cornerRadius = 12; destination.clipsToBounds = true
        destination.heightAnchor.constraint(equalToConstant: 110).isActive = true
        destination.addInteraction(UIDropInteraction(delegate: self)); stack.addArrangedSubview(destination)
        facts.numberOfLines = 0; facts.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        stack.addArrangedSubview(facts); refresh()
    }
    private func box(_ text: String, color: UIColor) -> UILabel {
        let label = UILabel(); label.text = text; label.textAlignment = .center
        label.backgroundColor = color.withAlphaComponent(0.2); label.isUserInteractionEnabled = true
        label.layer.cornerRadius = 12; label.clipsToBounds = true
        label.heightAnchor.constraint(equalToConstant: 100).isActive = true
        return label
    }
    @objc private func close() { dismiss(animated: true) }
    private func refresh() {
        facts.text = "Menu choices: \(menuChoices)\nDrag starts: \(dragStarts)\nDrag ends: \(dragEnds)\nDrops: \(drops)"
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Confirm Probe menu") { _ in
                self?.menuChoices += 1; self?.refresh()
            }])
        }
    }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider(object: "SOMA" as NSString))
        item.localObject = "SOMA"
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
        dragStarts += 1; refresh()
    }
    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
        dragEnds += 1; refresh()
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil && session.items.count == 1 && session.items[0].localObject as? String == "SOMA"
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard self.dropInteraction(interaction, canHandle: session) else { return }
        drops += 1; destination.text = "Received: SOMA"; destination.backgroundColor = .systemGreen.withAlphaComponent(0.2)
        refresh()
    }
}

// Rotation is requested only by visible fixture buttons through UIKit's public
// scene API. No device setting changes, sensor spoofing or input endpoint.
private final class RotationProbeController: UIViewController, UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    private let controls = UIStackView()
    private let facts = UILabel()
    private let menu = UILabel(), source = UILabel(), destination = UILabel()
    private var targets: [UIButton] = []
    private var hits = [0, 0, 0, 0]
    private var menuChoices = 0, starts = 0, ends = 0, drops = 0
    private var rotationError = ""
    private var delayedRotation: DispatchWorkItem?
    private var automaticRotations: [DispatchWorkItem] = []
    private var automaticStep = 0
    deinit { automaticRotations.forEach { $0.cancel() } }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        controls.distribution = .fillEqually; controls.spacing = 4; view.addSubview(controls)
        for (name, mask) in [("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft), ("Right", .landscapeRight)] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.rotate(mask) }, for: .touchUpInside)
            controls.addArrangedSubview(button)
        }
        let delayed = UIButton(type: .system); delayed.setTitle("Right +5s", for: .normal)
        delayed.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delayedRotation?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rotate(.landscapeRight) }
            self.delayedRotation = work; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }, for: .touchUpInside); controls.addArrangedSubview(delayed)
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in
            self?.delayedRotation?.cancel(); self?.automaticRotations.forEach { $0.cancel() }; self?.dismiss(animated: true)
        }, for: .touchUpInside)
        controls.addArrangedSubview(close)
        for i in 0..<4 {
            let button = UIButton(type: .system); button.backgroundColor = .systemTeal.withAlphaComponent(0.2)
            button.layer.cornerRadius = 8
            button.addAction(UIAction { [weak self] _ in self?.hits[i] += 1; self?.refresh() }, for: .touchUpInside)
            targets.append(button); view.addSubview(button)
        }
        for (label, text, color) in [(source, "Drag SOMA", UIColor.systemOrange), (menu, "Hold: menu", .systemBlue), (destination, "Drop here", .systemGreen)] {
            label.text = text; label.textAlignment = .center; label.numberOfLines = 2
            label.backgroundColor = color.withAlphaComponent(0.2); label.isUserInteractionEnabled = true
            label.layer.cornerRadius = 8; label.clipsToBounds = true; view.addSubview(label)
        }
        menu.addInteraction(UIContextMenuInteraction(delegate: self))
        let drag = UIDragInteraction(delegate: self); drag.isEnabled = true; source.addInteraction(drag)
        destination.addInteraction(UIDropInteraction(delegate: self))
        facts.numberOfLines = 0; facts.textAlignment = .center; facts.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.addSubview(facts); refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.arguments.contains("--preview-rotation-probe"), automaticRotations.isEmpty else { return }
        // App-driven rotation isolates passive preview recovery from the CLI's
        // mandatory post-input observation. No capture or control endpoint.
        let cycle: [UIInterfaceOrientationMask] = [.landscapeLeft, .landscapeRight, .landscapeLeft, .landscapeRight, .portrait]
        for (index, mask) in Array(repeating: cycle, count: 3).flatMap({ $0 }).enumerated() {
            let work = DispatchWorkItem { [weak self] in
                self?.automaticStep = index + 1; self?.rotate(mask); self?.refresh()
            }
            automaticRotations.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20 + Double(index) * 10, execute: work)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 12, dy: 6)
        controls.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 40)
        let width = min(130.0, area.width * 0.32)
        targets[0].frame = CGRect(x: area.minX, y: area.minY + 48, width: width, height: 42)
        targets[1].frame = CGRect(x: area.maxX - width, y: area.minY + 48, width: width, height: 42)
        targets[2].frame = CGRect(x: area.minX, y: area.maxY - 42, width: width, height: 42)
        targets[3].frame = CGRect(x: area.maxX - width, y: area.maxY - 42, width: width, height: 42)
        let cardWidth = (area.width - 16) / 3
        let cardY = area.minY + 102
        for (i, label) in [source, menu, destination].enumerated() {
            label.frame = CGRect(x: area.minX + Double(i) * (cardWidth + 8), y: cardY, width: cardWidth, height: 92)
        }
        facts.frame = CGRect(x: area.minX, y: cardY + 98, width: area.width, height: 60)
        refresh()
    }
    private func rotate(_ mask: UIInterfaceOrientationMask) {
        rotationError = ""; setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            self?.rotationError = error.localizedDescription; self?.refresh()
        }
    }
    private func refresh() {
        for (i, target) in targets.enumerated() { target.setTitle("\(["A", "B", "C", "D"][i]): \(hits[i])", for: .normal) }
        let orientation = view.window?.windowScene?.interfaceOrientation.rawValue ?? 0
        facts.text = "Rotation Probe / UIKit \(orientation) / \(Int(view.bounds.width))x\(Int(view.bounds.height))\nMenu \(menuChoices) / Starts \(starts) / Ends \(ends) / Drops \(drops)" + (rotationError.isEmpty ? "" : "\n" + rotationError)
        if !automaticRotations.isEmpty { facts.text = (facts.text ?? "") + "\nAuto rotation \(automaticStep)/15" }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Confirm rotation menu") { _ in self?.menuChoices += 1; self?.refresh() }])
        }
    }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider(object: "SOMA" as NSString)); item.localObject = "SOMA"; return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { starts += 1; refresh() }
    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) { ends += 1; refresh() }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil && session.items.count == 1 && session.items[0].localObject as? String == "SOMA"
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation: .copy) }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard self.dropInteraction(interaction, canHandle: session) else { return }
        drops += 1; destination.text = "Received SOMA"; refresh()
    }
}

// Ordinary form shortcuts. These handlers only navigate focus or end editing;
// text and selection edits are performed by UIKit's standard text editor.
private final class KeyboardProbeInput: UITextView {
    var navigate: ((Bool) -> Void)?
    var escape: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(moveFocus(_:))),
                        UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(moveFocus(_:))),
                        UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(endEditingKey))]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }
    @objc private func moveFocus(_ command: UIKeyCommand) { navigate?(command.modifierFlags.contains(.shift)) }
    @objc private func endEditingKey() { escape?() }
}

private final class KeyboardProbeController: UIViewController, UITextViewDelegate {
    private let controls = UIStackView(), fixtures = UIStackView()
    private let first = KeyboardProbeInput(), second = KeyboardProbeInput(), facts = UILabel()
    private var edits = 0, focuses = 0, escapes = 0, tabs = 0, backTabs = 0
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        for row in [controls, fixtures] { row.distribution = .fillEqually; row.spacing = 4; view.addSubview(row) }
        for (name, mask) in [("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft), ("Right", .landscapeRight)] {
            add(name, to: controls) { [weak self] in
                self?.setNeedsUpdateOfSupportedInterfaceOrientations()
                self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
        }
        add("Close", to: controls) { [weak self] in self?.view.endEditing(true); self?.dismiss(animated: true) }
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
        facts.font = .monospacedSystemFont(ofSize: 12, weight: .regular); facts.numberOfLines = 0; view.addSubview(facts)
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
        first.becomeFirstResponder(); first.selectedRange = NSRange(location: lines ? 7 : 3, length: 0); refresh()
    }
    func textViewDidChange(_ textView: UITextView) { edits += 1; refresh() }
    func textViewDidChangeSelection(_ textView: UITextView) { refresh() }
    func textViewDidBeginEditing(_ textView: UITextView) { focuses += 1; refresh() }
    func textViewDidEndEditing(_ textView: UITextView) { refresh() }
    private func refresh() {
        let active = first.isFirstResponder ? 1 : second.isFirstResponder ? 2 : 0
        let orientation = view.window?.windowScene?.interfaceOrientation.rawValue ?? 0
        func visible(_ input: UITextView) -> String { input.text.replacingOccurrences(of: "\n", with: "\\n") }
        facts.text = "Active \(active) / Focus \(focuses) / Edits \(edits) / UIKit \(orientation)\n" +
            "Selection1 UTF16: \(first.selectedRange.location),\(first.selectedRange.length)\n" +
            "Tab \(tabs) / ShiftTab \(backTabs) / Escape \(escapes)\n" +
            "Value1: \(visible(first))\nValue2: \(visible(second))"
    }
}

private final class DoubleTapProbeController: UIViewController, UITextViewDelegate {
    private let controls = UIStackView(), target = UILabel(), text = UITextView(), facts = UILabel()
    private var doubles = 0, singles = 0
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        controls.distribution = .fillEqually; view.addSubview(controls)
        for (name, mask) in [("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft), ("Right", .landscapeRight)] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in
                self?.setNeedsUpdateOfSupportedInterfaceOrientations()
                self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }, for: .touchUpInside); controls.addArrangedSubview(button)
        }
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside); controls.addArrangedSubview(close)
        target.text = "Double tap here"; target.textAlignment = .center
        target.backgroundColor = .systemTeal; target.isUserInteractionEnabled = true; view.addSubview(target)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleHit)); double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleHit)); single.require(toFail: double)
        target.addGestureRecognizer(double); target.addGestureRecognizer(single)
        text.text = "alpha bravo charlie"; text.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        text.isEditable = false; text.isSelectable = true; text.delegate = self
        text.backgroundColor = .secondarySystemBackground; view.addSubview(text)
        facts.font = .monospacedSystemFont(ofSize: 13, weight: .regular); facts.numberOfLines = 0; view.addSubview(facts)
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
        let selected = range.location <= value.length && range.length <= value.length - range.location ? value.substring(with: range) : ""
        facts.text = "Double \(doubles) / Single \(singles) / UIKit \(view.window?.windowScene?.interfaceOrientation.rawValue ?? 0)\n" +
            "Selection UTF16: \(range.location),\(range.length)\nSelected: \(selected)"
    }
}

private final class PinchProbeController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
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
        for (name, mask) in [("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft), ("Right", .landscapeRight)] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in
                self?.requestedOrientation = name; self?.refresh()
                self?.setNeedsUpdateOfSupportedInterfaceOrientations()
                self?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }, for: .touchUpInside); controls.addArrangedSubview(button)
        }
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside); controls.addArrangedSubview(close)
        facts.font = .monospacedSystemFont(ofSize: 13, weight: .regular); facts.numberOfLines = 0; view.addSubview(facts)
        scroll.delegate = self; scroll.minimumZoomScale = 0.5; scroll.maximumZoomScale = 4
        scroll.bouncesZoom = false; scroll.backgroundColor = .secondarySystemBackground
        scroll.contentInsetAdjustmentBehavior = .never; view.addSubview(scroll)
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 600); scroll.addSubview(canvas); scroll.contentSize = canvas.bounds.size
        for row in 0..<6 { for column in 0..<6 {
            let label = UILabel(frame: CGRect(x: column * 100, y: row * 100, width: 98, height: 98))
            label.text = "\(row),\(column)"; label.textAlignment = .center; label.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
            label.backgroundColor = (row + column) % 2 == 0 ? .systemTeal : .systemYellow
            canvas.addSubview(label)
        } }
        // Observe the standard UIScrollView recognizer. UIKit alone applies zoom.
        scroll.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
        refresh()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 12, dy: 4)
        controls.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 34)
        facts.frame = CGRect(x: area.minX, y: area.minY + 38, width: area.width, height: 98)
        scroll.frame = CGRect(x: area.minX, y: area.minY + 142, width: area.width, height: max(80, area.height - 142))
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
    @objc private func recordTap(_ gesture: UITapGestureRecognizer) { lastTap = gesture.location(in: view); refresh() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    private func refresh() {
        facts.text = String(format: "Zoom %.3f / UIKit %d\nBegan %d / ended %d / cancelled %d\nPeak touches %d / active %d\nCenter %.1f,%.1f -> %.1f,%.1f\nTap %.1f,%.1f / Request %@", Double(scroll.zoomScale),
            view.window?.windowScene?.interfaceOrientation.rawValue ?? 0, began, ended, cancelled, peakTouches, scroll.pinchGestureRecognizer?.numberOfTouches ?? 0, beginCenter.x, beginCenter.y, lastCenter.x, lastCenter.y, lastTap.x, lastTap.y, requestedOrientation)
    }
}

// Controlled motion beside a real UIKit target. The timers change only fixture
// appearance; the tap count can change only through the button's touch action.
private final class ScreenGuardProbeController: UIViewController {
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
        target.setTitle("TARGET", for: .normal); target.backgroundColor = .systemBlue; target.setTitleColor(.white, for: .normal)
        target.addAction(UIAction { [weak self] _ in self?.taps += 1; self?.refresh() }, for: .touchUpInside)
        for (button, title) in [(move, "Move in 8s"), (cover, "Cover in 8s"), (reset, "Reset fixture")] {
            button.setTitle(title, for: .normal); view.addSubview(button)
        }
        move.addAction(UIAction { [weak self] _ in self?.arm(cover: false) }, for: .touchUpInside)
        cover.addAction(UIAction { [weak self] _ in self?.arm(cover: true) }, for: .touchUpInside)
        reset.addAction(UIAction { [weak self] _ in
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
            self.animation.backgroundColor = UIColor(hue: CGFloat(self.tick % 300) / 300, saturation: 0.85, brightness: 0.9, alpha: 1)
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
