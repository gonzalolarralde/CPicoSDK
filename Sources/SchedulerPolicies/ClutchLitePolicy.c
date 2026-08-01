#include "SchedulerPolicies.h"

#include <assert.h>
#include <limits.h>
#include <string.h>

#if defined(CPICOSDK_SCHEDULER_EMBEDDED)
#define CPICOSDK_POLICY_HOT __attribute__((section(".time_critical.cpicosdk_scheduler_policy")))
#else
#define CPICOSDK_POLICY_HOT
#endif

#if defined(CPICOSDK_SCHEDULER_CLUTCH_LITE) || \
    defined(CPICOSDK_SCHEDULER_POLICY_COMPARISON) || \
    defined(CPICOSDK_SCHEDULER_POLICY_TESTING)

/*
 * Clean-room implementation of the root-bucket behavior described in
 * Apple's public Clutch scheduler design. This file does not contain XNU
 * source code; the constants intentionally match the source-derived variant
 * so deterministic traces can compare the two implementations.
 */

static const uint32_t cpicosdk_clutch_wcel_us[CPICOSDK_CLUTCH_BUCKET_COUNT] = {
    0u,
    37500u,
    75000u,
    150000u,
    250000u,
};

static const uint32_t cpicosdk_clutch_warp_us[CPICOSDK_CLUTCH_BUCKET_COUNT] = {
    8000u,
    4000u,
    2000u,
    1000u,
    0u,
};

static const uint32_t cpicosdk_clutch_quantum_us[CPICOSDK_CLUTCH_BUCKET_COUNT] = {
    10000u,
    8000u,
    6000u,
    4000u,
    2000u,
};

static inline uint8_t cpicosdk_clutch_bit(uint8_t bucket) {
    return (uint8_t)(1u << bucket);
}

static int8_t cpicosdk_clutch_highest_set(uint8_t bitmap) {
    return bitmap == 0u ? CPICOSDK_CLUTCH_NO_BUCKET : (int8_t)__builtin_ctz((unsigned int)bitmap);
}

static int8_t cpicosdk_clutch_earliest_deadline(const cpicosdk_clutch_lite_state_t *state) {
    if ((state->runnable_bitmap & (uint8_t)(state->runnable_bitmap - 1u)) == 0u) {
        return cpicosdk_clutch_highest_set(state->runnable_bitmap);
    }

    int8_t selected = CPICOSDK_CLUTCH_NO_BUCKET;
    uint64_t earliest = UINT64_MAX;

    for (uint8_t bucket = 0; bucket < CPICOSDK_CLUTCH_BUCKET_COUNT; bucket++) {
        if ((state->runnable_bitmap & cpicosdk_clutch_bit(bucket)) == 0u) {
            continue;
        }
        if (selected == CPICOSDK_CLUTCH_NO_BUCKET || state->deadline[bucket] < earliest) {
            selected = (int8_t)bucket;
            earliest = state->deadline[bucket];
        }
    }
    return selected;
}

static inline void cpicosdk_clutch_deadline_update(
    cpicosdk_clutch_lite_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us)
{
    uint64_t new_deadline = timestamp_us + cpicosdk_clutch_wcel_us[bucket];
    assert(state->deadline[bucket] <= new_deadline);
    state->deadline[bucket] = new_deadline;
}

void cpicosdk_clutch_lite_init(cpicosdk_clutch_lite_state_t *state) {
    assert(state != NULL);
    memset(state, 0, sizeof(*state));
    for (uint8_t bucket = 0; bucket < CPICOSDK_CLUTCH_BUCKET_COUNT; bucket++) {
        state->warp_remaining[bucket] = cpicosdk_clutch_warp_us[bucket];
        state->warped_deadline[bucket] = UINT64_MAX;
    }
}

void CPICOSDK_POLICY_HOT cpicosdk_clutch_lite_bucket_runnable(
    cpicosdk_clutch_lite_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us)
{
    assert(state != NULL);
    assert(bucket < CPICOSDK_CLUTCH_BUCKET_COUNT);
    uint8_t bit = cpicosdk_clutch_bit(bucket);
    assert((state->runnable_bitmap & bit) == 0u);

    state->runnable_bitmap |= bit;
    if ((state->starvation_bitmap & bit) == 0u) {
        state->deadline[bucket] = timestamp_us + cpicosdk_clutch_wcel_us[bucket];
    }
    if (state->warp_remaining[bucket] != 0u) {
        state->warp_available_bitmap |= bit;
    }
}

