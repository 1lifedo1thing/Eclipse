#if os(macOS)
import AppKit
import SwiftUI

struct MacSubtitleOverlay: NSViewRepresentable {
    let text: String
    let appearance: PlayerSubtitleAppearance

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityRole(.staticText)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let value = NSMutableAttributedString(attributedString: appearance.attributedText(text))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        field.attributedStringValue = value
        field.setAccessibilityLabel(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 720)
        let size = nsView.attributedStringValue.boundingRect(with: CGSize(width: max(1, width - 8), height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(size.height) + 6)
    }
}
#endif
