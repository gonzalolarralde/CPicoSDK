#ifndef CPICOSDK_SCHEDULER_POLICIES_H
#define CPICOSDK_SCHEDULER_POLICIES_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    CPICOSDK_CLUTCH_BUCKET_COUNT = 5,
    CPICOSDK_CLUTCH_NO_BUCKET = -1,
};

typedef enum {
    CPICOSDK_CLUTCH_SELECTION_EDF = 0,
    CPICOSDK_CLUTCH_SELECTION_WARP = 1,
    CPICOSDK_CLUTCH_SELECTION_STARVATION_AVOIDANCE = 2,
} cpicosdk_clutch_selection_reason_t;

/*
 * A compact, clean-room representation of XNU Clutch's root timeshare
 * policy. Bucket indices are ordered from highest (0) to lowest (4)
 * priority. Timestamps and policy windows are expressed in microseconds.
 */
typedef struct {
    uint64_t deadline[CPICOSDK_CLUTCH_BUCKET_COUNT];
    uint64_t warp_remaining[CPICOSDK_CLUTCH_BUCKET_COUNT];
    uint64_t warped_deadline[CPICOSDK_CLUTCH_BUCKET_COUNT];
    uint64_t starvation_timestamp[CPICOSDK_CLUTCH_BUCKET_COUNT];
    uint8_t runnable_bitmap;
    uint8_t warp_available_bitmap;
    uint8_t starvation_bitmap;
} cpicosdk_clutch_lite_state_t;

void cpicosdk_clutch_lite_init(cpicosdk_clutch_lite_state_t *state);
void cpicosdk_clutch_lite_bucket_runnable(
    cpicosdk_clutch_lite_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us);
void cpicosdk_clutch_lite_bucket_empty(
    cpicosdk_clutch_lite_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us);
int8_t cpicosdk_clutch_lite_select(
    cpicosdk_clutch_lite_state_t *state,
    uint64_t timestamp_us,
    cpicosdk_clutch_selection_reason_t *reason);

/*
 * The source-derived declarations below deliberately keep XNU's pairing-heap
 * shape. They are modified from osfmk/kern/priority_queue.h and the Clutch
 * root-bucket representation in osfmk/kern/sched_clutch.c at XNU commit
 * f6217f891ac0bb64f3d375211650a4c1ff8ca1ea. The public layout makes the
 * policy allocation-free on bare metal and lets deterministic host tests
 * inspect invariants without test-only allocation.
 *
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
 *
 * CPicoSDK modifications, 2026-08-01: the XNU types were renamed, reduced
 * to the fields needed by the five-bucket experiment, and exposed as a
 * fixed-size freestanding C representation.
 */
typedef struct cpicosdk_xnu_priority_queue_entry_deadline {
    struct cpicosdk_xnu_priority_queue_entry_deadline *next;
    struct cpicosdk_xnu_priority_queue_entry_deadline *prev;
    long child;
    uint64_t deadline;
} cpicosdk_xnu_priority_queue_entry_deadline_t;

typedef struct {
    cpicosdk_xnu_priority_queue_entry_deadline_t *root;
} cpicosdk_xnu_priority_queue_deadline_min_t;

typedef struct {
    cpicosdk_xnu_priority_queue_entry_deadline_t priority_queue_link;
    uint64_t warp_remaining;
    uint64_t warped_deadline;
    uint64_t starvation_timestamp;
    uint8_t bucket;
    bool starvation_avoidance;
    bool runnable;
} cpicosdk_xnu_clutch_bucket_t;

typedef struct {
    cpicosdk_xnu_priority_queue_deadline_min_t root_buckets;
    cpicosdk_xnu_clutch_bucket_t buckets[CPICOSDK_CLUTCH_BUCKET_COUNT];
    uint8_t runnable_bitmap;
    uint8_t warp_available_bitmap;
} cpicosdk_xnu_clutch_state_t;

void cpicosdk_xnu_clutch_init(cpicosdk_xnu_clutch_state_t *state);
void cpicosdk_xnu_clutch_bucket_runnable(
    cpicosdk_xnu_clutch_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us);
void cpicosdk_xnu_clutch_bucket_empty(
    cpicosdk_xnu_clutch_state_t *state,
    uint8_t bucket,
    uint64_t timestamp_us);
int8_t cpicosdk_xnu_clutch_select(
    cpicosdk_xnu_clutch_state_t *state,
    uint64_t timestamp_us,
    cpicosdk_clutch_selection_reason_t *reason);

#ifdef __cplusplus
}
#endif

#endif
