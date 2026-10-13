import KavachCore
import SwiftUI

/// First-run hero: teaches what the Doctor checks and offers the two scans —
/// shown instead of blank tabs before the first report.
struct ScanHero: View {
    let onScan: () -> Void
    let onDeepScan: () -> Void

    private struct Area: Identifiable {
        var id: String { label }
        let symbol: String
        let label: String
        let desc: String
        let tint: Color
    }

    private let areas = [
        Area(symbol: "gearshape", label: "System", desc: "Low Power Mode, memory pressure, Time Machine", tint: .accentColor),
        Area(symbol: "chevron.left.forwardslash.chevron.right", label: "VSCode",
             desc: "Extensions, orphan caches, database bloat", tint: .green),
        Area(symbol: "globe", label: "Browser", desc: "Memory, extension cost, caches", tint: .accentColor),
        Area(symbol: "internaldrive", label: "Disk", desc: "Free space, dev caches, ollama models", tint: .orange),
        Area(symbol: "power", label: "Startup", desc: "Third-party launch agents", tint: .green),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 60, height: 60)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    Text("Check your Mac's health").font(.title2.weight(.semibold))
                    Text("One read-only scan across key areas. Nothing changes without your confirmation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(areas) { area in
                        HStack(spacing: 12) {
                            Image(systemName: area.symbol)
                                .font(.callout)
                                .foregroundStyle(area.tint)
                                .frame(width: 34, height: 34)
                                .background(area.tint.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(area.label).font(.callout.weight(.semibold))
                                Text(area.desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 64)
                        .card(padding: 0)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Scan areas")

                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Button(action: onScan) { Label("Scan", systemImage: "stethoscope") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                        Button(action: onDeepScan) { Label("Deep scan", systemImage: "internaldrive") }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    Text("Deep scan also sweeps node_modules and dev caches — slower, but finds the most disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safe and read-only").font(.callout.weight(.semibold))
                        Text("Scans only read system information. No changes are made without your confirmation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .card(padding: 12)
            }
            .frame(maxWidth: 760)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Probe id → what the deep-scan loader says it's waiting on. Unknown ids
/// fall back to a generic line, so a new probe never breaks the loader.
private let probeLabels: [String: String] = [
    "low_power_mode": "Checking Low Power Mode…",
    "memory_truth": "Checking memory pressure…",
    "backup_risk": "Checking Time Machine…",
    "startup_items": "Checking startup items…",
    "disk_free": "Checking free disk space…",
    "load_vs_cores": "Checking CPU load…",
    "ollama_models": "Scanning ollama models…",
    "browser_processes": "Scanning browsers…",
    "browser_audio": "Checking browser audio and background settings…",
    "browser_storage": "Measuring browser caches…",
    "browser_extensions": "Scanning browser extensions…",
    "node_modules_sweep": "Sweeping node_modules folders…",
    "dev_caches": "Measuring dev caches…",
]

private func probeLabel(_ id: String) -> String {
    switch id {
    case VSCodeDoctor.orphans.id: "Scanning VSCode workspace caches…"
    case VSCodeDoctor.dbBloat.id: "Checking VSCode databases…"
    case VSCodeDoctor.extensionAudit.id: "Scanning VSCode extensions…"
    default: probeLabels[id] ?? "Scanning…"
    }
}

/// Loader for a running scan: what's being checked, how far along (deep scan
/// only — the quick scan has no progress events) and a way out.
struct ScanLoader: View {
    let deep: Bool
    let progress: ScanProgress?
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            VStack(spacing: 4) {
                Text(deep ? "Deep scanning…" : "Scanning…").font(.headline)
                Text(deep
                     ? progress.map { probeLabel($0.probeId) } ?? "Starting checks…"
                     : "Running read-only checks across your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if deep {
                VStack(spacing: 6) {
                    ProgressView(value: Double(progress?.index ?? 0), total: Double(max(progress?.total ?? 1, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9),
                                   value: progress?.index)
                        .accessibilityLabel("Deep scan progress")
                    // Fixed-height line so the layout never shifts when it appears.
                    Text(progress.map { "Check \($0.index + 1) of \($0.total)" } ?? " ")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive, action: onCancel) { Label("Cancel scan", systemImage: "xmark") }
                .buttonStyle(.bordered)
                .tint(.red)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
