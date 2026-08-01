/*
 * Copyright (c) 2018 Apple Inc. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. The rights granted to you under the License
 * may not be used to create, or enable the creation or redistribution of,
 * unlawful or unlicensed copies of an Apple operating system, or to
 * circumvent, violate, or enable the circumvention or violation of, any
 * terms of an Apple operating system software license agreement.
 *
 * Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */

/*
 * CPicoSDK modifications, 2026-08-01:
 * Derived from apple-oss-distributions/xnu commit
 * f6217f891ac0bb64f3d375211650a4c1ff8ca1ea, specifically the deadline
 * pairing heap declarations and implementation in
 * osfmk/kern/priority_queue.h and libkern/c++/priority_queue.cpp, and the
 * timeshare root policy in osfmk/kern/sched_clutch.c. It was converted from
 * kernel C++ to freestanding C, reduced to one five-bucket hierarchy, and
 * stripped of threads, bound buckets, fixed-priority work, preemption,
 * processor sets, thread groups, and tracing. The pairing-heap operations
 * and root-policy update/branch ordering remain source-derived for
 * experimental comparison.
 */

#include "SchedulerPolicies.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(CPICOSDK_SCHEDULER_XNU_CLUTCH) || \
    defined(CPICOSDK_SCHEDULER_POLICY_COMPARISON) || \
    defined(CPICOSDK_SCHEDULER_POLICY_TESTING)

#if defined(CPICOSDK_SCHEDULER_EMBEDDED)
#define CPICOSDK_XNU_HOT __attribute__((section(".time_critical.cpicosdk_scheduler_policy")))
#else
#define CPICOSDK_XNU_HOT
#endif
#define CPICOSDK_XNU_NOINLINE __attribute__((noinline)) CPICOSDK_XNU_HOT
#define CPICOSDK_XNU_WARP_UNUSED UINT64_MAX

static const uint32_t cpicosdk_xnu_root_bucket_wcel_us[CPICOSDK_CLUTCH_BUCKET_COUNT] = {
    0u,
    37500u,
    75000u,
    150000u,
    250000u,
};

static const uint32_t cpicosdk_xnu_root_bucket_warp_us[CPICOSDK_CLUTCH_BUCKET_COUNT] = {
    8000u,
    4000u,
    2000u,
    1000u,
    0u,
};

static const uint32_t cpicosdk_xnu_thread_quantum_us[CPICOSDK_CLUTCH_BUCKET_COUNT] = {
    10000u,
    8000u,
    6000u,
    4000u,
    2000u,
};

static inline uint8_t cpicosdk_xnu_bit(uint8_t bucket) {
    return (uint8_t)(1u << bucket);
}

static int8_t cpicosdk_xnu_bitmap_lsb_first(uint8_t bitmap) {
    return bitmap == 0u ? CPICOSDK_CLUTCH_NO_BUCKET : (int8_t)__builtin_ctz((unsigned int)bitmap);
}

static inline cpicosdk_xnu_priority_queue_entry_deadline_t *
cpicosdk_xnu_unpack_child(cpicosdk_xnu_priority_queue_entry_deadline_t *entry) {
    return (cpicosdk_xnu_priority_queue_entry_deadline_t *)(uintptr_t)entry->child;
}

static inline void cpicosdk_xnu_pack_child(
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry,
    cpicosdk_xnu_priority_queue_entry_deadline_t *child)
{
    entry->child = (long)(uintptr_t)child;
}

/* Keep XNU's comparator behavior, including its non-zero equal-key result. */
static inline int cpicosdk_xnu_deadline_compare(
    const cpicosdk_xnu_priority_queue_entry_deadline_t *first,
    const cpicosdk_xnu_priority_queue_entry_deadline_t *second)
{
    return first->deadline < second->deadline ? 1 : -1;
}

static inline bool cpicosdk_xnu_merge_parent_is_second(
    cpicosdk_xnu_priority_queue_entry_deadline_t *first,
    cpicosdk_xnu_priority_queue_entry_deadline_t *second)
{
    return cpicosdk_xnu_deadline_compare(first, second) < 0;
}

