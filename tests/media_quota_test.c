/* Pure C tests for the shared media budget: thresholds, reservation ordering,
 * concurrency, rollback and reminder hysteresis. No filesystem, no Foundation. */
#include "Core/SRMediaQuota.h"

#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define MIB (1024ULL * 1024ULL)

static SRMediaSnapshot SRSnapshot(uint64_t committed, uint64_t reserved, uint64_t limit, bool valid) {
    SRMediaSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    snapshot.committed_bytes = committed;
    snapshot.reserved_bytes = reserved;
    snapshot.limit_bytes = limit ? limit : SR_MEDIA_LIMIT_BYTES;
    snapshot.scan_valid = valid;
    return snapshot;
}

static void test_policy_and_thresholds(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    assert(policy.limit_bytes == 268435456ULL);
    assert(policy.limit_bytes == 256ULL * 1024ULL * 1024ULL);
    assert(policy.warn_numerator == 4 && policy.warn_denominator == 5);
    assert(policy.reset_numerator == 3 && policy.reset_denominator == 4);
    assert(SRMediaPolicyIsValid(policy));

    /* A per-type or per-account budget would be a different number; the single
     * shared ceiling is the contract. */
    assert(SR_MEDIA_SINGLE_FILE_LIMIT_BYTES == 20ULL * 1024ULL * 1024ULL);
    assert((uint64_t)SR_MEDIA_SINGLE_FILE_LIMIT_BYTES < policy.limit_bytes);

    SRMediaPolicy inverted = policy;
    inverted.reset_numerator = 4;    /* reset == warn is not a band */
    inverted.reset_denominator = 5;
    assert(!SRMediaPolicyIsValid(inverted));
    SRMediaPolicy zero = policy;
    zero.limit_bytes = 0;
    assert(!SRMediaPolicyIsValid(zero));
    SRMediaPolicy zero_denominator = policy;
    zero_denominator.warn_denominator = 0;
    assert(!SRMediaPolicyIsValid(zero_denominator));

    /* Exact byte boundaries, not rounded percentages: 256 MiB * 4/5 is
     * 214748364.8, so 214748364 is still below and 214748365 is at/above. */
    const uint64_t below = 214748364ULL, at = 214748365ULL;
    assert(SRMediaSnapshotLevel(SRSnapshot(below, 0, 0, true), policy) == SRMediaLevelNormal);
    assert(SRMediaSnapshotLevel(SRSnapshot(at, 0, 0, true), policy) == SRMediaLevelWarning);
    assert(SRMediaSnapshotLevel(SRSnapshot(policy.limit_bytes - 1, 0, 0, true), policy) == SRMediaLevelWarning);
    assert(SRMediaSnapshotLevel(SRSnapshot(policy.limit_bytes, 0, 0, true), policy) == SRMediaLevelFull);
    assert(SRMediaSnapshotLevel(SRSnapshot(policy.limit_bytes + 1, 0, 0, true), policy) == SRMediaLevelFull);

    /* Pending bytes count as used: a reservation must not look like free space. */
    assert(SRMediaSnapshotLevel(SRSnapshot(at - 1000, 1000, 0, true), policy) == SRMediaLevelWarning);
    assert(SRMediaSnapshotUsedBytes(SRSnapshot(100, 20, 0, true)) == 120);
    assert(SRMediaSnapshotRemainingBytes(SRSnapshot(100, 20, 1000, true)) == 880);
    assert(SRMediaSnapshotRemainingBytes(SRSnapshot(1000, 20, 1000, true)) == 0);

    /* A 79.6% reading must not be rounded up into a warning. */
    uint64_t nearly = policy.limit_bytes * 796 / 1000;
    assert(nearly < below && SRMediaSnapshotLevel(SRSnapshot(nearly, 0, 0, true), policy) == SRMediaLevelNormal);
}

