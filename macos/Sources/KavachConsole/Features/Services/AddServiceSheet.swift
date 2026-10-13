import KavachCore
import SwiftUI

/// "Connect a service": search brew, or pick from services installed on this
/// Mac that aren't in the list yet, or a popular one.
struct AddServiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var results: [String]?
    @ViewState private var searching = false

    static let popular = ["mysql", "mariadb", "valkey", "mongodb-community", "memcached", "rabbitmq", "nginx", "elasticsearch"]

    private func isAdded(_ f: String) -> Bool {
        model.intent.managed.contains { bareFormula($0.formula) == bareFormula(f) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect a service").font(.title3.weight(.semibold))
                Text("Only formulae Homebrew can run as a service can be added.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Search Homebrew formulae (e.g. mysql)…", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        searchResults
                    } else {
                        suggestions
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: query) { await search() }
    }

    @ViewBuilder
    private var searchResults: some View {
        if searching && results == nil {
            ProgressView().controlSize(.small).padding(6)
        } else if let results, results.isEmpty {
            Text("No formulae found.").foregroundStyle(.secondary).padding(6)
        } else {
            ForEach((results ?? []).prefix(40), id: \.self) { f in
                Button { model.addManaged(f) } label: {
                    HStack {
                        Text(f).font(.body.monospaced())
                        Spacer()
                        if isAdded(f) {
                            Label("added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "plus").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .disabled(isAdded(f))
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let installed = model.brewServices.map(\.name).filter { !isAdded($0) }
        if !installed.isEmpty {
            Text("Installed on this Mac · not in your list").font(.caption).foregroundStyle(.secondary)
            chips(installed).padding(.bottom, 10)
        }
        Text("Popular services").font(.caption).foregroundStyle(.secondary)
        chips(Self.popular.filter { !installed.contains($0) })
    }

    private func chips(_ list: [String]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(list, id: \.self) { f in
                Button { model.addManaged(f) } label: {
                    Label(f, systemImage: isAdded(f) ? "checkmark" : "plus").font(.callout.monospaced())
                }
                .disabled(isAdded(f))
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = nil; return }
        try? await Task.sleep(for: .milliseconds(250))  // debounce
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await model.services.search(q)
            if !Task.isCancelled { results = found }
        } catch {
            if !Task.isCancelled { results = []; model.report(error) }
        }
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxW = max(maxW, x)
            rowH = max(rowH, s.height)
        }
        return (maxW, y + rowH)
    }
}