static inline cpicosdk_xnu_priority_queue_entry_deadline_t *
cpicosdk_xnu_merge_pair_inline(
    cpicosdk_xnu_priority_queue_entry_deadline_t *first,
    cpicosdk_xnu_priority_queue_entry_deadline_t *second)
{
    cpicosdk_xnu_priority_queue_entry_deadline_t *result = NULL;
    if (first == NULL) {
        result = second;
    } else if (second == NULL || first == second) {
        result = first;
    } else {
        cpicosdk_xnu_priority_queue_entry_deadline_t *parent = first;
        cpicosdk_xnu_priority_queue_entry_deadline_t *child = second;
        if (cpicosdk_xnu_merge_parent_is_second(first, second)) {
            parent = second;
            child = first;
        }
        child->next = cpicosdk_xnu_unpack_child(parent);
        child->prev = parent;
        if (cpicosdk_xnu_unpack_child(parent) != NULL) {
            cpicosdk_xnu_unpack_child(parent)->prev = child;
        }
        cpicosdk_xnu_pack_child(parent, child);
        parent->next = NULL;
        parent->prev = NULL;
        result = parent;
    }
    return result;
}

static CPICOSDK_XNU_NOINLINE cpicosdk_xnu_priority_queue_entry_deadline_t *
cpicosdk_xnu_merge_pair(
    cpicosdk_xnu_priority_queue_entry_deadline_t *first,
    cpicosdk_xnu_priority_queue_entry_deadline_t *second)
{
    return cpicosdk_xnu_merge_pair_inline(first, second);
}

static CPICOSDK_XNU_NOINLINE cpicosdk_xnu_priority_queue_entry_deadline_t *
cpicosdk_xnu_meld_pair(cpicosdk_xnu_priority_queue_entry_deadline_t *entry) {
    cpicosdk_xnu_priority_queue_entry_deadline_t *meld_result = NULL;
    cpicosdk_xnu_priority_queue_entry_deadline_t *pair_list = NULL;

    assert(entry != NULL);
    do {
        cpicosdk_xnu_priority_queue_entry_deadline_t *pair_item_a = entry;
        cpicosdk_xnu_priority_queue_entry_deadline_t *pair_item_b = entry->next;
        if (pair_item_b == NULL) {
            pair_item_a->prev = pair_list;
            pair_list = pair_item_a;
            break;
        }
        entry = pair_item_b->next;
        cpicosdk_xnu_priority_queue_entry_deadline_t *pair =
            cpicosdk_xnu_merge_pair_inline(pair_item_a, pair_item_b);
        pair->prev = pair_list;
        pair_list = pair;
    } while (entry != NULL);

    do {
        entry = pair_list->prev;
        meld_result = cpicosdk_xnu_merge_pair_inline(meld_result, pair_list);
        pair_list = entry;
    } while (pair_list != NULL);

    return meld_result;
}

static inline void cpicosdk_xnu_list_clear(
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry)
{
    entry->next = NULL;
    entry->prev = NULL;
}

static inline void cpicosdk_xnu_list_remove(
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry)
{
    assert(entry->prev != NULL);
    if (cpicosdk_xnu_unpack_child(entry->prev) == entry) {
        cpicosdk_xnu_pack_child(entry->prev, entry->next);
    } else {
        entry->prev->next = entry->next;
    }
    if (entry->next != NULL) {
        entry->next->prev = entry->prev;
    }
    cpicosdk_xnu_list_clear(entry);
}

static inline bool cpicosdk_xnu_priority_queue_insert(
    cpicosdk_xnu_priority_queue_deadline_min_t *queue,
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry,
    bool clear)
{
    if (clear) {
        cpicosdk_xnu_list_clear(entry);
        cpicosdk_xnu_pack_child(entry, NULL);
    }
    queue->root = cpicosdk_xnu_merge_pair(queue->root, entry);
    return queue->root == entry;
}

static inline cpicosdk_xnu_priority_queue_entry_deadline_t *
cpicosdk_xnu_priority_queue_remove_root(
    cpicosdk_xnu_priority_queue_deadline_min_t *queue,
    cpicosdk_xnu_priority_queue_entry_deadline_t *old_root)
{
    cpicosdk_xnu_priority_queue_entry_deadline_t *new_root = cpicosdk_xnu_unpack_child(old_root);
    if (new_root != NULL) {
        queue->root = cpicosdk_xnu_meld_pair(new_root);
        cpicosdk_xnu_pack_child(old_root, NULL);
    } else {
        queue->root = NULL;
    }
    return old_root;
}

static inline cpicosdk_xnu_priority_queue_entry_deadline_t *
cpicosdk_xnu_priority_queue_remove_non_root(
    cpicosdk_xnu_priority_queue_deadline_min_t *queue,
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry)
{
    cpicosdk_xnu_list_remove(entry);
    cpicosdk_xnu_priority_queue_entry_deadline_t *child = cpicosdk_xnu_unpack_child(entry);
    if (child != NULL) {
        child = cpicosdk_xnu_meld_pair(child);
        queue->root = cpicosdk_xnu_merge_pair(queue->root, child);
        cpicosdk_xnu_pack_child(entry, NULL);
    }
    return entry;
}

