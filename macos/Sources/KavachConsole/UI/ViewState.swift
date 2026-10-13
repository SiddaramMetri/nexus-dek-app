import SwiftUI

/// Use `@ViewState` instead of `@State` everywhere in this target.
/// The macOS 27 SDK declares `@State` as a macro whose implementation ships
/// only with full Xcode; under the Command Line Tools it fails to expand. The
/// alias names the underlying property wrapper directly — same behavior.
typealias ViewState = SwiftUI.State
