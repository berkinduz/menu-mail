import SwiftUI

struct AboutView: View {
    let settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.blue)
                    .frame(width: 88, height: 88)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
                VStack(spacing: 6) {
                    Text("MenuMail").font(.title2.weight(.semibold))
                    Text(settings.text("Version %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(settings.text("Your inbox, in the menu bar."))
                    .foregroundStyle(.secondary)
                VStack(spacing: 14) {
                    Link(destination: URL(string: "https://github.com/berkinduz")!) {
                        Label(settings.text("Made by %@", "berkinduz"), systemImage: "person.crop.circle")
                    }
                    Link(destination: URL(string: "mailto:mberkinduz@gmail.com")!) {
                        Label("mberkinduz@gmail.com", systemImage: "envelope")
                    }
                    Link(destination: URL(string: "https://github.com/berkinduz/menu-mail")!) {
                        Label(settings.text("Source code & contributions"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                .font(.system(size: 13))
                Link(destination: URL(string: "https://buymeacoffee.com/berkinduz")!) {
                    Label(settings.text("Buy me a coffee"), systemImage: "cup.and.saucer.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1, green: 0.37, blue: 0.37))
                Text(settings.text("Free to use. Open to contributions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }
}