static inline bool cpicosdk_xnu_priority_queue_remove(
    cpicosdk_xnu_priority_queue_deadline_min_t *queue,
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry)
{
    if (entry == queue->root) {
        cpicosdk_xnu_priority_queue_remove_root(queue, entry);
        return true;
    }
    cpicosdk_xnu_priority_queue_remove_non_root(queue, entry);
    return false;
}

static inline bool cpicosdk_xnu_priority_queue_entry_increased(
    cpicosdk_xnu_priority_queue_deadline_min_t *queue,
    cpicosdk_xnu_priority_queue_entry_deadline_t *entry)
{
    bool was_root = queue->root == entry;
    if (!was_root) {
        cpicosdk_xnu_priority_queue_remove_non_root(queue, entry);
        cpicosdk_xnu_priority_queue_insert(queue, entry, false);
    } else if (cpicosdk_xnu_unpack_child(entry) != NULL) {
        cpicosdk_xnu_priority_queue_remove_root(queue, entry);
        cpicosdk_xnu_priority_queue_insert(queue, entry, false);
    }
    return was_root;
}

static inline cpicosdk_xnu_clutch_bucket_t *cpicosdk_xnu_bucket_for_link(
    cpicosdk_xnu_priority_queue_entry_deadline_t *link)
{
    return link == NULL
        ? NULL
        : (cpicosdk_xnu_clutch_bucket_t *)((char *)link - offsetof(cpicosdk_xnu_clutch_bucket_t, priority_queue_link));
}

static uint64_t cpicosdk_xnu_root_bucket_deadline_calculate(
    const cpicosdk_xnu_clutch_bucket_t *root_bucket,
    uint64_t timestamp_us)
{
    return timestamp_us + cpicosdk_xnu_root_bucket_wcel_us[root_bucket->bucket];
}

static void CPICOSDK_XNU_HOT cpicosdk_xnu_root_bucket_deadline_update(
    cpicosdk_xnu_clutch_bucket_t *root_bucket,
    cpicosdk_xnu_clutch_state_t *root_clutch,
    uint64_t timestamp_us,
    bool bucket_is_enqueued)
{
    uint64_t old_deadline = root_bucket->priority_queue_link.deadline;
    uint64_t new_deadline = cpicosdk_xnu_root_bucket_deadline_calculate(root_bucket, timestamp_us);
    assert(old_deadline <= new_deadline);
    if (old_deadline != new_deadline) {
        root_bucket->priority_queue_link.deadline = new_deadline;
        if (bucket_is_enqueued) {
            cpicosdk_xnu_priority_queue_entry_increased(
                &root_clutch->root_buckets,
                &root_bucket->priority_queue_link);
        }
    }
}

void cpicosdk_xnu_clutch_init(cpicosdk_xnu_clutch_state_t *state) {
    assert(state != NULL);
    memset(state, 0, sizeof(*state));
    for (uint8_t bucket = 0; bucket < CPICOSDK_CLUTCH_BUCKET_COUNT; bucket++) {
        state->buckets[bucket].bucket = bucket;
        state->buckets[bucket].warp_remaining = cpicosdk_xnu_root_bucket_warp_us[bucket];
        state->buckets[bucket].warped_deadline = CPICOSDK_XNU_WARP_UNUSED;
    }
}

void CPICOSDK_XNU_HOT cpicosdk_xnu_clutch_bucket_runnable(
    cpicosdk_xnu_clutch_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us)
{
    assert(state != NULL);
    assert(bucket < CPICOSDK_CLUTCH_BUCKET_COUNT);
    cpicosdk_xnu_clutch_bucket_t *root_bucket = &state->buckets[bucket];
    assert(!root_bucket->runnable);

    root_bucket->runnable = true;
    state->runnable_bitmap |= cpicosdk_xnu_bit(bucket);
    if (!root_bucket->starvation_avoidance) {
        root_bucket->priority_queue_link.deadline =
            cpicosdk_xnu_root_bucket_deadline_calculate(root_bucket, timestamp_us);
    }
    cpicosdk_xnu_priority_queue_insert(
        &state->root_buckets,
        &root_bucket->priority_queue_link,
        true);
    if (root_bucket->warp_remaining != 0u) {
        state->warp_available_bitmap |= cpicosdk_xnu_bit(bucket);
    }
}

