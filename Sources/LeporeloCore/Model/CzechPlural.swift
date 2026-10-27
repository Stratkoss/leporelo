import Foundation

/// Czech plural forms for counts shown in the UI and in messages: 1 -> `one` ("fotka"),
/// 2...4 -> `few` ("fotky"), everything else (0, 5+, negatives) -> `many` ("fotek").
/// Czech uses `many` for 21-24 too ("22 fotek"), so only the whole number matters.
public enum CzechPlural {
    private static let locale = Locale(identifier: "cs_CZ")

    public static func choose(_ n: Int, one: String, few: String, many: String) -> String {
        switch n {
        case 1: one
        case 2...4: few
        default: many
        }
    }

    /// `3000` -> "3 000" (Czech grouping; the separator is a no-break space).
    public static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// "148 fotek", with Czech grouping.
    public static func count(_ n: Int, one: String, few: String, many: String) -> String {
        "\(grouped(n)) \(choose(n, one: one, few: few, many: many))"
    }

    /// "1 fotka", "3 fotky", "148 fotek".
    public static func photos(_ n: Int) -> String { count(n, one: "fotka", few: "fotky", many: "fotek") }

    /// "1 strana", "4 strany", "36 stran".
    public static func pages(_ n: Int) -> String { count(n, one: "strana", few: "strany", many: "stran") }
}
