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
                Button("Open System Settings…") {
                    model.openSystemSettings()
                }
                .keyboardShortcut(.defaultAction)
                Text(
                    "Toggle Ext4Kit on under General → Login Items & Extensions → File System Extensions."
                )
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }

            if case .enabled = model.status {
                GroupBox("Mounting a volume") {
                    Text(
                        """
                        sudo mkdir -p /Volumes/ext4
                        sudo mount -F -t ext4 diskN /Volumes/ext4

                        Use the BSD name (diskN, no /dev/ prefix). Unmount \
                        with `sudo umount /Volumes/ext4`. Format a device \
                        with `newfs_fskit -t ext4 -L LABEL /dev/diskNsM`.
                        """
                    )
                    .font(.system(.callout, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Link(
                    "Source & license",
                    destination: URL(string: "https://github.com/rayhanadev/Ext4Kit")!)
                Link(
                    "Third-party licenses",
                    destination: URL(
                        string:
                            "https://github.com/rayhanadev/Ext4Kit/blob/main/THIRD_PARTY_LICENSES.md"
                    )!)
            }
            .font(.footnote)

            Text(
                "Ext4Kit statically links lwext4; distributed builds are subject to GPL-2.0 terms — see Third-party licenses."
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
            Text("Checking extension status…").font(.headline)
        case .enabled:
            Text("File system extension is enabled.").font(.headline)
        case .disabled:
            Text("File system extension is installed but disabled.").font(.headline)
        case .notInstalled:
            Text("Extension not registered yet — run this app once from its installed location, then relaunch.")
                .font(.headline)
                .multilineTextAlignment(.center)
        case .unavailable(let why):
            Text("Could not query FSKit: \(why)")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    ContentView()
}
