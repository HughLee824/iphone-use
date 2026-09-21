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
        close.addAction(UIAction { [weak self] _ in self?.delayedRotation?.cancel(); self?.dismiss(animated: true) }, for: .touchUpInside)
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
