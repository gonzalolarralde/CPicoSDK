import SchedulerPolicies
import Testing

private typealias LiteState = cpicosdk_clutch_lite_state_t
private typealias XNUState = cpicosdk_xnu_clutch_state_t
private typealias XNUBucket = cpicosdk_xnu_clutch_bucket_t

private struct PolicySelection {
    let liteBucket: Int8
    let xnuBucket: Int8
    let liteReason: cpicosdk_clutch_selection_reason_t
    let xnuReason: cpicosdk_clutch_selection_reason_t
}

private struct PolicyPair {
    var lite = LiteState()
    var xnu = XNUState()

    init() {
        cpicosdk_clutch_lite_init(&lite)
        cpicosdk_xnu_clutch_init(&xnu)
    }

    mutating func makeRunnable(_ bucket: UInt8, at timestamp: UInt64) {
        cpicosdk_clutch_lite_bucket_runnable(&lite, bucket, timestamp)
        cpicosdk_xnu_clutch_bucket_runnable(&xnu, bucket, timestamp)
    }

    mutating func makeEmpty(_ bucket: UInt8, at timestamp: UInt64) {
        cpicosdk_clutch_lite_bucket_empty(&lite, bucket, timestamp)
        cpicosdk_xnu_clutch_bucket_empty(&xnu, bucket, timestamp)
    }

    mutating func select(at timestamp: UInt64) -> (lite: Int8, xnu: Int8) {
        (
            cpicosdk_clutch_lite_select(&lite, timestamp, nil),
            cpicosdk_xnu_clutch_select(&xnu, timestamp, nil)
        )
    }

    mutating func selectWithReasons(at timestamp: UInt64) -> PolicySelection {
        var liteReason = CPICOSDK_CLUTCH_SELECTION_EDF
        var xnuReason = CPICOSDK_CLUTCH_SELECTION_EDF
        let liteBucket = cpicosdk_clutch_lite_select(&lite, timestamp, &liteReason)
        let xnuBucket = cpicosdk_xnu_clutch_select(&xnu, timestamp, &xnuReason)
        return PolicySelection(
            liteBucket: liteBucket,
            xnuBucket: xnuBucket,
            liteReason: liteReason,
            xnuReason: xnuReason
        )
    }
}

private func xnuRootBucket(_ state: inout XNUState) -> UInt8? {
    guard let root = state.root_buckets.root else { return nil }
    // `priority_queue_link` is the first field in the bucket, matching XNU's
    // container-of operation in the source-derived implementation.
    return UnsafeRawPointer(root)
        .assumingMemoryBound(to: XNUBucket.self)
        .pointee.bucket
}

private func xnuDeadline(_ state: inout XNUState, bucket: UInt8) -> UInt64 {
    withUnsafePointer(to: &state.buckets) { buckets in
        UnsafeRawPointer(buckets)
            .assumingMemoryBound(to: XNUBucket.self)
            .advanced(by: Int(bucket))
            .pointee.priority_queue_link.deadline
    }
}

@Test func schedulerPoliciesReturnNoBucketWhenEmpty() {
    var policies = PolicyPair()
    let selected = policies.select(at: 0)
    #expect(selected.lite == -1)
    #expect(selected.xnu == -1)
}

@Test func schedulerPoliciesMatchXNUWarpAndStarvationBoundaries() {
    var policies = PolicyPair()
    policies.makeRunnable(0, at: 0)
    policies.makeRunnable(4, at: 0)

    // Foreground is initially the natural EDF bucket. Selecting it at a late
    // timestamp advances its deadline beyond the aged background bucket.
    let oracle: [(UInt64, Int8, cpicosdk_clutch_selection_reason_t)] = [
        (300_000, 0, CPICOSDK_CLUTCH_SELECTION_EDF),
        (300_001, 0, CPICOSDK_CLUTCH_SELECTION_WARP),
        (308_000, 0, CPICOSDK_CLUTCH_SELECTION_WARP),
        (308_001, 4, CPICOSDK_CLUTCH_SELECTION_STARVATION_AVOIDANCE),
        (310_000, 4, CPICOSDK_CLUTCH_SELECTION_STARVATION_AVOIDANCE),
        (310_001, 0, CPICOSDK_CLUTCH_SELECTION_EDF),
    ]

    // This fixed trace covers EDF, an 8 ms foreground warp, the exact warp
    // expiry boundary, and the background bucket's 2 ms starvation window.
    for (timestamp, expectedBucket, expectedReason) in oracle {
        let selected = policies.selectWithReasons(at: timestamp)
        #expect(selected.liteBucket == expectedBucket, "timestamp=\(timestamp)")
        #expect(selected.xnuBucket == expectedBucket, "timestamp=\(timestamp)")
        #expect(selected.liteReason == expectedReason, "timestamp=\(timestamp)")
        #expect(selected.xnuReason == expectedReason, "timestamp=\(timestamp)")
    }
}

