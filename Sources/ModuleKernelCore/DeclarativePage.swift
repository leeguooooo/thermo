import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n
import ThermoUI
import WasmHost

/// Keeps one declarative scene (#47): the module's last valid view, form input, and the action in flight.
@MainActor package final class DeclarativeSceneModel: ObservableObject {
    package let module: DeclarativeModule
    package let scene: String
    private let language: () -> String
    @Published package private(set) var view: ModuleView?
    @Published package private(set) var problem: String?
    @Published package private(set) var busy = false
    /// Form input by form id, then field id. Starts from the values the module sent.
    @Published package var values: [String: [String: ModuleView.Value]] = [:]

    package init(module: DeclarativeModule, scene: String, language: @escaping () -> String = { L10n.current.rawValue }) {
        self.module = module; self.scene = scene; self.language = language
    }

    package func load() async {
        await run { [module, scene, language] in try await module.render(scene: scene, language: language()) }
    }

    package func perform(_ action: String, form: String? = nil) async {
        let input = form.flatMap { values[$0] } ?? [:]
        await run { [module, scene, language] in try await module.perform(action, values: input, scene: scene, language: language()) }
    }

    private func run(_ work: @escaping @Sendable () async throws -> ModuleView) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let next = try await work()
            view = next; problem = nil
            values = Self.initialValues(next)
        } catch {
            // Keep showing the last good view; say what went wrong beside it.
            problem = (error as? DeclarativeModule.Failure)?.description ?? "\(error)"
        }
    }

    static func initialValues(_ view: ModuleView) -> [String: [String: ModuleView.Value]] {
        var result: [String: [String: ModuleView.Value]] = [:]
        for case let .form(id, _, fields, _) in view.sections ?? [] {
            var form: [String: ModuleView.Value] = [:]
            for field in fields {
                switch field.input {
                case .text: form[field.id] = field.value ?? .text("")
                case .number: form[field.id] = field.value ?? .number(0)
                case .toggle: form[field.id] = field.value ?? .toggle(false)
                case .choice: form[field.id] = field.value ?? field.options?.first.map { .text($0.id) }
                }
            }
            result[id] = form
        }
        return result
    }
}

/// Module text is shown verbatim: never parsed as Markdown, so it can't turn into links.
private func plain(_ s: String) -> Text { Text(verbatim: s) }

private func symbolImage(_ name: String?) -> Image? {
    guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
    return Image(systemName: name)
}

/// A module page drawn with the same page frame, type and controls as the built-in pages.
package struct DeclarativePageView: View {
    @ObservedObject var model: DeclarativeSceneModel
    let fallbackTitle: String
    package init(model: DeclarativeSceneModel, fallbackTitle: String) { self.model = model; self.fallbackTitle = fallbackTitle }

    package var body: some View {
        WindowPage(title: model.view?.title ?? fallbackTitle, subtitle: model.view?.subtitle) {
            if let problem = model.problem {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.caution)
                    plain(problem).font(Theme.secondary).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    Spacer()
                    Button(tr("Try again")) { Task { await model.load() } }.buttonStyle(PillButtonStyle()).controlSize(.small)
                }.accessibilityIdentifier("declarative-problem")
            }
            if let sections = model.view?.sections {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    DeclarativeSectionView(model: model, section: section, primaryForm: index == firstFormIndex(sections))
                }
            } else if model.problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: model.scene) { await model.load() }
        .disabled(model.busy && model.view != nil)
    }

    private func firstFormIndex(_ sections: [ModuleView.Section]) -> Int? {
        sections.firstIndex { if case .form = $0 { return true } else { return false } }
    }
}

struct DeclarativeSectionView: View {
    @ObservedObject var model: DeclarativeSceneModel
    let section: ModuleView.Section
    /// Only one form per page takes Return as its default button.
    let primaryForm: Bool

