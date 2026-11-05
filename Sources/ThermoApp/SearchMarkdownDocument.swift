import Foundation
@_implementationOnly import Markdown

struct SearchMarkdownDocument: Sendable {
    struct Heading: Sendable { let level: Int; let title: String; let anchor: String }
    let source: String
    let body: String
    let headings: [Heading]

    static func supports(_ url: URL) -> Bool { ["md", "markdown", "mdown", "mkd", "mdx"].contains(url.pathExtension.lowercased()) }

    static func load(_ url: URL) throws -> SearchMarkdownDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024 else { throw PreviewError.tooLarge }
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw PreviewError.encoding }
        return render(source, baseURL: url.deletingLastPathComponent())
    }

    static func render(_ source: String, baseURL: URL? = nil) -> SearchMarkdownDocument {
        var renderer = Renderer(baseURL: baseURL.map { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL })
        let body = renderer.visit(Document(parsing: source))
        return .init(source: source, body: body, headings: renderer.headings)
    }

    func html(showSource: Bool = false) -> String {
        let outline = headings.count < 3 || showSource ? "" : "<nav aria-label=\"Contents\">" + headings.map {
            "<a class=\"depth-\($0.level)\" href=\"#\($0.anchor)\">\(Self.escape($0.title))</a>"
        }.joined() + "</nav>"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>\(Self.style)</style></head><body><main class="\(outline.isEmpty ? "single" : "with-outline")">\(outline)<article>\(showSource ? "<pre class=\"source\"><code>" + Self.escape(source) + "</code></pre>" : body)</article></main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    enum PreviewError: LocalizedError {
        case tooLarge, encoding
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This document is too large to preview. Open it in its default app."
            case .encoding: return "This document's text encoding is not supported. Open it in its default app."
            }
        }
    }

    private struct Renderer: MarkupVisitor {
        typealias Result = String
        var headings: [Heading] = []
        var slugs: [String: Int] = [:]
        var images: [URL: String] = [:]
        var imageBytes = 0
        var baseURL: URL?
        mutating func defaultVisit(_ markup: Markup) -> String { markup.children.map { visit($0) }.joined() }
        mutating func wrapped(_ node: Markup, _ tag: String) -> String { "<\(tag)>" + defaultVisit(node) + "</\(tag)>" }
        mutating func visitText(_ text: Markdown.Text) -> String { SearchMarkdownDocument.escape(text.string) }
        mutating func visitParagraph(_ paragraph: Paragraph) -> String { wrapped(paragraph, "p") }
        mutating func visitHeading(_ heading: Markdown.Heading) -> String {
            let slug = heading.plainText.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-" || $0 == "_"
            }.map(String.init).joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
            let base = slug.isEmpty ? "section" : slug
            let count = slugs[base, default: 0]; slugs[base] = count + 1
            let anchor = count == 0 ? base : base + "-" + String(count)
            headings.append(.init(level: heading.level, title: heading.plainText, anchor: anchor))
            return "<h\(heading.level) id=\"\(anchor)\">" + defaultVisit(heading) + "</h\(heading.level)>"
        }
        mutating func visitEmphasis(_ node: Emphasis) -> String { wrapped(node, "em") }
        mutating func visitStrong(_ node: Strong) -> String { wrapped(node, "strong") }
        mutating func visitStrikethrough(_ node: Strikethrough) -> String { wrapped(node, "del") }
        mutating func visitBlockQuote(_ node: BlockQuote) -> String { wrapped(node, "blockquote") }
        mutating func visitUnorderedList(_ node: UnorderedList) -> String { wrapped(node, "ul") }
        mutating func visitOrderedList(_ node: OrderedList) -> String { "<ol start=\"\(node.startIndex)\">" + defaultVisit(node) + "</ol>" }
        mutating func visitListItem(_ node: ListItem) -> String {
            let checkbox = node.checkbox.map { "<input type=\"checkbox\" disabled \($0 == .checked ? "checked" : "")>" } ?? ""
            return (node.checkbox == nil ? "<li>" : "<li class=\"task-item\">") + checkbox + defaultVisit(node) + "</li>"
        }
        mutating func visitThematicBreak(_ node: ThematicBreak) -> String { "<hr>" }
        mutating func visitLineBreak(_ node: LineBreak) -> String { "<br>" }
        mutating func visitSoftBreak(_ node: SoftBreak) -> String { "\n" }
        mutating func visitInlineCode(_ node: InlineCode) -> String { "<code>" + SearchMarkdownDocument.escape(node.code) + "</code>" }
        mutating func visitCodeBlock(_ node: CodeBlock) -> String {
            let language = SearchMarkdownDocument.escape(node.language ?? "")
            return "<section class=\"code-block\"><div class=\"code-language\">\(language)</div><pre><code>" + SearchMarkdownDocument.escape(node.code) + "</code></pre></section>"
        }
        mutating func visitLink(_ node: Markdown.Link) -> String {
            guard let destination = node.destination, Self.allowedLink(destination) else { return defaultVisit(node) }
            let resolved = destination.hasPrefix("#") ? destination : URL(string: destination, relativeTo: baseURL)?.absoluteString ?? destination
            return "<a href=\"\(SearchMarkdownDocument.escape(resolved))\">" + defaultVisit(node) + "</a>"
        }
        mutating func visitImage(_ node: Markdown.Image) -> String {
            let alt = SearchMarkdownDocument.escape(node.plainText)
            guard let source = node.source, let data = imageSource(source) else { return "<span class=\"image-placeholder\">\(alt)</span>" }
            return "<img src=\"\(SearchMarkdownDocument.escape(data))\" alt=\"\(alt)\" loading=\"lazy\">"
        }
        mutating func visitHTMLBlock(_ node: HTMLBlock) -> String { safeHTML(node.rawHTML) }
        mutating func visitInlineHTML(_ node: InlineHTML) -> String { safeHTML(node.rawHTML) }
        mutating func visitTable(_ node: Table) -> String { "<div class=\"table-scroll\">" + wrapped(node, "table") + "</div>" }
        mutating func visitTableHead(_ node: Table.Head) -> String { "<thead><tr>" + node.children.map { "<th>" + defaultVisit($0) + "</th>" }.joined() + "</tr></thead>" }
        mutating func visitTableBody(_ node: Table.Body) -> String { wrapped(node, "tbody") }
        mutating func visitTableRow(_ node: Table.Row) -> String { wrapped(node, "tr") }
        mutating func visitTableCell(_ node: Table.Cell) -> String { wrapped(node, "td") }
        static func allowedLink(_ value: String) -> Bool {
            guard let scheme = URL(string: value)?.scheme?.lowercased() else { return true }
            return ["http", "https", "mailto", "file"].contains(scheme)
        }
        mutating func safeHTML(_ raw: String) -> String {
            let raw = raw.replacingOccurrences(of: #"(?is)<(script|style|iframe|object|embed)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            let pattern = #"(?s)<!--.*?-->|</?([A-Za-z][A-Za-z0-9]*)\b([^>]*)>"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return "" }
            let ns = raw as NSString
            var result = "", cursor = 0
            let tags: Set<String> = ["p", "div", "span", "br", "hr", "strong", "b", "em", "i", "s", "del", "code", "pre", "kbd", "sub", "sup", "ul", "ol", "li", "blockquote", "table", "thead", "tbody", "tr", "th", "td", "details", "summary", "h1", "h2", "h3", "h4", "h5", "h6", "a", "img"]
            func text(_ value: String) -> String {
                SearchMarkdownDocument.escape(value).replacingOccurrences(of: #"&amp;((?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);)"#, with: "&$1", options: .regularExpression)
            }
            for match in expression.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                result += text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                cursor = match.range.location + match.range.length
                guard match.range(at: 1).location != NSNotFound else { continue }
                let name = ns.substring(with: match.range(at: 1)).lowercased()
                guard tags.contains(name) else { continue }
                if ns.substring(with: match.range).hasPrefix("</") { result += "</" + name + ">"; continue }
                let attributes = Self.attributes(ns.substring(with: match.range(at: 2)))
                if name == "img" {
                    let alt = SearchMarkdownDocument.escape(attributes["alt"] ?? "")
                    if let source = attributes["src"], let data = imageSource(source) {
                        result += "<img src=\"" + SearchMarkdownDocument.escape(data) + "\" alt=\"" + alt + "\">"
                    } else { result += "<span class=\"image-placeholder\">" + alt + "</span>" }
                    continue
                }
                result += "<" + name
                if name == "a", let href = attributes["href"], Self.allowedLink(href) {
                    let resolved = href.hasPrefix("#") ? href : URL(string: href, relativeTo: baseURL)?.absoluteString ?? href
                    result += " href=\"" + SearchMarkdownDocument.escape(resolved) + "\""
                }
                if ["left", "center", "right"].contains(attributes["align"] ?? "") { result += " align=\"" + attributes["align"]! + "\"" }
                result += ">"
            }
            result += text(ns.substring(from: cursor))
            return result
        }
        static func attributes(_ value: String) -> [String: String] {
            let pattern = #"([A-Za-z][A-Za-z0-9-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
            let ns = value as NSString
            var attributes: [String: String] = [:]
            for match in expression.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: match.range(at: 1)).lowercased()
                if let group = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) {
                    attributes[key] = ns.substring(with: match.range(at: group))
                }
            }
            return attributes
        }
        mutating func imageSource(_ source: String) -> String? {
            if source.hasPrefix("data:image/png;base64,") || source.hasPrefix("data:image/jpeg;base64,") {
                return source.utf8.count <= 8 * 1024 * 1024 ? source : nil
            }
            guard let url = URL(string: source, relativeTo: baseURL)?.absoluteURL, url.isFileURL else { return nil }
            if let cached = images[url] { return cached }
            guard images.count < 48, imageBytes < 24 * 1024 * 1024 else { return nil }
            let mime: String
            switch url.pathExtension.lowercased() {
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            case "svg": mime = "image/svg+xml"
            default: return nil
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let limit = min(8 * 1024 * 1024, 24 * 1024 * 1024 - imageBytes)
            guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
            imageBytes += data.count
            let result = "data:" + mime + ";base64," + data.base64EncodedString()
            images[url] = result
            return result
        }

    }

    private static let style = """
    :root { color-scheme: light dark; --paper:#fff; --ink:#24292f; --muted:#68717d; --line:#d8dee4; --wash:#f5f7f9; --link:#0969da; }
    @media(prefers-color-scheme:dark) { :root { --paper:#16191f; --ink:#e1e6ed; --muted:#99a3b1; --line:#353b45; --wash:#20252d; --link:#83b8ff; } }
    * { box-sizing:border-box } html { scroll-behavior:smooth; scroll-padding-top:28px } body { margin:0; background:var(--paper); color:var(--ink); font:15px/1.8 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; overflow-wrap:anywhere; }
    main { max-width:1100px; margin:auto; padding:36px 40px 80px } main.single { max-width:860px } main.with-outline { display:grid; grid-template-columns:164px minmax(0,1fr); gap:36px }
    article { min-width:0 } article>:first-child { margin-top:0 } p { margin:0 0 1.15em } h1,h2,h3,h4,h5,h6 { font-weight:650; line-height:1.35; margin:1.65em 0 .65em; scroll-margin-top:28px } h1 { font-size:2em; padding-bottom:.45em; border-bottom:1px solid var(--line) } h2 { font-size:1.5em; border-bottom:1px solid var(--line); padding-bottom:.35em } h3 { font-size:1.2em } h4,h5,h6 { font-size:1em }
    a { color:var(--link); text-decoration:none } a:hover { text-decoration:underline } nav { position:sticky; top:28px; align-self:start; max-height:calc(100vh - 56px); overflow:auto; font-size:12px; line-height:1.5; border-right:1px solid var(--line); padding-right:16px } nav a { display:block; color:var(--muted); padding:5px 0 } nav a:hover { color:var(--link) } nav .depth-2 { padding-left:10px } nav .depth-3,nav .depth-4,nav .depth-5,nav .depth-6 { padding-left:20px }
    code,kbd { font: .88em/1.6 ui-monospace,"SFMono-Regular",Menlo,monospace; background:var(--wash); padding:.18em .35em; border-radius:4px } kbd { border:1px solid var(--line) } .code-block { margin:1.4em 0; border:1px solid var(--line); border-radius:8px; overflow:hidden; background:var(--wash) } .code-language { font:11px/1.5 ui-monospace,Menlo,monospace; padding:7px 16px; color:var(--muted); border-bottom:1px solid var(--line) } .code-language:empty { display:none } pre { overflow:auto; margin:0; padding:16px 20px; line-height:1.65; overflow-wrap:normal; tab-size:4 } pre code { padding:0; background:none; border-radius:0; font-size:13px } pre.source { padding:0; white-space:pre-wrap } pre.raw-html { color:var(--muted); background:var(--wash); font-size:12px; margin:1em 0 }
    blockquote { margin:1.3em 0; padding:4px 20px; color:var(--muted); border-left:3px solid var(--line) } blockquote p:last-child { margin-bottom:0 } ul,ol { padding-left:1.7em } li>p { margin:.25em 0 } li { margin:.25em 0 } li.task-item { list-style:none; position:relative } li.task-item>input { position:absolute; left:-1.55em; top:.45em; margin:0 } li.task-item>p:first-of-type { margin:0 } input[type=checkbox] { margin-right:8px; accent-color:var(--link) } [align=center] { text-align:center } [align=right] { text-align:right } details { margin:1em 0 } summary { cursor:pointer; font-weight:600 } img { max-width:100%; height:auto; border-radius:6px } .image-placeholder { color:var(--muted) } hr { border:0; border-top:1px solid var(--line); margin:28px 0 } .table-scroll { overflow:auto; margin:1.3em 0 } table { border-collapse:collapse; font-size:14px; min-width:55% } th,td { border:1px solid var(--line); padding:8px 14px; text-align:left } th { background:var(--wash); font-weight:600 } tr:nth-child(even) { background:var(--wash) } ::selection { background:#388bfd55 }
    @media(max-width:760px) { main { padding:24px 24px 60px } main.with-outline { display:block } nav { display:none } }
    @media(prefers-reduced-motion:reduce) { html { scroll-behavior:auto } }
    """
}
