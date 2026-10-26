import Foundation

public enum Recommender {
    public static let minTarget = 8
    public static let maxTarget = 20
    public static let photosPerPick = 6
    /// Spread rule: preferred minimum gap between two selected photos.
    public static let minSpacing: TimeInterval = 120

    /// `n` = eligible photos (no videos, utility or defective). Integer division.
    public static func targetCount(photoCount n: Int) -> Int {
        min(n, min(max(n / photosPerPick, minTarget), maxTarget))
    }

    /// Deterministic. Series losers are never recommended. Candidates are ranked: series winners
    /// first, then by score (ties: capturedAt, id). Pass 1 enforces `minSpacing`; if the target is
    /// not reached, pass 2 relaxes spacing and fills in rank order.
    public static func recommend(day: DayGroup, series: [Series]) -> Set<PhotoID> {
        let eligible = day.photos.filter { $0.kind != .video && !PhotoScore.isDefective($0) }
        let target = targetCount(photoCount: eligible.count)
        guard target > 0 else { return [] }

        func rank(_ a: Photo, _ b: Photo) -> Bool {
            let sa = PhotoScore.score(a), sb = PhotoScore.score(b)
            if sa != sb { return sa > sb }
            return (a.capturedAt, a.id) < (b.capturedAt, b.id)
        }

        let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var winners = Set<PhotoID>()
        var losers = Set<PhotoID>()
        for s in series {
            let members = s.photoIDs.compactMap { byID[$0] }.sorted(by: rank)
            guard let best = members.first else { continue }
            winners.insert(best.id)
            members.dropFirst().forEach { losers.insert($0.id) }
        }
        let candidates = eligible.filter { !losers.contains($0.id) }.sorted { a, b in
            let wa = winners.contains(a.id), wb = winners.contains(b.id)
            if wa != wb { return wa }
            return rank(a, b)
        }

        var picked: [Photo] = []
        for c in candidates where picked.count < target {
            if picked.allSatisfy({ abs($0.capturedAt.timeIntervalSince(c.capturedAt)) >= minSpacing }) {
                picked.append(c)
            }
        }
        if picked.count < target {
            let have = Set(picked.map(\.id))
            for c in candidates where picked.count < target && !have.contains(c.id) {
                picked.append(c)
            }
        }
        return Set(picked.map(\.id))
    }
}
