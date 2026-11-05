import AppKit
import SwiftUI

struct MailAccountView: View {
    @Bindable var store: MailboxStore
    @State private var removing: MailAccount?
    private var settings: AppSettings { store.settings }
    private var listedAccounts: [MailAccount] {
        store.accounts.filter { account in account.provider != .appleMail || store.connections.contains(where: { $0.id == account.id }) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(settings.text("Your inbox, in the menu bar.")).font(.title2.weight(.semibold))
                Text(settings.text("Read accounts already added to Apple Mail on this Mac."))
                    .foregroundStyle(.secondary)
                if !listedAccounts.isEmpty {
                    Divider()
                    Text(settings.text("Your accounts")).font(.system(size: 15, weight: .semibold))
                    ForEach(listedAccounts) { account in accountRow(account) }
                }
                Divider()
                Label(settings.text("Apple Mail · Read only"), systemImage: "envelope")
                    .font(.system(size: 15, weight: .semibold))
                Text(settings.text("Apple Mail handles sign-in and sync. Envl only reads your messages."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button(settings.text("Load Apple Mail accounts")) {
                    Task { await store.loadAccounts(); if store.canConnect { await store.connect() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
                let appleAccounts = store.accounts.filter { $0.provider == .appleMail }
                if !appleAccounts.isEmpty {
                    Picker(settings.text("Account"), selection: Binding(get: { appleAccounts.contains(where: { $0.id == store.accountID }) ? store.accountID : "" }, set: { id in Task { await store.selectAccount(id) } })) {
                        Text(settings.text("Choose an account")).tag("")
                        ForEach(appleAccounts) { account in Text(account.name).tag(account.id) }
                    }
                    if appleAccounts.contains(where: { $0.id == store.accountID }) {
                        Picker(settings.text("Mailbox"), selection: $store.mailboxName) {
                            Text(settings.text("Choose Inbox / INBOX")).tag("")
                            ForEach(store.mailboxes, id: \.self) { Text($0).tag($0) }
                        }
                        Button(settings.text("Show messages")) { Task { await store.connect() } }
                            .disabled(!store.canConnect || store.isBusy)
                    }
                }
                if !store.isConnected && !store.isDemo {
                    Button(settings.text("Try sample data")) { store.startDemo() }
                        .buttonStyle(.link)
                }
                Divider()
                upcomingProvider(.gmail)
                upcomingProvider(.outlook)
            }
            .padding(20)
        }
        .confirmationDialog(settings.text("Remove this account from Envl?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let account = removing {
                Button(settings.text("Remove account"), role: .destructive) { removing = nil; Task { await store.removeAccount(account.id) } }
            }
            Button(settings.text("Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(settings.text("The account will be disconnected from Envl. Any draft for this account will be discarded."))
        }
    }
    private func upcomingProvider(_ provider: MailProvider) -> some View {
        HStack {
            Text(provider.name).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 12)
            Text(settings.text("Coming soon"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func accountRow(_ account: MailAccount) -> some View {
        let connected = store.connections.contains { $0.id == account.id }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).font(.system(size: 14, weight: .medium))
                    Text(account.provider.name).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if let count = store.unreadCount(for: account.id) {
                    Text(settings.text("%d unread", count)).font(.system(size: 12.5)).monospacedDigit()
                }
                Menu {
                    Button(settings.text("Try again")) { Task { await store.retryAccount(account.id) } }
                    if account.provider != .appleMail {
                        Button(settings.text("Sign in again")) { Task { await store.connectProvider(account.provider) } }
                    }
                    Button(settings.text("Remove account"), role: .destructive) { removing = account }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(settings.text("Account actions"))
            }
            if let error = store.accountErrors[account.id] {
                Text(error).font(.system(size: 12.5)).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text(settings.text(connected ? "Connected" : "Not connected")).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .disabled(store.isBusy)
        .padding(.vertical, 4)
    }
}
