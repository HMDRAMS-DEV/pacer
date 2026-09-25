import AppKit
import SwiftUI

/// Sizes a window to its content with the top edge fixed.
///
/// Use with `View.fitsWindow(_:)` and `.windowResizability(.contentMinSize)`.
///
/// SwiftUI resizes a content-sized window around its bottom-left corner on every animation frame,
/// so moving it back afterwards flashes the window background along the top. Here the size and
/// origin change together in one call instead. Growth applies at once; shrinking waits for the
/// collapse animation, so the cards aren't clipped while they close.
@MainActor
final class WindowFit {
    weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            window.styleMask.remove(.resizable)
            window.backgroundColor = NSColor(Theme.canvas)
            apply(height)
        }
    }

    var height: CGFloat = 0 {
        didSet {
            guard height != oldValue else { return }
            pending?.cancel()
            if height > oldValue {
                apply(height)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self.map { $0.apply($0.height) } }
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
    }

    private var pending: DispatchWorkItem?

    private func apply(_ height: CGFloat) {
        guard let window, height > 0 else { return }
        // SwiftUI lays the view out inside the content layout rect, which leaves out the title bar
        // even when the title bar is hidden and the content view fills the whole window.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let total = height + chrome
        guard abs(total - window.frame.height) > 0.5 else { return }
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - total, width: window.frame.width, height: total)
        window.setFrame(frame, display: true)
    }
}

/// Hands the hosting window to a closure once the view is in one.
struct WindowAccessor: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { found(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Sizes the hosting window to this view's height, keeping the window's top edge in place.
    /// The view should have a fixed width and its ideal height.
    func fitsWindow(_ fit: WindowFit) -> some View {
        onGeometryChange(for: CGFloat.self, of: \.size.height) { fit.height = $0 }
            // The window never sizes itself to the content; WindowFit does, top edge fixed.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(WindowAccessor { fit.window = $0 })
    }
}
