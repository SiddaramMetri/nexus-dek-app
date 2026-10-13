import NexusCore
import SwiftUI

struct DockerImageRow: View {
    @Environment(AppModel.self) private var model
    @Bindable var d: DockerModel
    let image: DockerImage

    var body: some View {
        HStack(spacing: 10) {
            DockerSelectBox(mark: d.imageSel.contains(image.id) ? .all : .none, enabled: image.removable) {
                d.toggle(image: image)
            }
            Image(systemName: image.inUse ? "lock.fill" : "square.stack.3d.up")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.reference).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Text("\(image.imageID) · created \(created)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            DockerChip(style: image.inUse ? .inUse : image.isDangling ? .dangling : .unused)
            VStack(alignment: .trailing, spacing: 1) {
                DockerSizeText(bytes: image.bytes, measuring: false)
                if let unique = image.uniqueBytes, let total = image.bytes, unique < total {
                    Text("\(Format.bytes(unique)) unique").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Layers shared with other images stay when this one is removed")
                }
            }
            .frame(width: 96, alignment: .trailing)
            DockerRowTrash(locked: !image.removable, busy: d.busy,
                           help: image.inUse ? "A container uses this image — remove the container first" : "Remove image") {
                d.remove(images: [image], model: model)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { d.toggle(image: image) }
    }

    private var created: String {
        image.created.map { Format.relative($0) } ?? (image.createdSince.isEmpty ? "—" : image.createdSince)
    }
}

struct DockerContainerRow: View {
    @Environment(AppModel.self) private var model
    @Bindable var d: DockerModel
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 10) {
            DockerSelectBox(mark: d.containerSel.contains(container.id) ? .all : .none, enabled: container.removable) {
                d.toggle(container: container)
            }
            Image(systemName: container.isRunning ? "lock.fill" : "shippingbox")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Text("\(container.image) · \(container.status)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            DockerChip(style: container.isRunning ? .running(container.state) : .stopped)
            DockerSizeText(bytes: container.bytes, measuring: d.measuring)
                .frame(width: 96, alignment: .trailing)
                .help("Files written inside the container (its writable layer)")
            DockerRowTrash(locked: !container.removable, busy: d.busy,
                           help: container.isRunning ? "Running — stop it first" : "Remove container") {
                d.remove(containers: [container], model: model)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { d.toggle(container: container) }
    }
}

struct DockerVolumeRow: View {
    @Environment(AppModel.self) private var model
    @Bindable var d: DockerModel
    let volume: DockerVolume

    var body: some View {
        HStack(spacing: 10) {
            DockerSelectBox(mark: d.volumeSel.contains(volume.name) ? .all : .none, enabled: volume.removable) {
                d.toggle(volume: volume)
            }
            Image(systemName: volume.removable ? "externaldrive" : "lock.fill")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.isAnonymous ? String(volume.name.prefix(12)) + "…" : volume.name)
                    .font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                    .help(volume.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            DockerChip(style: volume.removable ? .unused : .inUse)
            DockerSizeText(bytes: volume.bytes, measuring: d.measuring)
                .frame(width: 96, alignment: .trailing)
            DockerRowTrash(locked: !volume.removable, busy: d.busy,
                           help: volume.removable ? "Delete volume permanently" : "A container uses this volume") {
                d.remove(volumes: [volume], model: model)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { d.toggle(volume: volume) }
    }

    private var detail: String {
        var parts: [String] = [volume.isAnonymous ? "Anonymous volume" : "Named volume"]
        if let project = volume.composeProject { parts.append("compose project \(project)") }
        if volume.driver != "local" { parts.append(volume.driver) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Small pieces

/// Round macOS-style selection checkbox with a mixed state.
struct DockerSelectBox: View {
    let mark: DockerModel.Mark
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: mark == .all ? "checkmark.circle.fill" : mark == .some ? "minus.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(mark == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(mark == .all ? "Selected" : mark == .some ? "Partly selected" : "Not selected")
    }
}

/// Per-row remove, or a lock when the row can't go.
private struct DockerRowTrash: View {
    let locked: Bool
    let busy: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help(help)
            .disabled(locked || busy)
    }
}

private struct DockerSizeText: View {
    let bytes: UInt64?
    /// `system df -v` is still running — a size may yet arrive.
    let measuring: Bool

    var body: some View {
        if let bytes {
            Text(Format.bytes(bytes)).monospacedDigit()
        } else if measuring {
            ProgressView().controlSize(.mini)
        } else {
            Text("—").foregroundStyle(.secondary).help("Docker didn't report a size")
        }
    }
}

/// Status = label + tint, never color alone. Unused isn't alarming: no red.
private struct DockerChip: View {
    enum Style { case inUse, unused, dangling, running(String), stopped }
    let style: Style

    var body: some View {
        let (text, color, help) = look
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .help(help)
            .frame(width: 76)
    }

    private var look: (String, Color, String) {
        switch style {
        case .inUse: ("In use", .secondary, "Used by a container — locked")
        case .unused: ("Unused", .orange, "No container uses it")
        case .dangling: ("Dangling", .orange, "Untagged and unused — what “Remove dangling images” clears")
        case let .running(state): (state.prefix(1).uppercased() + state.dropFirst(), .green, "Locked while it runs")
        case .stopped: ("Stopped", .secondary, "Can be removed")
        }
    }
}
