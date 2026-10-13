import KavachCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionsPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var dragging: String?

    var body: some View {
        let services = model.reconciled
        let hasRuns = model.runs.values.contains { !$0.isEmpty }
        VStack(spacing: 0) {
            PageHeader(title: "Sessions", subtitle: "How long each service has run") {
                if hasRuns {
                    Button("Clear all") { model.clearSessions() }
                }
            }
            Divider()
            if services.isEmpty {
                EmptyState(symbol: "clock", title: "No services", message: "Add a service to start tracking sessions.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Run history is recorded while \(AppInfo.name) is open. The current run's uptime is read from the live process."
                             + (services.count > 1 ? " Drag a card to reorder." : ""))
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(services) { s in
                            SessionCard(service: s, runs: model.runs[s.formula] ?? [])
                                .opacity(dragging == s.formula ? 0.4 : 1)
                                .onDrag {
                                    dragging = s.formula
                                    return NSItemProvider(object: s.formula as NSString)
                                }
                                .onDrop(of: [.text], delegate: ReorderDrop(target: s.formula, dragging: $dragging, model: model))
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
}

private struct SessionCard: View {
    let service: ReconciledService
    let runs: [Run]
    @ViewState private var open = false

    var body: some View {
        // Ticks once a second so open runs and live uptime count up.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let nowMs = ctx.date.timeIntervalSince1970 * 1000
            let total = runs.reduce(0.0) { $0 + (($1.endMs ?? nowMs) - $1.startMs) } / 1000
            VStack(alignment: .leading, spacing: 0) {
                Button { if !runs.isEmpty { withAnimation(.snappy) { open.toggle() } } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: service.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.displayName).font(.headline)
                            if service.isRunning, let up = service.uptimeSecs {
                                Label("up \(Format.duration(up))", systemImage: "clock").font(.caption).foregroundStyle(.green)
                            }
                        }
                        Spacer()
                        Stat(label: "Total uptime", value: Format.duration(UInt64(max(0, total))))
                            .frame(width: 110, alignment: .leading)
                        Stat(label: "Runs", value: "\(runs.count)").frame(width: 50, alignment: .leading)
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                            .opacity(runs.isEmpty ? 0 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open && !runs.isEmpty {
                    Divider().padding(.vertical, 10)
                    ForEach(runs.reversed(), id: \.startMs) { r in
                        HStack {
                            Text("\(Format.time(Date(timeIntervalSince1970: r.startMs / 1000))) → \(r.endMs.map { Format.time(Date(timeIntervalSince1970: $0 / 1000)) } ?? "now")")
                            Spacer()
                            Text(Format.duration(UInt64(max(0, ((r.endMs ?? nowMs) - r.startMs) / 1000))))
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                    }
                }
            }
            .card()
        }
    }
}
