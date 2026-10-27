import AppKit
import Foundation
import LeporeloCore
import SwiftUI

/// Everything the banner could show, from the window's background work (`BackgroundWork`,
/// `OriginalsWork`).
struct BannerState: Equatable {
    var analysis: PipelineProgress?
    var originals: OriginalsWork.Progress?
    var resolvingPlaces = false
    var sourceUnavailable = false
    var failedOriginals = 0

    @MainActor
    init(work: BackgroundWork?, originals: OriginalsWork?) {
        analysis = work?.analysisProgress
        resolvingPlaces = work?.isResolvingPlaces ?? false
        sourceUnavailable = (work?.sourceUnavailable ?? false) || (originals?.sourceUnavailable ?? false)
        self.originals = originals?.progress
        failedOriginals = originals?.failedCount ?? 0
    }

    init() {}
}

/// The banner texts (Czech; numbers with Czech digit grouping, "3 000").
enum BannerText {
    static let resolvingPlaces = "Zjišťuji místa…"
    static let sourceUnavailable = "Fotky nelze načíst: chybí přístup k Fotkám"
    static let retry = "Stáhnout znovu"
    static let openSettings = "Otevřít Nastavení"

    static func analyzing(done: Int, total: Int) -> String {
        "Analyzuji fotky \(czech(done)) / \(czech(total))"
    }

    static func downloading(done: Int, total: Int) -> String {
        "Stahuji originály \(czech(done)) / \(czech(total))"
    }

    /// "3 originály se nepodařilo stáhnout".
    static func failedOriginals(_ count: Int) -> String {
        "\(CzechPlural.count(count, one: "originál", few: "originály", many: "originálů")) se nepodařilo stáhnout"
    }

    /// ONE line (no stacked banners, so nothing flickers between them), by priority: analysis,
    /// originals, places, missing Photos access, originals that failed; nil when there is nothing
    /// to say. An analysis of 0 photos counts as none.
    static func line(for state: BannerState) -> BackgroundActivity? {
        if let a = state.analysis, a.total > 0 { return .analyzing(done: a.done, total: a.total) }
        if let o = state.originals, o.total > 0 { return .downloading(done: o.done, total: o.total) }
        if state.resolvingPlaces { return .resolvingPlaces }
        if state.sourceUnavailable { return .sourceUnavailable }
        if state.failedOriginals > 0 { return .failedOriginals(state.failedOriginals) }
        return nil
    }

    /// "Stáhnout znovu" in the banner: some originals failed and nothing is downloading.
    static func offersRetry(_ state: BannerState) -> Bool {
        state.failedOriginals > 0 && state.originals == nil && !state.sourceUnavailable
    }

    static func text(for activity: BackgroundActivity) -> String? {
        switch activity {
        case .idle: nil
        case .analyzing(let done, let total): analyzing(done: done, total: total)
        case .downloading(let done, let total): downloading(done: done, total: total)
        case .resolvingPlaces: resolvingPlaces
        case .sourceUnavailable: sourceUnavailable
        case .failedOriginals(let count): failedOriginals(count)
        }
    }

    private static let czechLocale = Locale(identifier: "cs_CZ")

    /// `3000` -> "3 000" (the grouping separator is a no-break space).
    static func czech(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic).locale(czechLocale))
    }
}

/// The strip at the top of the album window while background work runs. Only this view reads
/// the works' counters, so a progress step re-renders the banner, not the window.
struct ProgressBanner: View {
    let work: BackgroundWork?
    let originals: OriginalsWork?

    var body: some View {
        let state = BannerState(work: work, originals: originals)
        if let activity = BannerText.line(for: state), let text = BannerText.text(for: activity) {
            HStack(spacing: 10) {
                switch activity {
                case .analyzing(let done, let total), .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                case .resolvingPlaces:
                    ProgressView().controlSize(.small)
                case .sourceUnavailable, .failedOriginals:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
                Text(text)
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
                if activity == .sourceUnavailable {
                    Button(BannerText.openSettings) { NSWorkspace.shared.open(PhotoAccess.settingsURL) }
                        .controlSize(.small)
                }
                if BannerText.offersRetry(state) {
                    Button(BannerText.retry) { originals?.retryFailed() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
}
