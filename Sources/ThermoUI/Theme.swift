import SwiftUI
import ThermoL10n

// The one look every page shares. Pages use these tokens and primitives instead of their own
// sizes, opacities and controls, so a header, a tab bar or a panel reads the same everywhere.
//
// Principles: a quiet graphite window where the data carries the color (heat green→red, one blue
// for what you can act on); one surface level for panels, hairlines between rows, no shadows;
// figures in rounded monospaced digits; motion only to show that something changed.

package enum Theme {
    // MARK: Color

    /// The window: near-black graphite with a hint of blue.
    package static let canvas = Color(red: 0.075, green: 0.082, blue: 0.098)
    package static let canvasDeep = Color(red: 0.055, green: 0.060, blue: 0.072)
    /// The sidebar sits a step darker than the page.
    package static let sidebar = Color(red: 0.050, green: 0.055, blue: 0.066)
    /// A panel on the canvas.
    package static let surface = Color.white.opacity(0.045)
    /// A hovered or selected row, or a control's track.
    package static let surfaceRaised = Color.white.opacity(0.075)
    package static let surfaceActive = Color.white.opacity(0.12)
    package static let hairline = Color.white.opacity(0.075)
    package static let border = Color.white.opacity(0.10)

    package static let textPrimary = Color.white.opacity(0.94)
    package static let textSecondary = Color.white.opacity(0.62)
    package static let textTertiary = Color.white.opacity(0.40)

    /// What you can act on.
    package static let accent = Color(red: 0.33, green: 0.62, blue: 1.0)
    package static let good = Color(red: 0.32, green: 0.82, blue: 0.52)
    package static let caution = Color(red: 1.0, green: 0.66, blue: 0.26)
    package static let danger = Color(red: 1.0, green: 0.38, blue: 0.36)

    // MARK: Shape and space

    package static let radius: CGFloat = 12
    package static let radiusSmall: CGFloat = 8
    package static let pagePadding: CGFloat = 32
    package static let pageTop: CGFloat = 44
    package static let pageWidth: CGFloat = 960

    /// Every gap is one of these (a 4-point grid): inside a row, between rows, between a header and
    /// its panel, between sections, page edges.
    package enum Space {
        package static let xs: CGFloat = 4
        package static let s: CGFloat = 8
        package static let m: CGFloat = 12
        package static let l: CGFloat = 16
        package static let xl: CGFloat = 24
        package static let xxl: CGFloat = 32
    }

    // MARK: Type

    // Five text sizes, no others: 24 page title, 15 heading (a verdict, a panel's lead line),
    // 13 body and row titles, 12 secondary lines, 11 labels and meta. Figures use the rounded
    // face at 40 (the page's one hero), 24 (a metric), 15 or 13 (in rows).

    package static let pageTitle = Font.system(size: 24, weight: .semibold)
    package static let heading = Font.system(size: 15, weight: .semibold)
    package static let pageSubtitle = Font.system(size: 13)
    package static let rowTitle = Font.system(size: 13, weight: .medium)
    package static let body = Font.system(size: 13)
    package static let secondary = Font.system(size: 12)
    package static let sectionTitle = Font.system(size: 12, weight: .semibold)
    package static let caption = Font.system(size: 11)
    package static let label = Font.system(size: 11, weight: .medium)
    package static let mono = Font.system(size: 11, design: .monospaced)

    package enum FigureSize: CGFloat { case hero = 40, metric = 24, large = 15, row = 13 }

    package static func figure(_ size: FigureSize, weight: Font.Weight = .semibold) -> Font {
        .system(size: size.rawValue, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Only for figures drawn to the size of a graphic (the inside of a ring gauge).
    package static func figure(points: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: points, weight: weight, design: .rounded).monospacedDigit()
    }

    // MARK: Motion

    package static let quick = Animation.easeOut(duration: 0.16)
    package static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)
    package static let gentle = Animation.easeInOut(duration: 0.6)
}

extension Animation {
    /// The animation, or none when Reduce Motion is on.
    package func unlessReduced(_ reduce: Bool) -> Animation? { reduce ? nil : self }
}

// MARK: - Page header