static void test_reserve_paths(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    SRMediaLedger *ledger = SRMediaLedgerCreate(policy);
    assert(ledger);
    SRMediaReservation reservation;
    uint64_t shortfall = 0;

    /* No scan yet: refusal, never "assume empty". */
    assert(SRMediaLedgerReserve(ledger, MIB, false, &reservation, &shortfall) == SRMediaStatusScanUnavailable);
    assert(SRMediaLedgerSnapshot(ledger).scan_valid == false);

    assert(SRMediaLedgerRecordScan(ledger, 0, 0, 0) == SRMediaStatusOK);
    assert(SRMediaLedgerReserve(ledger, 0, false, &reservation, &shortfall) == SRMediaStatusInvalidArgument);
    assert(SRMediaLedgerReserve(ledger, SR_MEDIA_SINGLE_FILE_LIMIT_BYTES + 1, false, &reservation, &shortfall)
        == SRMediaStatusSingleFileExceeded);

    /* Not full, but the new object does not fit: exact shortfall, no state change. */
    assert(SRMediaLedgerRecordScan(ledger, policy.limit_bytes - 100, 0, 1) == SRMediaStatusOK);
    shortfall = 0;
    assert(SRMediaLedgerReserve(ledger, 1000, false, &reservation, &shortfall) == SRMediaStatusQuotaExceeded);
    assert(shortfall == 900);
    assert(SRMediaLedgerSnapshot(ledger).reserved_bytes == 0);

    /* Exactly the remaining space still fits. */
    assert(SRMediaLedgerReserve(ledger, 100, false, &reservation, &shortfall) == SRMediaStatusOK);
    assert(SRMediaLedgerSnapshot(ledger).reserved_bytes == 100);

    /* Full quota refuses every new byte and reports what to free. */
    assert(SRMediaLedgerRecordScan(ledger, policy.limit_bytes, 0, 1) == SRMediaStatusOK);
    shortfall = 0;
    assert(SRMediaLedgerReserve(ledger, 1, false, &reservation, &shortfall) == SRMediaStatusQuotaExceeded);
    assert(shortfall == 1);

    /* Full quota still allows exact reuse: it adds no byte. */
    SRMediaReservation reuse;
    assert(SRMediaLedgerReserve(ledger, 1024, true, &reuse, &shortfall) == SRMediaStatusOK);
    assert(reuse.reuse_only && reuse.bytes == 0);
    assert(SRMediaLedgerSnapshot(ledger).reserved_bytes == 100); /* unchanged by reuse */
    assert(SRMediaLedgerCommit(ledger, reuse.id, 0) == SRMediaStatusOK);

    /* Reuse at full quota must still fail if the caller lies about bytes. */
    assert(SRMediaLedgerRecordScanFailure(ledger) == SRMediaStatusOK);

    SRMediaLedgerDestroy(ledger);
}

static void test_commit_and_rollback(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    SRMediaLedger *ledger = SRMediaLedgerCreate(policy);
    assert(ledger);
    assert(SRMediaLedgerRecordScan(ledger, 5 * MIB, MIB, 3) == SRMediaStatusOK);
    SRMediaReservation reservation;
    uint64_t shortfall = 0;

    /* Successful write: reservation becomes committed bytes. */
    assert(SRMediaLedgerReserve(ledger, MIB, false, &reservation, &shortfall) == SRMediaStatusOK);
    assert(SRMediaLedgerCommit(ledger, reservation.id, MIB) == SRMediaStatusOK);
    SRMediaSnapshot after = SRMediaLedgerSnapshot(ledger);
    assert(after.committed_bytes == 6 * MIB && after.reserved_bytes == 0);
    assert(!SRMediaLedgerHasReservation(ledger, reservation.id));
    assert(SRMediaLedgerCommit(ledger, reservation.id, MIB) == SRMediaStatusInvalidArgument);

    /* Failed write: release returns every reserved byte and changes nothing. */
    assert(SRMediaLedgerReserve(ledger, MIB, false, &reservation, &shortfall) == SRMediaStatusOK);
    assert(SRMediaLedgerSnapshot(ledger).reserved_bytes == MIB);
    assert(SRMediaLedgerRelease(ledger, reservation.id) == SRMediaStatusOK);
    SRMediaSnapshot rolled = SRMediaLedgerSnapshot(ledger);
    assert(rolled.reserved_bytes == 0 && rolled.committed_bytes == 6 * MIB);
    assert(SRMediaLedgerRelease(ledger, reservation.id) == SRMediaStatusInvalidArgument);

    /* A write can never exceed what it reserved. */
    assert(SRMediaLedgerReserve(ledger, MIB, false, &reservation, &shortfall) == SRMediaStatusOK);
    assert(SRMediaLedgerCommit(ledger, reservation.id, MIB + 1) == SRMediaStatusInvalidArgument);
    SRMediaSnapshot unchanged = SRMediaLedgerSnapshot(ledger);
    assert(unchanged.reserved_bytes == MIB && unchanged.committed_bytes == 6 * MIB);
    assert(SRMediaLedgerRelease(ledger, reservation.id) == SRMediaStatusOK);

    SRMediaLedgerDestroy(ledger);
}

