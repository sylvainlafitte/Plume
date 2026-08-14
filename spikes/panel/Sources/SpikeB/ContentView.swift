import AppKit
import SwiftUI

/// Live readout of who owns focus. Polled rather than observed because
/// `NSWorkspace.frontmostApplication` has no useful KVO story.
@MainActor
@Observable
final class FocusMonitor {
    var frontmostApp = "—"
    var plumeIsActive = false
    var panelIsKey = false
    var keystrokesReceived = 0

    private var timer: Timer?

    func start(panel: @escaping @MainActor () -> NSWindow?) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.frontmostApp =
                    NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
                self.plumeIsActive = NSApp.isActive
                self.panelIsKey = panel()?.isKeyWindow ?? false
            }
        }
    }
}

struct SpikeContentView: View {
    let title: String
    let hiddenFromShare: Bool
    @Bindable var monitor: FocusMonitor
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(hiddenFromShare ? "sharingType = .none" : "sharingType = .readOnly")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hiddenFromShare ? .orange : .secondary)
            }

            // Distinctive string to look for in a screen recording.
            Text(hiddenFromShare ? "PLUME-SPIKE-B-HIDDEN" : "PLUME-SPIKE-B-CONTROL")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(hiddenFromShare ? .orange : .green)

            Divider()

            Text("Type here while a video call is frontmost:")
                .font(.caption).foregroundStyle(.secondary)
            TextField("notes…", text: $typed, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .onChange(of: typed) { _, _ in monitor.keystrokesReceived += 1 }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                row("frontmost app", monitor.frontmostApp,
                    ok: monitor.frontmostApp != "SpikeB")
                row("NSApp.isActive", monitor.plumeIsActive ? "true" : "false",
                    ok: !monitor.plumeIsActive)
                row("panel isKeyWindow", monitor.panelIsKey ? "true" : "false", ok: true)
                row("keystrokes landed", "\(monitor.keystrokesReceived)",
                    ok: monitor.keystrokesReceived > 0)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(ok ? Color.primary : Color.red).bold(!ok)
        }
    }
}
