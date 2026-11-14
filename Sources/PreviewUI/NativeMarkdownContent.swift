import AppKit
import PreviewCore

@MainActor enum NativeMarkdownContent {
    static func render(_ document: PreviewMarkdownDocument) throws -> NSAttributedString {
        var html = document.html(includeOutline: false)
        let tags = try NSRegularExpression(pattern: #"<img src="data:image/[^;\"]+;base64,([A-Za-z0-9+/=]+)"[^>]*>"#)
        let original = html as NSString
        var images: [(String, NSTextAttachment)] = []
        // The HTML is our renderer's output. Replace embedded images before the
        // HTML importer sees them, so it never needs a resource-loading service.
        for match in tags.matches(in: html, range: NSRange(location: 0, length: original.length)).reversed() {
            let encoded = original.substring(with: match.range(at: 1))
            guard encoded.utf8.count <= 12 * 1024 * 1024, let data = Data(base64Encoded: encoded),
                  data.count <= 8 * 1024 * 1024, let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { continue }
            let token = "THERMOIMAGE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let attachment = NSTextAttachment(fileWrapper: nil)
            let scale = min(1, 720 / image.size.width)
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            images.append((token, attachment))
            guard let range = Range(match.range, in: html) else { continue }
            html.replaceSubrange(range, with: token)
        }
        let value = try NSMutableAttributedString(data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        for (token, attachment) in images {
            let range = (value.string as NSString).range(of: token)
            if range.location != NSNotFound { value.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment)) }
        }
        value.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: value.length))
        return value
    }
}
