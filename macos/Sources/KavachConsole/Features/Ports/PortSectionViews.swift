import AppKit
import KavachCore
import SwiftUI

struct BranchChip: View {
    let branch: String

    var body: some View {
        Label(branch, systemImage: "arrow.triangle.branch")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .foregroundStyle(.secondary)
            .help("Current git branch")
            .accessibilityLabel("Branch \(branch)")
    }
}

