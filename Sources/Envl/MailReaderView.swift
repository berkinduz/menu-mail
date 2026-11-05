import AppKit
import SwiftUI

struct MailReaderView: View {
    let message: MailMessage
    @Bindable var store: MailboxStore
    let onDetach: ((MailMessage) -> Void)?
    let showsStoreErrors: Bool
    @State private var activeAttachmentID: String?
    @State private var attachmentError: String?

    init(message: MailMessage, store: MailboxStore, onDetach: ((MailMessage) -> Void)? = nil, showsStoreErrors: Bool = false) {
        self.message = message
        self.store = store
        self.onDetach = onDetach
        self.showsStoreErrors = showsStoreErrors
    }

    private var currentMessage: MailMessage {
        MailReaderPresentation.currentMessage(snapshot: message, rows: store.visibleMessages + store.messages, selection: store.selected)
    }

    var body: some View {
        let current = currentMessage
        VStack(alignment: .leading, spacing: 0) {
            MailReaderActions(message: current, store: store, onDetach: onDetach)
            Divider()
            if showsStoreErrors, let error = store.errorMessage {
                Text(error).font(.system(size: 12.5)).foregroundStyle(.red).textSelection(.enabled).padding(12)
            }
            if store.isMessageMoved(current) {
                HStack {
                    Text(store.settings.text("This message was moved from the inbox.")).font(.system(size: 12.5))
                    Spacer()
                    if store.canUndo(for: current) {
                        Button(store.settings.text("Undo")) { Task { await store.undoLastAction() } }
                    }
                }.padding(12)
            }
            MailReaderHeader(message: current, settings: store.settings,
                accountName: store.connections.first { $0.id == current.accountID }?.account.name)
            Divider()
            MailReaderBody(message: current, store: store)
            let attachments = current.attachments.filter { !($0.mimeType.hasPrefix("image/") && $0.contentID != nil) }
            if !attachments.isEmpty {
                Divider()
                MailReaderAttachments(attachments: attachments, settings: store.settings,
                    activeAttachmentID: activeAttachmentID,
                    open: { openAttachment($0, message: current) },
                    save: { saveAttachment($0, message: current) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: 14))
        .alert(store.settings.text("Attachment error"), isPresented: Binding(
            get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
                Button(store.settings.text("OK")) { attachmentError = nil }
            } message: {
                Text(attachmentError ?? "")
            }
    }

    private func openAttachment(_ attachment: MailAttachment, message: MailMessage) {
        Task {
            activeAttachmentID = attachment.id
            defer { activeAttachmentID = nil }
            do {
                let data = try await store.attachmentData(attachment, message: message)
                let url = try await Task.detached(priority: .userInitiated) {
                    try MailAttachmentTemporaryFiles.shared.write(data, name: attachment.name)
                }.value
                if !NSWorkspace.shared.open(url) {
                    throw MailError.message("No app could open this attachment. Save it and open it from Finder.")
                }
            } catch { showAttachmentError(error) }
        }
    }

    private func saveAttachment(_ attachment: MailAttachment, message: MailMessage) {
        let panel = NSSavePanel()
        panel.title = store.settings.text("Save attachment")
        panel.nameFieldStringValue = MailAttachmentTemporaryFiles.filename(attachment.name)
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                activeAttachmentID = attachment.id
                defer { activeAttachmentID = nil }
                do {
                    let data = try await store.attachmentData(attachment, message: message)
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: destination, options: .atomic)
                    }.value
                } catch { showAttachmentError(error) }
            }
        }
    }

    private func showAttachmentError(_ error: Error) {
        attachmentError = store.settings.message(for: error)
    }
}