void CPICOSDK_POLICY_HOT cpicosdk_clutch_lite_bucket_empty(
    cpicosdk_clutch_lite_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us)
{
    assert(state != NULL);
    assert(bucket < CPICOSDK_CLUTCH_BUCKET_COUNT);
    uint8_t bit = cpicosdk_clutch_bit(bucket);
    assert((state->runnable_bitmap & bit) != 0u);

    state->runnable_bitmap &= (uint8_t)~bit;
    state->warp_available_bitmap &= (uint8_t)~bit;

    if (state->warped_deadline[bucket] != UINT64_MAX) {
        state->warp_remaining[bucket] = state->warped_deadline[bucket] > timestamp_us
            ? state->warped_deadline[bucket] - timestamp_us
            : 0u;
    }
}

int8_t CPICOSDK_POLICY_HOT cpicosdk_clutch_lite_select(
    cpicosdk_clutch_lite_state_t *state,
    uint64_t timestamp_us,
    cpicosdk_clutch_selection_reason_t *reason)
{
    assert(state != NULL);

evaluate_root_buckets:
    {
        int8_t edf = cpicosdk_clutch_earliest_deadline(state);
        if (edf == CPICOSDK_CLUTCH_NO_BUCKET) {
            return CPICOSDK_CLUTCH_NO_BUCKET;
        }
        uint8_t edf_bucket = (uint8_t)edf;
        uint8_t edf_bit = cpicosdk_clutch_bit(edf_bucket);

        if ((state->starvation_bitmap & edf_bit) != 0u &&
            timestamp_us >= state->starvation_timestamp[edf_bucket] + cpicosdk_clutch_quantum_us[edf_bucket]) {
            state->starvation_bitmap &= (uint8_t)~edf_bit;
            state->starvation_timestamp[edf_bucket] = 0u;
            cpicosdk_clutch_deadline_update(state, edf_bucket, timestamp_us);
            goto evaluate_root_buckets;
        }

        int8_t highest = cpicosdk_clutch_highest_set(state->runnable_bitmap);
        int8_t warp = cpicosdk_clutch_highest_set(state->warp_available_bitmap);
        bool can_warp = warp != CPICOSDK_CLUTCH_NO_BUCKET && warp < edf;

        if (!can_warp) {
            if ((state->starvation_bitmap & edf_bit) == 0u) {
                if (highest < edf) {
                    state->starvation_bitmap |= edf_bit;
                    state->starvation_timestamp[edf_bucket] = timestamp_us;
                } else {
                    cpicosdk_clutch_deadline_update(state, edf_bucket, timestamp_us);
                    state->warp_remaining[edf_bucket] = cpicosdk_clutch_warp_us[edf_bucket];
                    state->warped_deadline[edf_bucket] = UINT64_MAX;
                    if (state->warp_remaining[edf_bucket] != 0u) {
                        state->warp_available_bitmap |= edf_bit;
                    }
                }
            }
            if (reason != NULL) {
                *reason = (state->starvation_bitmap & edf_bit) != 0u
                    ? CPICOSDK_CLUTCH_SELECTION_STARVATION_AVOIDANCE
                    : CPICOSDK_CLUTCH_SELECTION_EDF;
            }
            return edf;
        }

        uint8_t warp_bucket = (uint8_t)warp;
        uint8_t warp_bit = cpicosdk_clutch_bit(warp_bucket);
        if (state->warped_deadline[warp_bucket] == UINT64_MAX) {
            state->warped_deadline[warp_bucket] = timestamp_us + state->warp_remaining[warp_bucket];
            cpicosdk_clutch_deadline_update(state, warp_bucket, timestamp_us);
            if (reason != NULL) {
                *reason = CPICOSDK_CLUTCH_SELECTION_WARP;
            }
            return warp;
        }
        if (state->warped_deadline[warp_bucket] > timestamp_us) {
            cpicosdk_clutch_deadline_update(state, warp_bucket, timestamp_us);
            if (reason != NULL) {
                *reason = CPICOSDK_CLUTCH_SELECTION_WARP;
            }
            return warp;
        }

        state->warp_remaining[warp_bucket] = 0u;
        state->warp_available_bitmap &= (uint8_t)~warp_bit;
        goto evaluate_root_buckets;
    }
}

#endif
