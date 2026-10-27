import Foundation
import SwiftUI

/// The banner texts (Czech; numbers with Czech digit grouping, "3 000").
enum BannerText {
    static let resolvingPlaces = "Zjišťuji místa…"
    static let sourceUnavailable = "Fotky nelze načíst: chybí přístup k Fotkám"

    static func analyzing(done: Int, total: Int) -> String {
        "Analyzuji fotky \(czech(done)) / \(czech(total))"
    }

    static func text(for activity: BackgroundActivity) -> String? {
        switch activity {
        case .idle: nil
        case .analyzing(let done, let total): analyzing(done: done, total: total)
        case .resolvingPlaces: resolvingPlaces
        case .sourceUnavailable: sourceUnavailable
        }
    }

    private static let czechLocale = Locale(identifier: "cs_CZ")

    /// `3000` -> "3 000" (the grouping separator is a no-break space).
    static func czech(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic).locale(czechLocale))
    }
}

/// The strip at the top of the album window while background work runs. Only this view reads
/// the work's counters, so a progress step re-renders the banner, not the window.
struct ProgressBanner: View {
    let work: BackgroundWork

    var body: some View {
        let activity = work.activity
        if let text = BannerText.text(for: activity) {
            HStack(spacing: 10) {
                switch activity {
                case .analyzing(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                case .resolvingPlaces:
                    ProgressView().controlSize(.small)
                case .sourceUnavailable:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
                Text(text)
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
}