private struct MailReaderHeader: View {
    let message: MailMessage
    let settings: AppSettings
    let accountName: String?
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(message.title(language: settings.language))
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline) {
                Text(message.sender(language: settings.language))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(message.shortDate(locale: settings.locale))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(settings.text("Message details"), isExpanded: $detailsExpanded) {
                ScrollView {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                        detailRow("From", addresses: message.from.map { [$0.emailAddress] } ?? [])
                        detailRow("To", addresses: message.recipients)
                        if !message.copyRecipients.isEmpty { detailRow("Cc", addresses: message.copyRecipients) }
                        let replyTo = message.replyTo.isEmpty ? message.body?.replyTo ?? [] : message.replyTo
                        if !replyTo.isEmpty { detailRow("Reply-To", addresses: replyTo) }
                        if let accountName { GridRow { detailLabel("Account"); Text(accountName) } }
                        GridRow { detailLabel("Date"); Text(message.longDate(locale: settings.locale)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 6)
                }
                .frame(maxHeight: 120)
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
    }

    private func detailLabel(_ key: String) -> some View {
        Text(settings.text(key)).foregroundStyle(.secondary)
    }

    private func detailRow(_ key: String, addresses: [MailMessage.Address]) -> some View {
        GridRow(alignment: .top) {
            detailLabel(key)
            Text(addresses.isEmpty ? settings.text("Not provided") : addresses.map { address in
                if let name = address.name, !name.isEmpty, let email = address.address { return "\(name) <\(email)>" }
                return address.address ?? address.name ?? settings.text("Unknown recipient")
            }.joined(separator: ", "))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MailReaderActions: View {
    let message: MailMessage
    let store: MailboxStore
    let onDetach: ((MailMessage) -> Void)?
    private var settings: AppSettings { store.settings }
    private var capabilities: MailCapabilities { store.capabilities(for: message.accountID ?? "") }

    var body: some View {
        HStack(spacing: 12) {
            if capabilities.contains(.readState) {
                action(message.isRead == true ? "Mark as unread" : "Mark as read",
                    image: message.isRead == true ? "envelope.badge" : "envelope.open",
                    perform: .markRead(message.isRead != true))
            }
            if capabilities.contains(.star) {
                action(message.isStarred == true ? "Unstar" : "Star", image: message.isStarred == true ? "star.fill" : "star",
                    perform: .star(message.isStarred != true))
            }
            if capabilities.contains(.send) {
                Menu {
                    Button(settings.text("Reply")) { store.reply(to: message) }
                    Button(settings.text("Reply all")) { store.reply(to: message, all: true) }
                    Button(settings.text("Forward")) { store.reply(to: message, forward: true) }
                } label: { Label(settings.text("Reply"), systemImage: "arrowshape.turn.up.left") }
                .labelStyle(.iconOnly)
                .help(settings.text("Reply"))
                .disabled(store.isBusy)
            }
            if capabilities.contains(.archive) { action("Archive", image: "archivebox", perform: .archive) }
            if capabilities.contains(.trash) { action("Move to Trash", image: "trash", perform: .trash) }
            Spacer(minLength: 0)
            if let url = MailReaderPresentation.originalURL(for: message) {
                Button { NSWorkspace.shared.open(url) } label: { Label(settings.text("Open original message"), systemImage: "arrow.up.forward.app") }
                    .labelStyle(.iconOnly)
                    .help(settings.text("Open original message"))
            }
            if let onDetach {
                Button { onDetach(message) } label: { Label(settings.text("Open in window"), systemImage: "macwindow") }
                    .labelStyle(.iconOnly)
                    .help(settings.text("Open in window"))
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func action(_ title: String, image: String, perform mailAction: MailAction) -> some View {
        Button { Task { await store.perform(mailAction, on: message) } } label: { Label(settings.text(title), systemImage: image) }
            .labelStyle(.iconOnly)
            .help(settings.text(title))
            .disabled(store.isBusy || store.isMessageMoved(message))
    }
}

private struct MailReaderBody: View {
    let message: MailMessage
    let store: MailboxStore
    private var settings: AppSettings { store.settings }

    var body: some View {
        Group {
            if let body = message.body {
                MailHTMLView(body: body, allowRemoteContent: settings.allowRemoteContent, language: settings.language).id(message.listID)
            } else if store.isLoadingBody, store.selected?.listID == message.listID {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(settings.text("Opening message…"))
                    Text(settings.text("You can return to your inbox while this loads."))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label(settings.text("Could not load the message"), systemImage: "envelope.badge")
                } description: {
                    Text(settings.text("Open another message or try again."))
                } actions: {
                    Button(settings.text("Try again")) { store.open(message) }.disabled(store.isLoadingList)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MailReaderAttachments: View {
    let attachments: [MailAttachment]
    let settings: AppSettings
    let activeAttachmentID: String?
    let open: (MailAttachment) -> Void
    let save: (MailAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text("Attachments")).font(.system(size: 13, weight: .medium))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 8) {
                            Image(systemName: "doc").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                                if let size = attachment.size {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if activeAttachmentID == attachment.id { ProgressView().controlSize(.mini) }
                            Button(settings.text("Open")) { open(attachment) }
                            Button(settings.text("Save…")) { save(attachment) }
                        }
                        .font(.system(size: 12.5))
                        .disabled(activeAttachmentID != nil)
                    }
                }
            }
            .frame(height: min(CGFloat(attachments.count) * 36, 108))
        }
        .padding(12)
    }
}

enum MailReaderPresentation {
    static func currentMessage(snapshot: MailMessage, rows: [MailMessage], selection: MailMessage?) -> MailMessage {
        var displayed = snapshot
        if let selection, selection.listID == snapshot.listID { displayed = selection }
        if displayed.body == nil { displayed.body = snapshot.body }
        if let row = rows.first(where: { $0.listID == snapshot.listID }) {
            displayed.isRead = row.isRead
            displayed.isStarred = row.isStarred
        }
        return displayed
    }

    static func originalURL(for message: MailMessage) -> URL? {
        if let webURL = message.webURL { return webURL }
        guard let identifier = message.internetMessageID ?? message.body?.messageID, !identifier.isEmpty,
              let encoded = identifier.addingPercentEncoding(withAllowedCharacters:
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { return nil }
        return URL(string: "message://\(encoded)")
    }
}

/// Keeps user-opened attachment files available to other apps until Envl exits.
final class MailAttachmentTemporaryFiles: @unchecked Sendable {
    static let shared = MailAttachmentTemporaryFiles()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Envl-attachments-\(UUID().uuidString)", isDirectory: true)
    private let lock = NSLock()
    private var terminationObserver: (any NSObjectProtocol)?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        removeAll()
    }

    static func filename(_ name: String) -> String {
        let component = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let clean = component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        return clean.isEmpty || clean == "." || clean == ".." ? "Attachment" : clean
    }

    func write(_ data: Data, name: String) throws -> URL {
        try lock.withLock {
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(Self.filename(name))
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    func removeAll() { lock.withLock { try? FileManager.default.removeItem(at: directory) } }
}
