import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.checkmark")
                .imageScale(.large)
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Ext4Kit")
                .font(.title)
                .bold()

            Text("Extension installed.")
                .font(.headline)

            Text(
                "Enable it in System Settings → General → Login Items & Extensions → File System Extensions, then mount an ext4 volume with:\n\nsudo mount -F -t ext4 diskN /mnt/point"
            )
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 280)
    }
}

#Preview {
    ContentView()
}
