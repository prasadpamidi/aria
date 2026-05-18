import Foundation
import SwiftData

@Model
final class Item {
    // MARK: Lifecycle

    init(timestamp: Date) {
        self.timestamp = timestamp
    }

    // MARK: Internal

    var timestamp: Date
}
