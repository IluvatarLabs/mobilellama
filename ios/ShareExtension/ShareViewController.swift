import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let group = "group.app.mobollama.mobollama"
  private let identifier = UUID().uuidString
  private var directory: URL?
  private var items: [[String: Any]] = []
  private let details = UITextView()
  private let saveButton = UIButton(type: .system)

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = "Share to MobileLlama"
    title.font = .preferredFont(forTextStyle: .title2)
    title.adjustsFontForContentSizeCategory = true
    details.font = .preferredFont(forTextStyle: .body)
    details.adjustsFontForContentSizeCategory = true
    details.isEditable = false
    details.text = "Preparing your content…"
    saveButton.setTitle("Save for MobileLlama", for: .normal)
    saveButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    saveButton.isEnabled = false
    saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
    let cancel = UIButton(type: .system)
    cancel.setTitle("Cancel", for: .normal)
    cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [title, details, saveButton, cancel])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
    Task { await prepare() }
  }

  @MainActor private func prepare() async {
    do {
      guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
        throw failure("Shared storage is unavailable.")
      }
      let root = container.appendingPathComponent("Intake", isDirectory: true).appendingPathComponent(identifier, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      directory = root
      let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
      for (index, provider) in providers.enumerated() {
        let name = provider.suggestedName ?? "Item \(index + 1)"
        do {
          if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await copyFile(provider, type: UTType.image.identifier, index: index, name: "image.png", image: true)
            items.append(["kind": "image", "name": name, "file": url.lastPathComponent])
          } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) || ["txt", "md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            let type = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ? UTType.pdf.identifier : UTType.plainText.identifier
            let fileName = type == UTType.pdf.identifier && !(name.lowercased().hasSuffix(".pdf")) ? "\(name).pdf" : name
            let url = try await copyFile(provider, type: type, index: index, name: fileName, image: false)
            items.append(["kind": "document", "name": fileName, "file": url.lastPathComponent])
          } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let value = try await load(provider, type: UTType.url.identifier)
            let text = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
            try addText(text, name: name)
          } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try await load(provider, type: UTType.plainText.identifier)
            let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try addText(text, name: name)
          } else {
            throw failure("Unsupported content. Share text, a URL, an image, PDF, TXT, or Markdown.")
          }
        } catch {
          items.append(["kind": "error", "name": name, "error": error.localizedDescription])
        }
      }
      details.text = items.map { item in
        if let error = item["error"] as? String { return "\(item["name"] ?? "Item"): \(error)" }
        return (item["text"] as? String) ?? (item["name"] as? String) ?? "Item"
      }.joined(separator: "\n\n") + "\n\nOpen MobileLlama after saving to choose a draft. Nothing is sent to a server."
      saveButton.isEnabled = items.contains { $0["kind"] as? String != "error" }
    } catch { details.text = error.localizedDescription }
  }

  private func addText(_ text: String, name: String) throws {
    guard !text.isEmpty, text.utf8.count <= 64 * 1024 else { throw failure("Text must be between 1 byte and 64 KB.") }
    items.append(["kind": "text", "name": name, "text": text])
  }

  private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
        if let error { continuation.resume(throwing: error) }
        else if let value { continuation.resume(returning: value) }
        else { continuation.resume(throwing: self.failure("This item could not be read.")) }
      }
    }
  }

  private func copyFile(_ provider: NSItemProvider, type: String, index: Int, name: String, image: Bool) async throws -> URL {
    guard let directory else { throw failure("Shared storage is unavailable.") }
    let safeName = (name as NSString).lastPathComponent
    let destination = directory.appendingPathComponent("\(index)-\(safeName)")
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        do {
          if let error { throw error }
          guard let url else { throw self.failure("This file could not be read.") }
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size > 0, size <= 8 * 1024 * 1024 else { throw self.failure("A file can be at most 8 MB.") }
          if image {
            guard let data = UIImage(contentsOfFile: url.path)?.pngData(), data.count <= 8 * 1024 * 1024 else { throw self.failure("The image cannot be prepared within the 8 MB limit.") }
            try data.write(to: destination, options: .atomic)
          } else {
            // Copy inside the provider callback: its URL expires on return.
            try FileManager.default.copyItem(at: url, to: destination)
          }
          continuation.resume(returning: destination)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  @objc private func save() {
    do {
      guard let directory else { return }
      let data = try JSONSerialization.data(withJSONObject: ["id": identifier, "items": items])
      try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
      details.text = "Saved for MobileLlama. Open the app to review your draft and send when ready."
      saveButton.setTitle("Done", for: .normal)
      saveButton.removeTarget(self, action: #selector(save), for: .touchUpInside)
      saveButton.addTarget(self, action: #selector(done), for: .touchUpInside)
    } catch { details.text = "Could not save: \(error.localizedDescription)" }
  }
  @objc private func done() { extensionContext?.completeRequest(returningItems: nil) }
  @objc private func cancelShare() {
    // Once Save succeeded, Cancel/closing must not discard acknowledged content.
    if let directory, !FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { try? FileManager.default.removeItem(at: directory) }
    extensionContext?.completeRequest(returningItems: nil)
  }
  private func failure(_ message: String) -> NSError { NSError(domain: "MobileLlamaShare", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