static void test_scan_failure_is_not_zero(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    SRMediaLedger *ledger = SRMediaLedgerCreate(policy);
    assert(ledger);
    assert(SRMediaLedgerRecordScan(ledger, 42 * MIB, 0, 7) == SRMediaStatusOK);
    assert(SRMediaLedgerRecordScanFailure(ledger) == SRMediaStatusOK);
    SRMediaSnapshot snapshot = SRMediaLedgerSnapshot(ledger);
    assert(snapshot.scan_valid == false);
    /* The last known total survives; the caller must not read it as current. */
    assert(snapshot.committed_bytes == 42 * MIB);
    SRMediaReservation reservation;
    uint64_t shortfall = 0;
    assert(SRMediaLedgerReserve(ledger, MIB, false, &reservation, &shortfall) == SRMediaStatusScanUnavailable);
    /* Reuse still works: it needs no measurement to prove it adds no byte. */
    assert(SRMediaLedgerReserve(ledger, MIB, true, &reservation, &shortfall) == SRMediaStatusOK);
    SRMediaLedgerDestroy(ledger);
}

#define SR_WORKER_THREADS 8
#define SR_WORKER_ROUNDS 32
#define SR_WORKER_BYTES MIB

typedef struct {
    SRMediaLedger *ledger;
    int granted;
    int refused;
    uint64_t ids[SR_WORKER_ROUNDS];
} SRWorkerBox;

static void *SRReserveWorker(void *raw) {
    SRWorkerBox *box = raw;
    for (int i = 0; i < SR_WORKER_ROUNDS; i++) {
        SRMediaReservation reservation;
        uint64_t shortfall = 0;
        if (SRMediaLedgerReserve(box->ledger, SR_WORKER_BYTES, false, &reservation, &shortfall) == SRMediaStatusOK)
            box->ids[box->granted++] = reservation.id;
        else
            box->refused++;
    }
    return NULL;
}

static void test_concurrent_reservations(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    SRMediaLedger *ledger = SRMediaLedgerCreate(policy);
    assert(ledger);
    assert(SRMediaLedgerRecordScan(ledger, 0, 0, 0) == SRMediaStatusOK);

    /* 8 * 32 * 1 MiB == 256 MiB: exactly the budget, so exactly 256 succeed no
     * matter how the threads interleave, and never a byte more. */
    SRWorkerBox boxes[SR_WORKER_THREADS];
    pthread_t threads[SR_WORKER_THREADS];
    memset(boxes, 0, sizeof(boxes));
    for (int i = 0; i < SR_WORKER_THREADS; i++) {
        boxes[i].ledger = ledger;
        assert(pthread_create(&threads[i], NULL, SRReserveWorker, &boxes[i]) == 0);
    }
    int granted = 0, refused = 0;
    for (int i = 0; i < SR_WORKER_THREADS; i++) {
        assert(pthread_join(threads[i], NULL) == 0);
        granted += boxes[i].granted;
        refused += boxes[i].refused;
    }
    assert(granted == 256);
    assert(refused == 0);
    SRMediaSnapshot snapshot = SRMediaLedgerSnapshot(ledger);
    assert(snapshot.reserved_bytes == policy.limit_bytes);
    assert(SRMediaSnapshotUsedBytes(snapshot) == policy.limit_bytes);

    /* One byte more must be refused with an exact shortfall. */
    SRMediaReservation extra;
    uint64_t shortfall = 0;
    assert(SRMediaLedgerReserve(ledger, 1, false, &extra, &shortfall) == SRMediaStatusQuotaExceeded);
    assert(shortfall == 1);

    for (int i = 0; i < SR_WORKER_THREADS; i++)
        for (int j = 0; j < boxes[i].granted; j++)
            assert(SRMediaLedgerRelease(ledger, boxes[i].ids[j]) == SRMediaStatusOK);
    assert(SRMediaLedgerSnapshot(ledger).reserved_bytes == 0);
    assert(SRMediaLedgerReserve(ledger, SR_WORKER_BYTES, false, &extra, &shortfall) == SRMediaStatusOK);
    assert(SRMediaLedgerRelease(ledger, extra.id) == SRMediaStatusOK);

    SRMediaLedgerDestroy(ledger);
}

