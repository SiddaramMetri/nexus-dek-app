import NexusCore
import SwiftUI

extension Scope {
    var label: String {
        switch self {
        case .system: "System"
        case .claude: "Claude"
        case .vscode: "VSCode"
        case .browser: "Browser"
        case .disk: "Disk"
        case .startup: "Startup"
        }
    }
}

/// Nexus Doctor: a read-only health scan whose report fills in as each probe
/// finishes. Scope tabs filter the report; Scan always runs everything.
struct DoctorPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let scan = DoctorScanModel.shared
    /// nil = All.
    @ViewState private var tab: Scope?
    @ViewState private var journalOpen = false

    private enum Phase { case hero, scanning, deep, empty, report }

    // Tabs are DERIVED from the report — a scope without findings gets no tab.
    private var scopes: [Scope] {
        let present = Set(scan.findings.map(\.scope))
        return Scope.allCases.filter(present.contains)
    }

    private var effectiveTab: Scope? { tab.flatMap { scopes.contains($0) ? $0 : nil } }

    private var displayed: [Finding] {
        DoctorEngine.sorted(scan.findings.filter { f in effectiveTab.map { f.scope == $0 } ?? true })
    }

    private var phase: Phase {
        if scan.deepScanning { return .deep }
        // A running quick scan holds ONE loader while findings stream in behind
        // it, so the report reveals once instead of popping in per probe.
        if scan.scanning { return .scanning }
        if !displayed.isEmpty { return .report }
        return scan.hasScanned ? .empty : .hero
    }

    private var subtitle: String {
        if scan.scanning { return "Scanning…" }
        if scan.deepScanning { return "Deep scanning — sweeping node_modules and dev caches…" }
        guard scan.hasScanned else { return "Read-only health check" }
        let attention = displayed.filter { $0.severity != .green }.count
        return "\(attention) need\(attention == 1 ? "s" : "") attention · \(displayed.count - attention) healthy"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Doctor", subtitle: subtitle) { actions }
            if !scan.findings.isEmpty, !scan.isBusy { scopeTabs }
            Divider().padding(.top, 8)
            content
                .id(phase)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: phase)
        .sheet(isPresented: $journalOpen) { JournalSheet() }
    }

    // MARK: - Header

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            Button { journalOpen = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
                .help("Every change the app has made")
                .accessibilityLabel("History")
            Button(action: exportReport) { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .disabled(scan.findings.isEmpty)
                .help("Save a markdown report to the Desktop")
                .accessibilityLabel("Export report")
            // A running scan collapses both actions into one Cancel.
            if scan.isBusy {
                Button(role: .destructive) { scan.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.bordered)
                    .tint(.red)
            } else if phase != .hero {
                Button { scan.deepScan() } label: { Label("Deep scan", systemImage: "internaldrive") }
                    .buttonStyle(.bordered)
                    .help("Slow: the full scan plus node_modules and dev caches")
                Button { scan.scan() } label: { Label("Scan", systemImage: "stethoscope") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.leading, 4)
    }

    /// Only scopes that actually have findings get a tab — never a blank one.
    private var scopeTabs: some View {
        Picker("Report filter", selection: $tab) {
            Text("All").tag(Scope?.none)
            ForEach(scopes, id: \.self) { s in Text(s.label).tag(Scope?.some(s)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .deep:
            ScanLoader(deep: true, progress: scan.progress) { scan.cancel() }
        case .scanning:
            ScanLoader(deep: false, progress: nil) { scan.cancel() }
        case .hero:
            ScanHero(onScan: { scan.scan() }, onDeepScan: { scan.deepScan() })
        case .empty:
            EmptyState(symbol: "stethoscope", title: "Nothing to report",
                       message: "The last scan produced no findings.")
        case .report:
            report
        }
    }

    /// One card; the list scrolls inside it under the fixed header.
    private var report: some View {
        let shown = displayed
        let rows = DoctorReport.rows(shown)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if effectiveTab == .browser {
                    ForEach(DoctorReport.browserGroups(rows), id: \.title) { group in
                        sectionHeader(group.title)
                        rowList(group.findings, all: shown)
                    }
                } else {
                    rowList(rows, all: shown)
                }
            }
        }
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(24)
    }

    @ViewBuilder
    private func rowList(_ rows: [Finding], all: [Finding]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, f in
            if i > 0 { Divider() }
            FindingRow(finding: f, subFindings: DoctorReport.children(of: f, in: all))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
            Divider()
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Export

    private func exportReport() {
        let content = DoctorReport.markdown(scan.findings, dateLabel: Format.time(Date()))
        Task {
            do {
                let path = try await DoctorReport.export(content)
                model.toast("Report saved to Desktop — \(path)")
            } catch {
                model.report(error)
            }
        }
    }
}
