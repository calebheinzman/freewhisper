import AppKit
import SwiftUI

/// Accepts the very first click.
///
/// `NSHostingView` declines first mouse, and this app is never the active one
/// while a floating panel is up — that is the whole point of the non-activating
/// panel. So the opening click on a button would be consumed as the click that
/// *would* have activated us, and the user would have to click twice. On a
/// button that exists to be hit once, in a hurry, while looking at another app,
/// that is the difference between an affordance and a decoration.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a nib")
    }
}
