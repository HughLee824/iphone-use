import SwiftUI
import UIKit

// Rotation is requested only by visible fixture buttons through UIKit's public
// scene API. No device setting changes, sensor spoofing or input endpoint.
final class RotationProbeController: UIViewController, UIContextMenuInteractionDelegate,
    UIDragInteractionDelegate, UIDropInteractionDelegate {
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
        for (name, mask) in [
            ("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft),
            ("Right", .landscapeRight)
        ] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.rotate(mask) }, for: .touchUpInside)
            controls.addArrangedSubview(button)
        }
        let delayed = UIButton(type: .system); delayed.setTitle("Right +5s", for: .normal)
        delayed.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delayedRotation?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.rotate(.landscapeRight) }
                self.delayedRotation = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }, for: .touchUpInside)
        controls.addArrangedSubview(delayed)
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal)
        close.addAction(
            UIAction { [weak self] _ in
                self?.delayedRotation?.cancel(); self?.automaticRotations.forEach { $0.cancel() }
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
        controls.addArrangedSubview(close)
        for index in 0..<4 {
            let button = UIButton(type: .system); button.backgroundColor = .systemTeal.withAlphaComponent(0.2)
            button.layer.cornerRadius = 8
            button.addAction(
                UIAction { [weak self] _ in
                    self?.hits[index] += 1; self?.refresh()
                }, for: .touchUpInside)
            targets.append(button); view.addSubview(button)
        }
        for (label, text, color) in [
            (source, "Drag SOMA", UIColor.systemOrange), (menu, "Hold: menu", .systemBlue),
            (destination, "Drop here", .systemGreen)
        ] {
            label.text = text; label.textAlignment = .center; label.numberOfLines = 2
            label.backgroundColor = color.withAlphaComponent(0.2); label.isUserInteractionEnabled = true
            label.layer.cornerRadius = 8; label.clipsToBounds = true; view.addSubview(label)
        }
        menu.addInteraction(UIContextMenuInteraction(delegate: self))
        let drag = UIDragInteraction(delegate: self); drag.isEnabled = true; source.addInteraction(drag)
        destination.addInteraction(UIDropInteraction(delegate: self))
        facts.numberOfLines = 0; facts.textAlignment = .center
        facts.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.addSubview(facts); refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.arguments.contains("--preview-rotation-probe"),
            automaticRotations.isEmpty
        else {
            return
        }
        // App-driven rotation isolates passive preview recovery from the CLI's
        // mandatory post-input observation. No capture or control endpoint.
        let cycle: [UIInterfaceOrientationMask] = [
            .landscapeLeft, .landscapeRight, .landscapeLeft, .landscapeRight, .portrait
        ]
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
        for (index, label) in [source, menu, destination].enumerated() {
            label.frame = CGRect(
                x: area.minX + Double(index) * (cardWidth + 8), y: cardY, width: cardWidth, height: 92)
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
        for (index, target) in targets.enumerated() {
            target.setTitle("\(["A", "B", "C", "D"][index]): \(hits[index])", for: .normal)
        }
        let orientation = view.window?.windowScene?.interfaceOrientation.rawValue ?? 0
        facts.text =
            """
            Rotation Probe / UIKit \(orientation) /\
             \(Int(view.bounds.width))x\(Int(view.bounds.height))\nMenu \(menuChoices) / Starts \(starts)\
             / Ends \(ends) / Drops \(drops)
            """
            + (rotationError.isEmpty ? "" : "\n" + rotationError)
        if !automaticRotations.isEmpty {
            facts.text = (facts.text ?? "") + "\nAuto rotation \(automaticStep)/15"
        }
    }
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Confirm rotation menu") { _ in
                    self?.menuChoices += 1; self?.refresh()
                }
            ])
        }
    }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession)
        -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider(object: "SOMA" as NSString))
        item.localObject = "SOMA"
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
        starts += 1; refresh()
    }
    func dragInteraction(
        _ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation
    ) { ends += 1; refresh() }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil && session.items.count == 1
            && session.items[0].localObject as? String == "SOMA"
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession)
        -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard self.dropInteraction(interaction, canHandle: session) else { return }
        drops += 1; destination.text = "Received SOMA"; refresh()
    }
}
