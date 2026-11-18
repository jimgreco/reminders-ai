import SwiftUI
import UIKit

/// Text the reader can select part of: press and hold, then drag the handles.
/// SwiftUI's own `textSelection` only offers the whole text on iPhone.
struct SelectableText: UIViewRepresentable {
    let markdown: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let text = Self.attributed(markdown)
        if view.attributedText != text { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.window?.windowScene?.screen.bounds.width ?? 320
        guard width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    /// Bold, italics, code and links from the assistant's Markdown; line breaks kept.
    static func attributed(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        let body = UIFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            var font = body
            if intent.contains(.code) {
                font = UIFontMetrics(forTextStyle: .body)
                    .scaledFont(for: .monospacedSystemFont(ofSize: body.pointSize * 0.92, weight: .regular))
            } else if !traits.isEmpty, let descriptor = body.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: 0)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
