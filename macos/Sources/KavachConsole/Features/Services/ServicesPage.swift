import KavachCore
import SwiftUI
import UniformTypeIdentifiers

struct ServicesPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var query = ""
    @ViewState private var addOpen = false
    @ViewState private var dragging: String?

    private var filtered: [ReconciledService] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.reconciled
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayName.lowercased().contains(q) || $0.formula.lowercased().contains(q) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PageHeader(title: "Services", subtitle: "Manage your local services") {
                SearchField(prompt: "Search…", text: $query).frame(width: 180)
                ThemeToggle()
                Picker("Layout", selection: $model.settings.layout) {
                    Image(systemName: "square.grid.2x2").tag(CardLayout.grid)
                    Image(systemName: "list.bullet").tag(CardLayout.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
                .help("Layout")
                Button { Task { await model.refreshServices() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            if model.context.brewBin != nil { actionBar }
            Divider()
            content
        }
        .sheet(isPresented: $addOpen) { AddServiceSheet() }
    }

    private var running: [ReconciledService] {
        model.reconciled.filter { $0.status == .running || $0.status == .starting }
    }

    private var startable: [ReconciledService] {
        model.reconciled.filter { $0.status == .stopped || $0.status == .error }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Spacer()
            if !running.isEmpty {
                Button(role: .destructive) { model.bulkStop(running) } label: {
                    Label("Stop all", systemImage: "stop.fill")
                }
            } else if !startable.isEmpty {
                Button { model.bulkStart(startable) } label: { Label("Start all", systemImage: "play.fill") }
            }
            Button { addOpen = true } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.context.brewBin == nil {
            EmptyState(symbol: "shippingbox", title: "Homebrew not detected",
                       message: "Install Homebrew from brew.sh, then reopen \(AppInfo.name).")
        } else if !model.servicesLoaded && model.servicesError == nil {
            ScrollView { grid(skeleton: true) }
        } else if let error = model.servicesError, model.reconciled.isEmpty {
            ErrorPanel(error: error, retry: { Task { await model.refreshServices() } }, trustTap: model.trustTap)
                .padding(24)
            Spacer()
        } else if filtered.isEmpty {
            EmptyState(symbol: "square.grid.2x2", title: "No services",
                       message: query.isEmpty ? "Add a service to get started." : "Nothing matches your search.")
        } else {
            ScrollView {
                if model.settings.layout == .grid {
                    grid(skeleton: false)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { ServiceRow(service: $0) }
                    }
                    .padding(24)
                }
            }
        }
    }

    private func grid(skeleton: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
            if skeleton {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)).frame(height: 168)
                }
            } else {
                ForEach(filtered) { s in
                    ServiceCard(service: s)
                        .opacity(dragging == s.formula ? 0.4 : 1)
                        .onDrag {
                            dragging = s.formula
                            return NSItemProvider(object: s.formula as NSString)
                        }
                        .onDrop(of: [.text], delegate: ReorderDrop(target: s.formula, dragging: $dragging, model: model))
                }
            }
        }
        .padding(24)
    }
}

/// Drag-to-reorder cards; the order persists as `settings.cardOrder`.
struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target else { return }
        MainActor.assumeIsolated {
            var order = model.reconciled.map(\.formula)
            guard let i = order.firstIndex(of: from), let j = order.firstIndex(of: target) else { return }
            order.move(fromOffsets: IndexSet(integer: i), toOffset: j > i ? j + 1 : j)
            withAnimation(.snappy) { model.settings.cardOrder = order }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