/// Title, one line under it, optional actions on the right and optional tabs below. Every page
/// starts with this, so the title sits at the same place whichever page is open.
package struct PageHeader<Trailing: View, Below: View>: View {
    package init(title:String,subtitle:String? = nil,@ViewBuilder trailing:@escaping ()->Trailing,@ViewBuilder below:@escaping ()->Below) {self.title=title;self.subtitle=subtitle;self.trailing=trailing;self.below=below}
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var below: () -> Below

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.pageTitle).foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(Theme.pageSubtitle).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }
            below()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Below == EmptyView {
    package init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, subtitle: subtitle, trailing: trailing, below: { EmptyView() })
    }
}

extension PageHeader where Trailing == EmptyView, Below == EmptyView {
    package init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, below: { EmptyView() })
    }
}

// MARK: - Tabs

/// A segmented control drawn for the dark window: the selection slides between the options.
package struct ThermoTabs<Value: Hashable>: View {
    package init(selection:Binding<Value>,options:[(Value,String)],size:Size = .regular,label:String = "") {self._selection=selection;self.options=options;self.size=size;self.label=label}
    package enum Size { case regular, small }

    @Binding var selection: Value
    let options: [(Value, String)]
    var size: Size = .regular
    var label: String = ""
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Value?

    package var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button {
                    withAnimation(Theme.standard.unlessReduced(reduceMotion)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: size == .small ? 11 : 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.textPrimary : hovered == option.0 ? Theme.textPrimary.opacity(0.85) : Theme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, size == .small ? 9 : 14)
                        .frame(height: size == .small ? 22 : 28)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: size == .small ? 6 : 7, style: .continuous)
                                    .fill(Color.white.opacity(0.13))
                                    .overlay(RoundedRectangle(cornerRadius: size == .small ? 6 : 7, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10)))
                                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option.0 : (hovered == option.0 ? nil : hovered) }
                .accessibilityLabel(option.1)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: size == .small ? 8 : 9, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: size == .small ? 8 : 9, style: .continuous).strokeBorder(Theme.hairline))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Search

/// A search box that matches the panels; ⌘F focuses it when `shortcut` is on.
package struct SearchField: View {
    package init(text:Binding<String>,prompt:String = tr("Search"),shortcut:Bool = true,width:CGFloat? = nil) {self._text=text;self.prompt=prompt;self.shortcut=shortcut;self.width=width}
    @Binding var text: String
    var prompt: String = tr("Search")
    var shortcut = true
    var width: CGFloat? = nil
    @FocusState private var focused: Bool

    package var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .help(tr("Clear search")).accessibilityLabel(tr("Clear search"))
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Color.white.opacity(focused ? 0.08 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.hairline))
        .animation(Theme.quick, value: focused)
        .background(shortcutButton)
    }

    @ViewBuilder var shortcutButton: some View {
        if shortcut {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}

// MARK: - Loading

/// A grey bar standing in for text that is still loading; it breathes instead of spinning.
package struct SkeletonBar: View {
    package init(width:CGFloat? = nil,height:CGFloat = 10) {self.width=width;self.height=height}
    var width: CGFloat? = nil
    var height: CGFloat = 10
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowSamplingActive) private var visible

    package var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(bright ? 0.11 : 0.06))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .animation(reduceMotion || !visible ? nil : .easeInOut(duration: 0.9).repeatForever(), value: bright)
            .onAppear { bright = visible }
            .onChange(of: visible) { bright = $0 }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { bright = false }
            }
            .accessibilityHidden(true)
    }
}

/// Rows of skeleton bars in a panel, for a list that is still loading.
package struct SkeletonList: View {
    package init(rows:Int = 4) {self.rows=rows}
    var rows = 4
    package var body: some View {
        InspectorPanel {
            ForEach(0..<rows, id: \.self) { i in
                if i > 0 { InspectorDivider(inset: 14) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(width: [180, 140, 210, 160][i % 4], height: 10)
                        SkeletonBar(width: [110, 160, 90, 130][i % 4], height: 8)
                    }
                    Spacer()
                    SkeletonBar(width: 56, height: 10)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .accessibilityLabel(tr("Loading"))
    }
}

// MARK: - Rows

/// Lights a row up under the pointer.
package struct HoverHighlight: ViewModifier {
    package init(radius:CGFloat = 0) {self.radius=radius}
    var radius: CGFloat = 0
    @State private var hover = false
    package func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(hover ? 0.035 : 0)))
            .onHover { hover = $0 }
            .animation(Theme.quick, value: hover)
    }
}

