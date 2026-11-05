import SwiftUI

struct MailComposerView: View {
    @Bindable var store: MailboxStore
    @State private var confirmDiscard = false
    private var settings: AppSettings { store.settings }

    private func field(_ key: WritableKeyPath<MailDraft, String>) -> Binding<String> {
        Binding(get: { store.draft?[keyPath: key] ?? "" }, set: { store.draft?[keyPath: key] = $0 })
    }

    var body: some View {
        VStack(spacing: 12) {
            if let draft = store.draft {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(settings.text("From"))
                        Picker(settings.text("Sending account"), selection: field(\.accountID)) {
                            ForEach(store.connections.filter { store.capabilities(for: $0.id).contains(.send) }) { connection in
                                Text(connection.account.address ?? connection.account.name).tag(connection.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(draft.replyToMessageID != nil || draft.forwardMessageID != nil)
                    }
                    GridRow {
                        Text(settings.text("To"))
                        TextField(settings.text("Recipient email addresses"), text: field(\.to))
                    }
                    GridRow { Text("Cc"); TextField(settings.text("Optional"), text: field(\.cc)) }
                    GridRow { Text("Bcc"); TextField(settings.text("Optional"), text: field(\.bcc)) }
                    GridRow {
                        Text(settings.text("Subject"))
                        TextField(settings.text("Subject"), text: field(\.subject))
                    }
                }
                .textFieldStyle(.roundedBorder)
                Divider()
                if draft.forwardMessageID != nil {
                    Label(settings.text("The complete original message and its attachments will be included."), systemImage: "arrowshape.turn.up.right")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: field(\.text))
                    .font(.system(size: 15))
                    .accessibilityLabel(settings.text("Message text"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(settings.text("Your draft stays here while Envl is running."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(settings.text("Discard draft"), role: .destructive) { confirmDiscard = true }
                    Spacer()
                    Button(settings.text("Save & close")) { store.goBack() }
                    Button(settings.text(store.isSending ? "Sending message…" : "Send")) {
                        Task { await store.sendDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .disabled(store.isSending)
        .confirmationDialog(settings.text("Discard this draft?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(settings.text("Discard draft"), role: .destructive) { store.discardDraft() }
            Button(settings.text("Cancel"), role: .cancel) {}
        }
    }
}