static void test_alert_hysteresis(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    const uint64_t below = 214748364ULL;      /* just under 80% */
    const uint64_t at = 214748365ULL;         /* first byte at/above 80% */
    const uint64_t reset = policy.limit_bytes * 3 / 4; /* exactly 75% */

    assert(SRMediaAlertStep(false, SRSnapshot(below, 0, 0, true), policy) == SRMediaAlertHold);
    assert(SRMediaAlertStep(false, SRSnapshot(at, 0, 0, true), policy) == SRMediaAlertRaise);
    assert(SRMediaAlertStep(true, SRSnapshot(at, 0, 0, true), policy) == SRMediaAlertHold);
    /* Inside the band: still raised, but nothing new to present. */
    assert(SRMediaAlertStep(true, SRSnapshot(reset + 1, 0, 0, true), policy) == SRMediaAlertHold);
    /* Falling back to the reset ratio clears, then the next crossing may raise. */
    assert(SRMediaAlertStep(true, SRSnapshot(reset, 0, 0, true), policy) == SRMediaAlertClear);
    assert(SRMediaAlertStep(false, SRSnapshot(reset, 0, 0, true), policy) == SRMediaAlertHold);
    assert(SRMediaAlertStep(false, SRSnapshot(at, 0, 0, true), policy) == SRMediaAlertRaise);

    /* An adjustable policy: warning at half, reset at one quarter. */
    SRMediaPolicy tight = policy;
    tight.warn_numerator = 1;
    tight.warn_denominator = 2;
    tight.reset_numerator = 1;
    tight.reset_denominator = 4;
    assert(SRMediaPolicyIsValid(tight));
    assert(SRMediaAlertStep(false, SRSnapshot(policy.limit_bytes / 2, 0, 0, true), tight) == SRMediaAlertRaise);
    assert(SRMediaAlertStep(true, SRSnapshot(policy.limit_bytes / 4 + 1, 0, 0, true), tight) == SRMediaAlertHold);
    assert(SRMediaAlertStep(true, SRSnapshot(policy.limit_bytes / 4, 0, 0, true), tight) == SRMediaAlertClear);

    /* Unknown usage neither raises nor clears. */
    assert(SRMediaAlertStep(false, SRSnapshot(at, 0, 0, false), policy) == SRMediaAlertHold);
    assert(SRMediaAlertStep(true, SRSnapshot(0, 0, 0, false), policy) == SRMediaAlertHold);
}

static void test_reservation_capacity(void) {
    SRMediaPolicy policy = SRMediaDefaultPolicy();
    SRMediaLedger *ledger = SRMediaLedgerCreate(policy);
    assert(ledger);
    assert(SRMediaLedgerRecordScan(ledger, 0, 0, 0) == SRMediaStatusOK);
    /* Zero-byte reuse reservations are cheap but still bounded. */
    uint64_t granted = 0;
    for (int i = 0; i < 200; i++) {
        SRMediaReservation reservation;
        if (SRMediaLedgerReserve(ledger, 1, true, &reservation, NULL) == SRMediaStatusOK) granted++;
    }
    assert(granted == 200);
    assert(SRMediaLedgerSnapshot(ledger).reserved_bytes == 0);
    SRMediaLedgerDestroy(ledger);
}

int main(void) {
    test_policy_and_thresholds();
    test_reserve_paths();
    test_commit_and_rollback();
    test_scan_failure_is_not_zero();
    test_concurrent_reservations();
    test_alert_hysteresis();
    test_reservation_capacity();
    printf("PASS: shared media budget thresholds, reservations, concurrency, rollback and reminder hysteresis\n");
    return 0;
}