extension View {
    package func hoverHighlight(radius: CGFloat = 0) -> some View { modifier(HoverHighlight(radius: radius)) }
}

/// A label + figure pair, the unit of every stats strip.
package struct Metric: View {
    package init(label:String,value:String,detail:String? = nil,color:Color = Theme.textPrimary) {self.label=label;self.value=value;self.detail=detail;self.color=color}
    let label: String
    let value: String
    var detail: String? = nil
    var color: Color = Theme.textPrimary

    package var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Text(value).font(Theme.figure(.metric)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Panels

/// One quiet panel per group; rows inside it are separated by hairlines.
package struct InspectorPanel<Content: View>: View {
    package init(@ViewBuilder content:@escaping ()->Content) {self.content=content}
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    package var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.white.opacity(0.5) : Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

package struct InspectorDivider: View {
    package init(inset:CGFloat = 44) {self.inset=inset}
    var inset: CGFloat = 44
    package var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset) }
}

/// The title over a panel, with room for a figure or a control on the right.
package struct SectionHeader<Trailing: View>: View {
    package init(title:String,@ViewBuilder trailing:@escaping ()->Trailing) {self.title=title;self.trailing=trailing}
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    package var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }.padding(.horizontal, 2).padding(.top, 8)
    }
}

extension SectionHeader where Trailing == EmptyView {
    package init(title: String) { self.init(title: title) { EmptyView() } }
}

/// A neutral status line: results may mix successes and failures, so none of them is drawn as success.
package struct NoticeBanner: View {
    package init(text:String,busy:Bool = false,dismiss:(()->Void)? = nil) {self.text=text;self.busy=busy;self.dismiss=dismiss}
    let text: String
    var busy = false
    var dismiss: (() -> Void)?
    package var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if busy { ProgressView().controlSize(.small) } else {
                Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.9)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(tr("Dismiss")).help(tr("Dismiss"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Small grey capsule naming a requirement or consequence of an action.
package struct RequirementTag: View {
    package init(text:String,warning:Bool = false) {self.text=text;self.warning=warning}
    let text: String
    var warning = false
    package var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(warning ? Theme.caution : Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(warning ? Theme.caution.opacity(0.14) : Color.white.opacity(0.07)))
    }
}

extension AnyTransition {
    /// How pages swap: the new one fades in while rising a few points, the old one just fades.
    package static var page: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }
}

// MARK: - Page frame

/// The bar under a list page for what applies to the whole list (select all, scan again, the
/// main action); it stays put while the list scrolls.
package struct ActionBar<Content: View>: View {
    package init(@ViewBuilder content:@escaping ()->Content) {self.content=content}
    @ViewBuilder let content: () -> Content
    package var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            // Opaque: rows scrolling beneath never show through the controls.
            .background(Theme.canvasDeep)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// A long list in one panel: rows separated by hairlines, built lazily.
package struct RowList<Item: Identifiable, Row: View>: View {
    package init(items:[Item],inset:CGFloat = 14,@ViewBuilder row:@escaping (Item)->Row) {self.items=items;self.inset=inset;self.row=row}
    let items: [Item]
    var inset: CGFloat = 14
    @ViewBuilder let row: (Item) -> Row

    package var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { InspectorDivider(inset: inset) }
                row(item)
            }
        }
        .glass()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// A small colored label on a row ("Running", "Protected").
package struct StatusTag: View {
    package init(text:String,color:Color = Theme.textSecondary) {self.text=text;self.color=color}
    let text: String
    var color: Color = Theme.textSecondary
    package var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.15)))
    }
}

