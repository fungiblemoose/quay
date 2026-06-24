import Foundation
import QuayCore

#if os(macOS)
import SwiftUI

// QuayBar — a MenuBarExtra that reflects quayd's status.json and offers a single
// safe action: Restart.
//
// Reads are a poll of status.json (quayd is the only writer of that file). The
// Restart button deliberately does NOT create or start containers — it only
// `container stop`s the service and lets quayd reconcile it back up on its next
// tick. A stop is indistinguishable from a crash, which the supervisor already
// handles, so quayd stays the SINGLE WRITER of start/create state and there is no
// two-writers race. That's the whole reason there's no Start/Stop button here.

@main
struct QuayBarApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            QuayMenu(model: model)
        } label: {
            Image(systemName: model.aggregateSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Resolve the `container` CLI. A launchd-started GUI app may not inherit a PATH
/// with /usr/local/bin, so prefer absolute paths and fall back to bare `container`.
func resolveContainerExecutable() -> String {
    let candidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return "container"
}

/// Polls status.json on a timer. (A v2 could watch the file with FSEvents.)
@MainActor
final class StatusModel: ObservableObject {
    @Published var snapshot: StatusSnapshot?
    @Published var loadError: String?
    /// Container names with an in-flight restart, so the UI can show progress
    /// and prevent double-taps.
    @Published var restarting: Set<String> = []
    /// Last action error, surfaced in the menu until the next successful poll.
    @Published var actionError: String?

    private var timer: Timer?
    private let store = StatusStore()
    private let pollInterval: TimeInterval = 3
    private let control: ContainerClient

    init(control: ContainerClient = CLIContainerClient(executable: resolveContainerExecutable())) {
        self.control = control
        reload()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func reload() {
        do {
            snapshot = try store.read()
            loadError = nil
        } catch {
            snapshot = nil
            loadError = "No status yet (\(store.url.lastPathComponent)). Is quayd running?"
        }
    }

    /// Recycle a service: stop the container and let quayd start it again on its
    /// next reconcile tick. We never start it ourselves — quayd stays the single
    /// writer of start/create state.
    func restart(containerName: String) {
        guard !restarting.contains(containerName) else { return }
        restarting.insert(containerName)
        actionError = nil
        let control = self.control
        Task { @MainActor in
            do {
                try await control.stop(name: containerName)
            } catch {
                actionError = "Restart failed for \(containerName): \(error.localizedDescription)"
            }
            restarting.remove(containerName)
            reload()
        }
    }

    var aggregate: HealthDot { snapshot?.aggregate ?? .gray }

    /// SF Symbol for the aggregate glyph.
    var aggregateSymbol: String {
        switch aggregate {
        case .green:  return "shippingbox.fill"
        case .yellow: return "shippingbox"
        case .red:    return "exclamationmark.triangle.fill"
        case .gray:   return "shippingbox"
        }
    }
}

struct QuayMenu: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if let snap = model.snapshot {
                if !snap.containerRuntimeAvailable {
                    Label(snap.note ?? "container runtime unavailable", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if snap.stacks.isEmpty {
                    Text("No stacks configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snap.stacks, id: \.stack) { stack in
                        stackView(stack)
                    }
                }
                if !snap.orphans.isEmpty {
                    Divider()
                    Text("Orphans (not managed): \(snap.orphans.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = model.actionError {
                    Divider()
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Divider()
                Text("Updated \(snap.generatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.loadError ?? "Loading…")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Refresh") { model.reload() }
            Button("Quit QuayBar") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Circle().fill(color(for: model.aggregate)).frame(width: 10, height: 10)
            Text("Quay").font(.headline)
            Spacer()
            if let v = model.snapshot?.runtimeVersion {
                Text(v).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func stackView(_ stack: StackStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stack.stack.uppercased())
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            ForEach(stack.services, id: \.containerName) { svc in
                HStack(spacing: 8) {
                    Circle().fill(color(for: svc.health)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(svc.service)
                        Text(svc.state.rawValue + (svc.restartCount > 0 ? " · restarts: \(svc.restartCount)" : ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.restarting.contains(svc.containerName) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            model.restart(containerName: svc.containerName)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Restart \(svc.service) — stops it; quayd brings it back up")
                    }
                }
            }
        }
    }

    private func color(for dot: HealthDot) -> Color {
        switch dot {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        case .gray:   return .gray
        }
    }
}

#else

// QuayBar is a macOS SwiftUI app; on other platforms it only builds as a stub so
// the whole package still compiles (e.g. for CI / QuayCore tests on Linux).
@main
struct QuayBarApp {
    static func main() {
        FileHandle.standardError.write(Data("QuayBar requires macOS 14+ (runtime: macOS 26+).\n".utf8))
    }
}

#endif
