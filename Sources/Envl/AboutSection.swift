import AppKit
import SwiftUI

struct AboutSection: View {
    let settings: AppSettings
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Envl").font(.system(size: 16, weight: .semibold))
                    Text(settings.text("Version %@", version)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(settings.text("Your inbox, in the menu bar."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Link(settings.text("Made by %@", "berkinduz"), destination: URL(string: "https://github.com/berkinduz")!)
                .font(.system(size: 13))
            HStack(spacing: 18) {
                Link(settings.text("Source code"), destination: URL(string: "https://github.com/berkinduz/menu-mail")!)
                    .help(settings.text("Source code & contributions"))
                Link(settings.text("Contact"), destination: URL(string: "mailto:mberkinduz@gmail.com")!)
                    .help("mberkinduz@gmail.com")
                Link(settings.text("Buy me a coffee"), destination: URL(string: "https://buymeacoffee.com/berkinduz")!)
            }
            .font(.system(size: 13))
            Text(settings.text("Free to use. Open to contributions."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
