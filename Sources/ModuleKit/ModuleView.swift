import Foundation

/// A page or menu bar item described by a sandboxed module as data (#47). The kernel validates it
/// and draws it with its own native controls, so a module never ships UI code and cannot draw outside
/// these shapes: lists, details, forms and cards on a page, and one menu bar item.
///
/// Text is shown as plain text: no Markdown, links or HTML are interpreted. Identifiers and SF Symbol
/// names are restricted to short lowercase words, and every collection and string has a cap, so a
/// module can't make the kernel lay out unbounded content. A document that breaks any rule is refused
/// as a whole rather than partly shown.
public struct ModuleView: Codable, Sendable, Equatable {
    public static let version = 1

    public enum Limits {
        public static let documentBytes = 64 * 1024
        public static let sections = 20
        public static let rows = 200
        public static let fields = 50
        public static let actions = 4
        public static let options = 50
        public static let title = 120
        public static let text = 500
    }

    public struct Action: Codable, Sendable, Equatable {
        /// Sent back to the module's `thermo_action` export.
        public var action: String
        public var title: String
        public init(action: String, title: String) { self.action = action; self.title = title }
    }

    public struct Row: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var value: String?
        public var symbol: String?
        public var action: String?
        public init(id: String, title: String, subtitle: String? = nil, value: String? = nil, symbol: String? = nil, action: String? = nil) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.value = value; self.symbol = symbol; self.action = action
        }
    }

    public struct DetailField: Codable, Sendable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public struct Option: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public enum Value: Codable, Sendable, Equatable {
        case text(String), number(Double), toggle(Bool)
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .toggle(b) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else { self = .text(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .number(let d): try c.encode(d)
            case .toggle(let b): try c.encode(b)
            }
        }
    }

    public struct FormField: Codable, Sendable, Equatable {
        public enum Input: String, Codable, Sendable { case text, number, toggle, choice }
        public var id: String
        public var label: String
        public var input: Input
        public var value: Value?
        public var placeholder: String?
        public var options: [Option]?
        public init(id: String, label: String, input: Input, value: Value? = nil, placeholder: String? = nil, options: [Option]? = nil) {
            self.id = id; self.label = label; self.input = input; self.value = value; self.placeholder = placeholder; self.options = options
        }
    }

    public enum Section: Codable, Sendable, Equatable {
        case list(id: String, title: String?, rows: [Row])
        case detail(title: String?, fields: [DetailField])
        case form(id: String, title: String?, fields: [FormField], submit: Action)
        case card(title: String, value: String?, caption: String?, symbol: String?, actions: [Action])

        enum Key: String, CodingKey { case type, id, title, rows, fields, submit, value, caption, symbol, actions }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .type) {
            case "list": self = .list(id: try c.decode(String.self, forKey: .id), title: try c.decodeIfPresent(String.self, forKey: .title),
                                      rows: try c.decode([Row].self, forKey: .rows))
            case "detail": self = .detail(title: try c.decodeIfPresent(String.self, forKey: .title), fields: try c.decode([DetailField].self, forKey: .fields))
            case "form": self = .form(id: try c.decode(String.self, forKey: .id), title: try c.decodeIfPresent(String.self, forKey: .title),
                                      fields: try c.decode([FormField].self, forKey: .fields), submit: try c.decode(Action.self, forKey: .submit))
            case "card": self = .card(title: try c.decode(String.self, forKey: .title), value: try c.decodeIfPresent(String.self, forKey: .value),
                                      caption: try c.decodeIfPresent(String.self, forKey: .caption), symbol: try c.decodeIfPresent(String.self, forKey: .symbol),
                                      actions: try c.decodeIfPresent([Action].self, forKey: .actions) ?? [])
            case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown section type \(other)")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self {
            case let .list(id, title, rows): try c.encode("list", forKey: .type); try c.encode(id, forKey: .id); try c.encodeIfPresent(title, forKey: .title); try c.encode(rows, forKey: .rows)
            case let .detail(title, fields): try c.encode("detail", forKey: .type); try c.encodeIfPresent(title, forKey: .title); try c.encode(fields, forKey: .fields)
            case let .form(id, title, fields, submit):
                try c.encode("form", forKey: .type); try c.encode(id, forKey: .id); try c.encodeIfPresent(title, forKey: .title)
                try c.encode(fields, forKey: .fields); try c.encode(submit, forKey: .submit)
            case let .card(title, value, caption, symbol, actions):
                try c.encode("card", forKey: .type); try c.encode(title, forKey: .title); try c.encodeIfPresent(value, forKey: .value)
                try c.encodeIfPresent(caption, forKey: .caption); try c.encodeIfPresent(symbol, forKey: .symbol); try c.encode(actions, forKey: .actions)
            }
        }
    }

    public struct MenuBarItem: Codable, Sendable, Equatable {
        public var title: String
        public var value: String?
        public var symbol: String?
        public var action: String?
        public init(title: String, value: String? = nil, symbol: String? = nil, action: String? = nil) {
            self.title = title; self.value = value; self.symbol = symbol; self.action = action
        }
    }

    public var version: Int
    public var title: String?
    public var subtitle: String?
    public var sections: [Section]?
    public var menuBarItem: MenuBarItem?

    public init(title: String? = nil, subtitle: String? = nil, sections: [Section]? = nil, menuBarItem: MenuBarItem? = nil) {
        version = Self.version; self.title = title; self.subtitle = subtitle; self.sections = sections; self.menuBarItem = menuBarItem
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// Decodes and checks a document the module produced. Never returns a partly valid view.
    public static func read(_ data: Data) throws -> ModuleView {
        guard data.count <= Limits.documentBytes else { throw Invalid("view is \(data.count) bytes, over \(Limits.documentBytes)") }
        let view: ModuleView
        do { view = try JSONDecoder().decode(ModuleView.self, from: data) }
        catch { throw Invalid("view is not valid: \(error)") }
        try view.validate()
        return view
    }

    public func validate() throws {
        guard version == Self.version else { throw Invalid("view version \(version) is not supported") }
        guard (sections == nil) != (menuBarItem == nil) else { throw Invalid("a view is either a page (sections) or a menu bar item") }
        try Self.text(title, Limits.title, "title"); try Self.text(subtitle, Limits.text, "subtitle")
        if let item = menuBarItem {
            try Self.text(item.title, Limits.title, "menu bar title"); try Self.text(item.value, Limits.title, "menu bar value")
            try Self.symbol(item.symbol); try Self.identifier(item.action, "menu bar action")
        }
        guard let sections else { return }
        guard sections.count <= Limits.sections else { throw Invalid("\(sections.count) sections, over \(Limits.sections)") }
        var ids = Set<String>()
        for section in sections {
            switch section {
            case let .list(id, title, rows):
                try Self.identifier(id, "list"); guard ids.insert(id).inserted else { throw Invalid("section id \(id) repeats") }
                try Self.text(title, Limits.title, "list title")
                guard rows.count <= Limits.rows else { throw Invalid("\(rows.count) rows, over \(Limits.rows)") }
                var rowIDs = Set<String>()
                for row in rows {
                    try Self.identifier(row.id, "row"); guard rowIDs.insert(row.id).inserted else { throw Invalid("row id \(row.id) repeats") }
                    try Self.text(row.title, Limits.title, "row title"); try Self.text(row.subtitle, Limits.text, "row subtitle")
                    try Self.text(row.value, Limits.title, "row value"); try Self.symbol(row.symbol); try Self.identifier(row.action, "row action")
                }
            case let .detail(title, fields):
                try Self.text(title, Limits.title, "detail title")
                guard fields.count <= Limits.fields else { throw Invalid("\(fields.count) detail fields, over \(Limits.fields)") }
                for field in fields { try Self.text(field.label, Limits.title, "detail label"); try Self.text(field.value, Limits.text, "detail value") }
            case let .form(id, title, fields, submit):
                try Self.identifier(id, "form"); guard ids.insert(id).inserted else { throw Invalid("section id \(id) repeats") }
                try Self.text(title, Limits.title, "form title"); try Self.action(submit)
                guard !fields.isEmpty, fields.count <= Limits.fields else { throw Invalid("a form needs 1…\(Limits.fields) fields") }
                var fieldIDs = Set<String>()
                for field in fields {
                    try Self.identifier(field.id, "field"); guard fieldIDs.insert(field.id).inserted else { throw Invalid("field id \(field.id) repeats") }
                    try Self.text(field.label, Limits.title, "field label"); try Self.text(field.placeholder, Limits.title, "placeholder")
                    switch (field.input, field.value) {
                    case (_, nil), (.text, .text?), (.number, .number?), (.toggle, .toggle?), (.choice, .text?): break
                    default: throw Invalid("field \(field.id) value does not match its input")
                    }
                    if case .text(let s)? = field.value { try Self.text(s, Limits.text, "field value") }
                    if case .number(let d)? = field.value, !d.isFinite { throw Invalid("field \(field.id) value is not finite") }
                    if field.input == .choice {
                        guard let options = field.options, !options.isEmpty, options.count <= Limits.options else { throw Invalid("choice \(field.id) needs 1…\(Limits.options) options") }
                        for option in options { try Self.identifier(option.id, "option"); try Self.text(option.title, Limits.title, "option title") }
                        if case .text(let s)? = field.value, !options.contains(where: { $0.id == s }) { throw Invalid("choice \(field.id) value is not an option") }
                    } else if field.options != nil { throw Invalid("only choices have options") }
                }
            case let .card(title, value, caption, symbol, actions):
                try Self.text(title, Limits.title, "card title"); try Self.text(value, Limits.title, "card value")
                try Self.text(caption, Limits.text, "card caption"); try Self.symbol(symbol)
                guard actions.count <= Limits.actions else { throw Invalid("\(actions.count) card actions, over \(Limits.actions)") }
                for action in actions { try Self.action(action) }
            }
        }
    }

    static func action(_ action: Action) throws {
        try identifier(action.action, "action"); try text(action.title, Limits.title, "action title")
        guard !action.title.isEmpty else { throw Invalid("action \(action.action) has no title") }
    }

    /// Short lowercase words: `refresh`, `row.42`, `apply-all`.
    public static func identifier(_ value: String?, _ what: String) throws {
        guard let value else { return }
        let allowed = value.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2e || $0 == 0x2d || $0 == 0x5f }
        guard (1...64).contains(value.utf8.count), allowed else { throw Invalid("\(what) id \"\(value.prefix(32))\" is not a short lowercase identifier") }
    }

    /// SF Symbol names look like `chart.bar.fill`; whether the symbol exists is checked when drawing.
    static func symbol(_ value: String?) throws {
        guard let value else { return }
        let allowed = value.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2e }
        guard (1...64).contains(value.utf8.count), allowed else { throw Invalid("symbol \"\(value.prefix(32))\" is not an SF Symbol name") }
    }

    static func text(_ value: String?, _ limit: Int, _ what: String) throws {
        guard let value else { return }
        guard value.count <= limit else { throw Invalid("\(what) is \(value.count) characters, over \(limit)") }
        // Control and bidi-override characters could disguise what a module shows.
        let refused = value.unicodeScalars.contains { s in
            (s.value < 0x20 && s != "\n" && s != "\t") || s.value == 0x7f || (0x202a...0x202e).contains(s.value) || (0x2066...0x2069).contains(s.value)
        }
        guard !refused else { throw Invalid("\(what) contains control characters") }
    }
}

/// What the kernel sends to a module's `thermo_render` and `thermo_action` exports.
public struct ModuleViewRequest: Codable, Sendable, Equatable {
    public var scene: String
    /// The app's language (`en`, `zh-Hans`), so the module can word its own texts.
    public var language: String
    public var action: String?
    public var values: [String: ModuleView.Value]?
    public init(scene: String, language: String, action: String? = nil, values: [String: ModuleView.Value]? = nil) {
        self.scene = scene; self.language = language; self.action = action; self.values = values
    }
}
