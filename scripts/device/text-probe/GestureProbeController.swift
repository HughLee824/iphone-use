import SwiftUI
import UIKit

// Real UIKit context menu and in-app drag/drop. Visible counters change only
// from the corresponding UIKit callbacks, never from a control endpoint.
final class GestureProbeController: UIViewController, UIContextMenuInteractionDelegate,
    UIDragInteractionDelegate, UIDropInteractionDelegate {
    private let facts = UILabel()
    private let destination = UILabel()
    private var menuChoices = 0
    private var drops = 0
    private var dragStarts = 0
    private var dragEnds = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Gesture Probe"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close", style: .plain, target: self, action: #selector(close))
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
        destination.isUserInteractionEnabled = true; destination.layer.cornerRadius = 12
        destination.clipsToBounds = true
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
        facts.text =
            "Menu choices: \(menuChoices)\nDrag starts: \(dragStarts)\nDrag ends: \(dragEnds)\nDrops: \(drops)"
    }
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Confirm Probe menu") { _ in
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
        dragStarts += 1; refresh()
    }
    func dragInteraction(
        _ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation
    ) {
        dragEnds += 1; refresh()
    }
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
        drops += 1; destination.text = "Received: SOMA"
        destination.backgroundColor = .systemGreen.withAlphaComponent(0.2)
        refresh()
    }
}
