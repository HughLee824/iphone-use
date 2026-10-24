import SwiftUI
import UIKit

// Ordinary UIKit search/navigation. Results are local strings; there is no network
// request, clipboard access or injection endpoint. Only Return invokes search.
final class SearchProbeController: UIViewController, UITextFieldDelegate {
    private let query = UITextField()
    private let facts = UILabel()
    private var edits = 0
    private var searches = 0
    private let catalog = ["苹果", "苹果派", "香蕉", "香蕉面包", "橙子"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Local search"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close", style: .plain, target: self, action: #selector(close))
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
        facts.text =
            """
            Query (complete): \(text)\nUTF8: \(text.utf8.count)\nEdits: \(edits)  Searches:\
             \(searches)\nActive: \(query.isFirstResponder)
            """
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        searches += 1
        let text = query.text ?? ""
        query.resignFirstResponder(); refresh()
        let matches = text.isEmpty ? [] : catalog.filter { $0.contains(text) }
        let result = UIViewController(); result.title = "Local results"
        result.view.backgroundColor = .systemBackground
        let label = UILabel(); label.numberOfLines = 0; label.font = .systemFont(ofSize: 18)
        label.text =
            """
            Query (complete): \(text)\nUTF8: \(text.utf8.count)\nSearches: \(searches)\nMatches:\
             \(matches.count)\n\n
            """
            + (matches.isEmpty ? "No local matches" : matches.joined(separator: "\n"))
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
