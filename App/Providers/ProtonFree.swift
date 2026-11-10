import Foundation

/// Only the servers a Free plan's key can use.
nonisolated struct ProtonFree: ProtonPlan {
    let free = true
    var catalogue = Catalog.Source.proton
}