@Test func sourceDerivedPairingHeapHandlesTiedDeadlinesAndLifecycle() {
    var state = XNUState()
    cpicosdk_xnu_clutch_init(&state)
    let tiedDeadline: UInt64 = 1_000_000

    // XNU's comparator intentionally makes the newly inserted entry the root
    // when deadlines tie. Build a three-level tied heap in a fixed order.
    cpicosdk_xnu_clutch_bucket_runnable(&state, 0, tiedDeadline)
    #expect(xnuRootBucket(&state) == 0)
    cpicosdk_xnu_clutch_bucket_runnable(&state, 4, tiedDeadline - 250_000)
    #expect(xnuRootBucket(&state) == 4)
    cpicosdk_xnu_clutch_bucket_runnable(&state, 3, tiedDeadline - 150_000)
    #expect(xnuRootBucket(&state) == 3)
    #expect(xnuDeadline(&state, bucket: 0) == tiedDeadline)
    #expect(xnuDeadline(&state, bucket: 3) == tiedDeadline)
    #expect(xnuDeadline(&state, bucket: 4) == tiedDeadline)

    // Bucket 0 warps over the tied EDF root. The second selection increases
    // its deadline while it is a non-root heap entry.
    var reason = CPICOSDK_CLUTCH_SELECTION_EDF
    #expect(cpicosdk_xnu_clutch_select(&state, tiedDeadline, &reason) == 0)
    #expect(reason == CPICOSDK_CLUTCH_SELECTION_WARP)
    #expect(cpicosdk_xnu_clutch_select(&state, tiedDeadline + 1, &reason) == 0)
    #expect(reason == CPICOSDK_CLUTCH_SELECTION_WARP)
    #expect(xnuDeadline(&state, bucket: 0) == tiedDeadline + 1)
    #expect(xnuRootBucket(&state) == 3)

    // Remove and reopen a non-root entry, then remove the root. The minimum
    // surviving entry must become root after the pairing-heap meld.
    cpicosdk_xnu_clutch_bucket_empty(&state, 4, tiedDeadline + 1)
    #expect(xnuRootBucket(&state) == 3)
    cpicosdk_xnu_clutch_bucket_runnable(&state, 4, tiedDeadline + 1)
    #expect(xnuRootBucket(&state) == 3)
    cpicosdk_xnu_clutch_bucket_empty(&state, 3, tiedDeadline + 1)
    #expect(xnuRootBucket(&state) == 0)

    // Selecting the root increases its deadline through the root-update path.
    #expect(cpicosdk_xnu_clutch_select(&state, tiedDeadline + 2, &reason) == 0)
    #expect(reason == CPICOSDK_CLUTCH_SELECTION_EDF)
    #expect(xnuDeadline(&state, bucket: 0) == tiedDeadline + 2)

    cpicosdk_xnu_clutch_bucket_empty(&state, 0, tiedDeadline + 2)
    #expect(xnuRootBucket(&state) == 4)
    cpicosdk_xnu_clutch_bucket_empty(&state, 4, tiedDeadline + 2)
    #expect(xnuRootBucket(&state) == nil)
    cpicosdk_xnu_clutch_bucket_runnable(&state, 4, tiedDeadline + 2)
    #expect(xnuRootBucket(&state) == 4)
    #expect(xnuDeadline(&state, bucket: 4) == tiedDeadline + 250_002)
}

@Test func schedulerPoliciesPreservePartiallyUsedWarpAcrossEmptyBucket() {
    var policies = PolicyPair()
    policies.makeRunnable(0, at: 0)
    policies.makeRunnable(4, at: 0)
    _ = policies.select(at: 300_000)
    _ = policies.select(at: 300_001) // opens foreground warp through 308_001

    policies.makeEmpty(0, at: 304_001)
    policies.makeRunnable(0, at: 305_001)

    var selected = policies.select(at: 305_001)
    #expect(selected.lite == 0)
    #expect(selected.xnu == 0)

    selected = policies.select(at: 308_001)
    #expect(selected.lite == 4)
    #expect(selected.xnu == 4)
}

@Test func compactAndSourceDerivedPoliciesMatchOnDeterministicCorpus() {
    // All timestamps are multiples of 1009. XNU's WCEL constants are not, so
    // distinct buckets cannot acquire equal deadlines in this corpus; XNU's
    // intentionally unstable equal-key heap ordering is therefore irrelevant.
    for seed in UInt64(1)...100 {
        var policies = PolicyPair()
        var runnable = [Bool](repeating: false, count: 5)
        var generator = seed &* 0x9e37_79b9_7f4a_7c15
        var timestamp = seed &* 1009

        for step in 0..<1_000 {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            timestamp &+= 1009
            let bucket = Int((generator >> 32) % 5)
            let runnableCount = runnable.reduce(into: 0) { $0 += $1 ? 1 : 0 }

            if !runnable[bucket] && (runnableCount == 0 || (generator & 3) != 0) {
                policies.makeRunnable(UInt8(bucket), at: timestamp)
                runnable[bucket] = true
                continue
            }

            let selected = policies.select(at: timestamp)
            #expect(
                selected.lite == selected.xnu,
                "seed=\(seed) step=\(step) lite=\(selected.lite) xnu=\(selected.xnu)"
            )
            guard selected.lite >= 0 else {
                continue
            }

            // Sometimes leave the selected bucket runnable to exercise open
            // warp and starvation windows across consecutive selections.
            if (generator & 7) < 5 {
                let selectedBucket = UInt8(selected.lite)
                policies.makeEmpty(selectedBucket, at: timestamp)
                runnable[Int(selectedBucket)] = false
            }
        }
    }
}
