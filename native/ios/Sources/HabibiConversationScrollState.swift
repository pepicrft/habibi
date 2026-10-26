// Adapted from Tuist Atlas (9af36c01be). MIT license: native/ATLAS_LICENSE.
import Combine
import Foundation

struct HabibiScrollMetrics: Equatable {
    let height: CGFloat
    let bottom: CGFloat
    let viewport: CGFloat
    var inset: CGFloat = 0
    var offset: CGFloat { height - bottom }
    var atBottom: Bool { abs(bottom - viewport) <= 20 }
}

final class HabibiConversationScrollState: ObservableObject {
    @Published var following = true
    @Published var editingEntry = false {
        didSet { if editingEntry { following = false } }
    }
    var userScrolling: Bool?
    private var previous: HabibiScrollMetrics?
    private var baseline: CGFloat?
    private var correcting = false

    func update(_ metrics: HabibiScrollMetrics) -> Bool {
        let layoutChanged = previous?.height != metrics.height || previous?.viewport != metrics.viewport || previous?.inset != metrics.inset
        previous = metrics
        if layoutChanged { baseline = metrics.offset; correcting = following }
        let origin = max(baseline ?? metrics.offset, metrics.offset)
        let movedUp = metrics.offset < origin - 1
        baseline = movedUp ? metrics.offset : origin
        // Keyboard reflow must not pull an active inline field to the latest reply.
        if editingEntry { return false }
        if metrics.atBottom {
            if !following { following = true }
            correcting = false
        } else if userScrolling == true || (userScrolling == nil && !correcting && !layoutChanged && movedUp) {
            if following { following = false }
            correcting = false
        }
        return following && !metrics.atBottom
    }
}