    var body: some View {
        switch section {
        case let .list(_, title, rows):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let title { SectionHeader(title: title) { EmptyView() } }
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { InspectorDivider(inset: row.symbol == nil ? Theme.Space.m : 46) }
                        rowView(row)
                    }
                    if rows.isEmpty { Text(tr("Nothing to show.")).font(Theme.secondary).foregroundStyle(Theme.textTertiary).padding(Theme.Space.m) }
                }.glass(radius: Theme.radius)
            }
        case let .detail(title, fields):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let title { SectionHeader(title: title) { EmptyView() } }
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { InspectorDivider(inset: Theme.Space.m) }
                        HStack(alignment: .firstTextBaseline) {
                            plain(field.label).font(Theme.body).foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: Theme.Space.l)
                            plain(field.value).font(Theme.body).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
                            .accessibilityElement(children: .combine)
                    }
                }.glass(radius: Theme.radius)
            }
        case let .form(id, title, fields, submit):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let title { SectionHeader(title: title) { EmptyView() } }
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(fields, id: \.id) { field in fieldView(form: id, field: field, submit: submit) }
                    HStack {
                        Spacer()
                        let button = Button(submit.title) { Task { await model.perform(submit.action, form: id) } }
                            .buttonStyle(PillButtonStyle(prominent: true)).disabled(model.busy)
                            .accessibilityIdentifier("declarative-submit-" + id)
                        if primaryForm { button.keyboardShortcut(.defaultAction) } else { button }
                    }
                }.padding(Theme.Space.m).glass(radius: Theme.radius)
            }
        case let .card(title, value, caption, symbol, actions):
            HStack(alignment: .top, spacing: Theme.Space.m) {
                if let image = symbolImage(symbol) { image.font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 28) }
                VStack(alignment: .leading, spacing: 4) {
                    plain(title).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    if let value { plain(value).font(.system(size: 22, weight: .semibold)).monospacedDigit() }
                    if let caption { plain(caption).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                }
                Spacer()
                if !actions.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(actions, id: \.action) { action in
                            Button(action.title) { Task { await model.perform(action.action) } }
                                .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy)
                        }
                    }
                }
            }.padding(Theme.Space.m).glass(radius: Theme.radius)
                .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func rowView(_ row: ModuleView.Row) -> some View {
        let content = HStack(spacing: Theme.Space.m) {
            if let image = symbolImage(row.symbol) { image.frame(width: 22).foregroundStyle(Theme.textSecondary) }
            VStack(alignment: .leading, spacing: 2) {
                plain(row.title).font(Theme.body)
                if let subtitle = row.subtitle { plain(subtitle).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
            }
            Spacer()
            if let value = row.value { plain(value).font(Theme.body).foregroundStyle(Theme.textSecondary).monospacedDigit() }
            if row.action != nil { Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8).contentShape(Rectangle())
        if let action = row.action {
            Button { Task { await model.perform(action) } } label: { content }
                .buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("declarative-row-" + row.id)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func fieldView(form: String, field: ModuleView.FormField, submit: ModuleView.Action) -> some View {
        let binding = Binding<ModuleView.Value?>(get: { model.values[form]?[field.id] }, set: { model.values[form, default: [:]][field.id] = $0 })
        switch field.input {
        case .text:
            LabeledContent {
                TextField(field.placeholder ?? "", text: Binding(get: { if case .text(let s)? = binding.wrappedValue { s } else { "" } },
                                                                  set: { binding.wrappedValue = .text(String($0.prefix(ModuleView.Limits.text))) }))
                    .textFieldStyle(.roundedBorder).onSubmit { Task { await model.perform(submit.action, form: form) } }
            } label: { plain(field.label).font(Theme.body) }
        case .number:
            LabeledContent {
                TextField(field.placeholder ?? "", value: Binding(get: { if case .number(let d)? = binding.wrappedValue { d } else { 0 } },
                                                                   set: { binding.wrappedValue = .number($0.isFinite ? $0 : 0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160).onSubmit { Task { await model.perform(submit.action, form: form) } }
            } label: { plain(field.label).font(Theme.body) }
        case .toggle:
            Toggle(isOn: Binding(get: { if case .toggle(let b)? = binding.wrappedValue { b } else { false } }, set: { binding.wrappedValue = .toggle($0) })) {
                plain(field.label).font(Theme.body)
            }.toggleStyle(.switch)
        case .choice:
            Picker(selection: Binding(get: { if case .text(let s)? = binding.wrappedValue { s } else { "" } }, set: { binding.wrappedValue = .text($0) })) {
                ForEach(field.options ?? [], id: \.id) { option in plain(option.title).tag(option.id) }
            } label: { plain(field.label).font(Theme.body) }
        }
    }
}

/// One line in the menu bar panel for a module's menu bar entry.
package struct DeclarativeMenuBarItemView: View {
    @ObservedObject var model: DeclarativeSceneModel
    let fallbackTitle: String
    let open: () -> Void
    package init(model: DeclarativeSceneModel, fallbackTitle: String, open: @escaping () -> Void) {
        self.model = model; self.fallbackTitle = fallbackTitle; self.open = open
    }
    package var body: some View {
        let item = model.view?.menuBarItem
        Button {
            if let action = item?.action { Task { await model.perform(action) } } else { open() }
        } label: {
            HStack(spacing: Theme.Space.s) {
                (symbolImage(item?.symbol) ?? Image(systemName: "puzzlepiece.extension")).frame(width: 18).foregroundStyle(Theme.textSecondary)
                plain(item?.title ?? fallbackTitle).font(Theme.body).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                if let value = item?.value { plain(value).font(Theme.body).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1) }
                if model.problem != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.caution).help(model.problem ?? "") }
            }.padding(.horizontal, Theme.Space.s).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(model.busy)
        .task(id: model.scene) { await model.load() }
    }
}
