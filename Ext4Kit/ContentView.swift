import Combine
import FSKit
import SwiftUI

/// Live status of the bundled FSKit module, read via `FSClient` (macOS 15.4+).
/// There is no public API to *enable* a module, so the UI deep-links to the
/// System Settings pane and re-polls when the app becomes active again.
@MainActor
final class ExtensionStatusModel: ObservableObject {
    static let moduleBundleID = "com.rayhanadev.Ext4Kit.Ext4KitExtension"

    enum Status {
        case checking
        case enabled
        case disabled
        case notInstalled
        case unavailable(String)
    }

    @Published var status: Status = .checking

    func refresh() {
        Task {
            do {
                let extensions = try await FSClient.shared.installedExtensions
                if let module = extensions.first(where: {
                    $0.bundleIdentifier == Self.moduleBundleID
                }) {
                    status = module.isEnabled ? .enabled : .disabled
                } else {
                    status = .notInstalled
                }
            } catch {
                status = .unavailable(error.localizedDescription)
            }
        }
    }

    func openSystemSettings() {
        let url = URL(
            string:
                "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule"
        )!
        NSWorkspace.shared.open(url)
    }
}

struct ContentView: View {
    @StateObject private var model = ExtensionStatusModel()
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: statusSymbol)
                .imageScale(.large)
                .font(.system(size: 48))
                .foregroundStyle(statusTint)

            Text("Ext4Kit")
                .font(.title)
                .bold()

            statusLine

            if case .disabled = model.status {
                Button("Open System Settings") {
                    model.openSystemSettings()
                }
                .keyboardShortcut(.defaultAction)
                Text(
                    "Turn it on under General → Login Items & Extensions → File System Extensions."
                )
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }

            if case .enabled = model.status {
                GroupBox("Mount a Volume") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            verbatim: """
                                sudo mkdir -p /Volumes/ext4
                                sudo mount -F -t ext4 diskN /Volumes/ext4
                                """
                        )
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)

                        Text(
                            "Pass the BSD name (`diskN`), not `/dev/diskN`. Unmount with `sudo umount /Volumes/ext4`."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Link(
                    "Source & License",
                    destination: URL(string: "https://github.com/rayhanadev/Ext4Kit")!)
                Link(
                    "Third-Party Licenses",
                    destination: URL(
                        string:
                            "https://github.com/rayhanadev/Ext4Kit/blob/main/THIRD_PARTY_LICENSES.md"
                    )!)
            }
            .font(.footnote)

            Text(
                "Ext4Kit links lwext4, so distributed builds fall under GPL-2.0. See Third-Party Licenses."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 360)
        .onAppear { model.refresh() }
        .onChange(of: activeState) { _, newValue in
            // Re-poll when the user comes back from System Settings.
            if newValue == .key { model.refresh() }
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .checking: return "externaldrive.badge.questionmark"
        case .enabled: return "externaldrive.badge.checkmark"
        case .disabled: return "externaldrive.badge.xmark"
        case .notInstalled, .unavailable: return "externaldrive.badge.exclamationmark"
        }
    }

    private var statusTint: Color {
        switch model.status {
        case .enabled: return .green
        case .disabled: return .orange
        case .checking: return .secondary
        case .notInstalled, .unavailable: return .red
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .checking:
            Text("Checking status…").font(.headline)
        case .enabled:
            Text("Enabled & ready to mount.").font(.headline)
        case .disabled:
            Text("Ext4Kit is turned off.").font(.headline)
        case .notInstalled:
            Text("Move Ext4Kit to your Applications folder, then open it once to register the extension.")
                .font(.headline)
                .multilineTextAlignment(.center)
        case .unavailable:
            Text("Couldn't read the extension status. Reopen Ext4Kit to try again.")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    ContentView()
}