void CPICOSDK_XNU_HOT cpicosdk_xnu_clutch_bucket_empty(
    cpicosdk_xnu_clutch_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us)
{
    assert(state != NULL);
    assert(bucket < CPICOSDK_CLUTCH_BUCKET_COUNT);
    cpicosdk_xnu_clutch_bucket_t *root_bucket = &state->buckets[bucket];
    assert(root_bucket->runnable);

    root_bucket->runnable = false;
    state->runnable_bitmap &= (uint8_t)~cpicosdk_xnu_bit(bucket);
    cpicosdk_xnu_priority_queue_remove(&state->root_buckets, &root_bucket->priority_queue_link);
    state->warp_available_bitmap &= (uint8_t)~cpicosdk_xnu_bit(bucket);

    if (root_bucket->warped_deadline != CPICOSDK_XNU_WARP_UNUSED) {
        root_bucket->warp_remaining = root_bucket->warped_deadline > timestamp_us
            ? root_bucket->warped_deadline - timestamp_us
            : 0u;
    }
}

int8_t CPICOSDK_XNU_HOT cpicosdk_xnu_clutch_select(
    cpicosdk_xnu_clutch_state_t *state,
    uint64_t timestamp_us,
    cpicosdk_clutch_selection_reason_t *reason)
{
    assert(state != NULL);
    cpicosdk_xnu_clutch_bucket_t *edf_bucket;

evaluate_root_buckets:
    edf_bucket = cpicosdk_xnu_bucket_for_link(state->root_buckets.root);
    if (edf_bucket == NULL) {
        return CPICOSDK_CLUTCH_NO_BUCKET;
    }

    if (edf_bucket->starvation_avoidance) {
        uint64_t starvation_window = cpicosdk_xnu_thread_quantum_us[edf_bucket->bucket];
        if (timestamp_us >= edf_bucket->starvation_timestamp + starvation_window) {
            edf_bucket->starvation_avoidance = false;
            edf_bucket->starvation_timestamp = 0u;
            cpicosdk_xnu_root_bucket_deadline_update(edf_bucket, state, timestamp_us, true);
            goto evaluate_root_buckets;
        }
    }

    int8_t highest_runnable_bucket = cpicosdk_xnu_bitmap_lsb_first(state->runnable_bitmap);
    int8_t warp_bucket_index = cpicosdk_xnu_bitmap_lsb_first(state->warp_available_bitmap);
    bool non_edf_bucket_can_warp =
        warp_bucket_index != CPICOSDK_CLUTCH_NO_BUCKET &&
        warp_bucket_index < (int8_t)edf_bucket->bucket;

    if (!non_edf_bucket_can_warp) {
        if (!edf_bucket->starvation_avoidance) {
            if (highest_runnable_bucket < (int8_t)edf_bucket->bucket) {
                edf_bucket->starvation_avoidance = true;
                edf_bucket->starvation_timestamp = timestamp_us;
            } else {
                cpicosdk_xnu_root_bucket_deadline_update(edf_bucket, state, timestamp_us, true);
                edf_bucket->warp_remaining = cpicosdk_xnu_root_bucket_warp_us[edf_bucket->bucket];
                edf_bucket->warped_deadline = CPICOSDK_XNU_WARP_UNUSED;
                if (edf_bucket->warp_remaining != 0u) {
                    state->warp_available_bitmap |= cpicosdk_xnu_bit(edf_bucket->bucket);
                }
            }
        }
        if (reason != NULL) {
            *reason = edf_bucket->starvation_avoidance
                ? CPICOSDK_CLUTCH_SELECTION_STARVATION_AVOIDANCE
                : CPICOSDK_CLUTCH_SELECTION_EDF;
        }
        return (int8_t)edf_bucket->bucket;
    }

    assert(warp_bucket_index >= 0);
    cpicosdk_xnu_clutch_bucket_t *warp_bucket = &state->buckets[(uint8_t)warp_bucket_index];
    if (warp_bucket->warped_deadline == CPICOSDK_XNU_WARP_UNUSED) {
        warp_bucket->warped_deadline = timestamp_us + warp_bucket->warp_remaining;
        cpicosdk_xnu_root_bucket_deadline_update(warp_bucket, state, timestamp_us, true);
        if (reason != NULL) {
            *reason = CPICOSDK_CLUTCH_SELECTION_WARP;
        }
        return warp_bucket_index;
    }
    if (warp_bucket->warped_deadline > timestamp_us) {
        cpicosdk_xnu_root_bucket_deadline_update(warp_bucket, state, timestamp_us, true);
        if (reason != NULL) {
            *reason = CPICOSDK_CLUTCH_SELECTION_WARP;
        }
        return warp_bucket_index;
    }

    warp_bucket->warp_remaining = 0u;
    state->warp_available_bitmap &= (uint8_t)~cpicosdk_xnu_bit(warp_bucket->bucket);
    goto evaluate_root_buckets;
}

#endif
