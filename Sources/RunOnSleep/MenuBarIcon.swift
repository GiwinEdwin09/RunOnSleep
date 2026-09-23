import AppKit

/// A small, monochrome version of the app's robot guardian. Template rendering
/// keeps it legible on either menu-bar appearance, including selected menus.
enum MenuBarIcon {
    enum State { case inactive, active, unknown }

    static let inactive = make(.inactive)
    static let active = make(.active)
    static let unknown = make(.unknown)

    private static func make(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.setFillColor(NSColor.black.cgColor)

            func rounded(_ rect: CGRect, _ radius: CGFloat) {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }

            // Rounded helmet and ear pieces echo the generated guardian artwork.
            rounded(CGRect(x: 0, y: 5, width: 3, height: 8), 1.5)
            rounded(CGRect(x: 19, y: 5, width: 3, height: 8), 1.5)
            rounded(CGRect(x: 3, y: 1, width: 16, height: 16), 5)
            context.setBlendMode(.clear)
            rounded(CGRect(x: 5, y: 4, width: 12, height: 9), 3)
            context.setBlendMode(.normal)

            switch state {
            case .active:
                rounded(CGRect(x: 7, y: 6.5, width: 2, height: 4), 1)
                rounded(CGRect(x: 13, y: 6.5, width: 2, height: 4), 1)
            case .inactive:
                rounded(CGRect(x: 6.5, y: 8, width: 3, height: 1), 0.5)
                rounded(CGRect(x: 12.5, y: 8, width: 3, height: 1), 0.5)
            case .unknown:
                let question = NSAttributedString(string: "?", attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.black
                ])
                question.draw(at: NSPoint(x: (22 - question.size().width) / 2, y: 3.5))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