/// A disclosure chevron that turns when its row opens.
package struct DisclosureChevron: View {
    package init(expanded:Bool) {self.expanded=expanded}
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    package var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(Theme.standard.unlessReduced(reduceMotion), value: expanded)
            .frame(width: 22, height: 22)
    }
}

/// What a page shows when there is nothing to list: a symbol, one line, and maybe what to do.
package struct EmptyState: View {
    package init(symbol:String,title:String,detail:String? = nil) {self.symbol=symbol;self.title=title;self.detail=detail}
    let symbol: String
    let title: String
    var detail: String? = nil
    package var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

// MARK: - Explanations on demand

/// A (?) that opens the explanation in a popover. Pages keep their numbers in front and put the
/// sentences that explain them here, so a page reads at a glance and the facts stay one click away.
package struct InfoButton: View {
    package init(text:String,title:String? = nil) {self.text=text;self.title=title}
    let text: String
    var title: String? = nil
    @State private var shown = false

    package var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .medium))
                .foregroundStyle(shown ? Theme.accent : Theme.textTertiary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title ?? tr("More information"))
        .accessibilityLabel(title ?? tr("More information"))
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let title { Text(title).font(Theme.sectionTitle) }
                Text(text).font(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(Theme.Space.l)
            .frame(width: 320, alignment: .leading)
        }
    }
}

// MARK: - Selection

package enum SelectionState { case none, some, all }

/// The one checkbox of the app: empty, a dash for part of a group, a tick for all, or a lock
/// for an item that cannot be picked.
package struct SelectionBox: View {
    package init(state:SelectionState,locked:Bool = false) {self.state=state;self.locked=locked}
    let state: SelectionState
    var locked = false
    @Environment(\.isEnabled) private var isEnabled

    package var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(state == .none || locked ? Color.white.opacity(0.06) : Theme.accent)
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(state == .none || locked ? Color.white.opacity(0.28) : Theme.accent, lineWidth: 1)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
            } else if state == .all {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if state == .some {
                RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 8, height: 2)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 16, height: 16)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Theme.quick, value: state)
        .accessibilityHidden(true)
    }
}

/// A checkbox for one item, tappable with room around it.
package struct SelectToggle: View {
    package init(selected:Bool,locked:Bool = false,label:String,toggle:@escaping ()->Void) {self.selected=selected;self.locked=locked;self.label=label;self.toggle=toggle}
    let selected: Bool
    var locked = false
    let label: String
    let toggle: () -> Void

    package var body: some View {
        Button(action: toggle) {
            SelectionBox(state: selected ? .all : .none, locked: locked)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? tr("Selected") : tr("Not selected"))
    }
}

/// Selects or clears a whole list or group at once: a tri-state checkbox, the group's name, and
/// how many of its items are picked. Clicking picks every item that can be picked, or clears them
/// when all already are. Put one in each group header and one in the action bar.
package struct SelectAllButton: View {
    package init(title:String? = nil,available:Int,selected:Int,selectAll:@escaping ()->Void,clear:@escaping ()->Void) {self.title=title;self.available=available;self.selected=selected;self.selectAll=selectAll;self.clear=clear}
    var title: String? = nil
    /// Items that can be picked (locked ones do not count).
    let available: Int
    let selected: Int
    let selectAll: () -> Void
    let clear: () -> Void

    var state: SelectionState { selected == 0 ? .none : selected >= available ? .all : .some }

    package var body: some View {
        Button { state == .all ? clear() : selectAll() } label: {
            HStack(spacing: Theme.Space.s) {
                SelectionBox(state: available == 0 ? .none : state)
                Text(title ?? (state == .all ? tr("Deselect all") : tr("Select all")))
                    .font(title == nil ? Theme.secondary.weight(.medium) : Theme.sectionTitle)
                    .foregroundStyle(title == nil ? Theme.textPrimary : Theme.textSecondary)
                if available > 0 {
                    Text(tr("%1$@ of %2$@", String(selected), String(available)))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        .contentTransition(.numericText())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(available == 0)
        .accessibilityLabel(title.map { tr("Select all in %1$@", $0) } ?? tr("Select all"))
        .accessibilityValue(tr("%1$@ of %2$@ selected", String(selected), String(available)))
    }
}
