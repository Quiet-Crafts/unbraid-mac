import Foundation

/// A row of the apps list.
nonisolated struct Row: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let routeName: String
    let week: Int64
}

/// How the list is sorted: a column and a direction, names breaking ties, so apps with no data stay in A to Z order.
nonisolated struct AppsSort: Equatable {
    enum Key: String { case name, route, week }
    struct Term: Equatable {
        var key: Key
        var ascending: Bool
    }
    /// The columns clicked, latest first: the earlier ones order what the latest leaves tied.
    var terms = [Term(key: .week, ascending: false)]

    func inOrder(_ a: Row, _ b: Row) -> Bool {
        for term in terms {
            let order: ComparisonResult
            switch term.key {
            case .name: order = a.name.localizedStandardCompare(b.name)
            case .route: order = a.routeName.localizedStandardCompare(b.routeName)
            case .week: order = a.week == b.week ? .orderedSame : a.week < b.week ? .orderedAscending : .orderedDescending
            }
            if order != .orderedSame { return order == (term.ascending ? .orderedAscending : .orderedDescending) }
        }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// What the apps search matches.
nonisolated enum AppSearch {
    /// A name always matches; the identifier only for a command-line tool, whose path the row shows. An app's
    /// identifier is not shown, so "app" must not list every com.apple app.
    static func matches(name: String, id: String, query q: String) -> Bool {
        q.isEmpty || name.localizedStandardContains(q) || (id.hasPrefix("/") && id.localizedStandardContains(q))
    }
}
