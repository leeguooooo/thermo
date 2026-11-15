import NativeFeatureAPI
import ThermoUI
import CleanKit
import SwiftUI
import ThermoL10n

/// The feature owns its page host, scan notices and cleanup confirmation.
struct DiskPages: View {
    let navigate: (DiskPage) -> Void
    let revealInSpace: (String) -> Void
    let overview: SpaceOverviewModel?
    let availability: @MainActor () -> Bool
    let sub: DiskPage
    @ObservedObject var disk: DiskModel
    @State private var cleanReview: DiskCleanupReview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var cleanupCategory: CleanCategory? {
        if case let .category(category) = sub { return category }
        return nil
    }

    var cleanupNoticeNeeded: Bool {
        switch sub {
        case .home, .category:
            return disk.scopeNeedsRefresh(category: cleanupCategory) || disk.resultsNeedRefresh || disk.languageStale
        default: return false
        }
    }

    func startClean() { if cleanReview == nil { cleanReview = disk.cleanupReview() } }
    func load() { if disk.report == nil, !disk.scanning { disk.loadSaved(category: cleanupCategory) } }

    var body: some View {
        VStack(spacing: 0) {
            if let error = disk.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body).foregroundStyle(Theme.caution).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass(radius: 12)
                    .padding(.horizontal, 32).padding(.top, 12)
            }
            if cleanupNoticeNeeded {
                HStack {
                    Text(disk.resultsNeedRefresh ? tr("Some paths could not be removed. Scan again to refresh the remaining items.") : disk.languageStale ? tr("Scan again to refresh results in the selected language.") : tr("Scan scope changed. Scan again to update these results.")).font(Theme.body)
                    Spacer()
                    Button(tr("Scan again")) { disk.scan(category: cleanupCategory) }.disabled(disk.scanning || disk.cleaning)
                }
                .padding(14).glass(radius: 12).padding(.horizontal, 32).padding(.top, 12)
            }
            ZStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Theme.standard.unlessReduced(reduceMotion), value: sub)
        }
        .onChange(of: sub) { _ in load() }
        .onAppear { load() }
        .sheet(item: $cleanReview) { review in
            DiskCleanConfirmation(review: review,
                                  confirm: { cleanReview = nil; disk.clean(review: review) }, cancel: { cleanReview = nil })
        }
    }

    @ViewBuilder var content: some View {
        switch sub {
        case .home:
            DiskHome(model: disk, open: { navigate(.category($0)) }, clean: startClean).transition(.page)
        case .overview:
            if let measured=overview {
            DiskOverviewView(model:measured,explanationWork:disk.explanationWork,availability:availability,openCleanup:{category in
                measured.stop()
                if !disk.scanning && !disk.cleaning {disk.scan(category:category)}
                navigate(category.map(DiskPage.category) ?? .home)
            },cleanupDisabled:disk.scanning || disk.cleaning,openInSpaceLens:{path in
                measured.stop();revealInSpace(path)
            }).transition(.page)
            }
        case let .category(c):
            DiskCategoryPage(model: disk, category: c, clean: startClean, cleanOne: { item in if cleanReview == nil { cleanReview = disk.cleanupReview(of: item) } }).id(c)
                .transition(.page)
        }
    }
}

