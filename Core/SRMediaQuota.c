#include "SRMediaQuota.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

/* Hard ceiling on simultaneous in-flight reservations. Reached only when a
 * caller leaks reservations; refusing is safer than growing without bound. */
#define SR_MEDIA_RESERVATION_CAPACITY 65536u

typedef struct {
    uint64_t id;
    uint64_t bytes;
    bool reuse_only;
} SRMediaReservationEntry;

struct SRMediaLedger {
    pthread_mutex_t lock;
    SRMediaPolicy policy;
    uint64_t committed_bytes;
    uint64_t reserved_bytes;
    uint64_t reclaimable_bytes;
    uint64_t file_count;
    bool scan_valid;
    uint64_t next_id;
    SRMediaReservationEntry *entries;
    size_t count;
    size_t capacity;
};

SRMediaPolicy SRMediaDefaultPolicy(void) {
    SRMediaPolicy policy;
    policy.limit_bytes = SR_MEDIA_LIMIT_BYTES;
    policy.warn_numerator = 4;
    policy.warn_denominator = 5;
    policy.reset_numerator = 3;
    policy.reset_denominator = 4;
    return policy;
}

bool SRMediaPolicyIsValid(SRMediaPolicy policy) {
    if (policy.limit_bytes == 0) return false;
    if (policy.warn_denominator == 0 || policy.reset_denominator == 0) return false;
    if (policy.warn_numerator == 0 || policy.reset_numerator == 0) return false;
    if (policy.warn_numerator > policy.warn_denominator) return false;
    if (policy.reset_numerator > policy.reset_denominator) return false;
    /* The reset band must be strictly below the warning band, otherwise the
     * reminder would flap on every byte. */
    if (policy.reset_numerator * policy.warn_denominator >=
        policy.warn_numerator * policy.reset_denominator) return false;
    /* Cross-multiplied comparisons must not overflow. */
    uint64_t factors[4] = {policy.warn_numerator, policy.warn_denominator,
                           policy.reset_numerator, policy.reset_denominator};
    for (size_t i = 0; i < 4u; i++)
        if (policy.limit_bytes > UINT64_MAX / factors[i]) return false;
    return true;
}

uint64_t SRMediaSnapshotUsedBytes(SRMediaSnapshot snapshot) {
    if (UINT64_MAX - snapshot.committed_bytes < snapshot.reserved_bytes) return UINT64_MAX;
    return snapshot.committed_bytes + snapshot.reserved_bytes;
}

uint64_t SRMediaSnapshotRemainingBytes(SRMediaSnapshot snapshot) {
    uint64_t used = SRMediaSnapshotUsedBytes(snapshot);
    return snapshot.limit_bytes > used ? snapshot.limit_bytes - used : 0;
}

static uint64_t SRMediaLimit(SRMediaSnapshot snapshot, SRMediaPolicy policy) {
    return snapshot.limit_bytes ? snapshot.limit_bytes : policy.limit_bytes;
}

/* Integer ratio comparison: no floating point, no rounded percentage. */
static SRMediaLevel SRMediaLevelFor(uint64_t used, uint64_t limit, SRMediaPolicy policy) {
    if (limit == 0) return SRMediaLevelFull;
    if (used >= limit) return SRMediaLevelFull;
    if (used * policy.warn_denominator >= limit * policy.warn_numerator) return SRMediaLevelWarning;
    return SRMediaLevelNormal;
}

SRMediaLevel SRMediaSnapshotLevel(SRMediaSnapshot snapshot, SRMediaPolicy policy) {
    if (!SRMediaPolicyIsValid(policy)) return SRMediaLevelFull;
    return SRMediaLevelFor(SRMediaSnapshotUsedBytes(snapshot), SRMediaLimit(snapshot, policy), policy);
}

SRMediaAlertAction SRMediaAlertStep(bool raised, SRMediaSnapshot snapshot, SRMediaPolicy policy) {
    if (!SRMediaPolicyIsValid(policy)) return SRMediaAlertHold;
    /* Never raise or clear from numbers the scan could not confirm. */
    if (!snapshot.scan_valid) return SRMediaAlertHold;
    uint64_t limit = SRMediaLimit(snapshot, policy);
    uint64_t used = SRMediaSnapshotUsedBytes(snapshot);
    if (limit == 0) return SRMediaAlertHold;
    if (!raised) {
        return SRMediaLevelFor(used, limit, policy) == SRMediaLevelNormal
            ? SRMediaAlertHold : SRMediaAlertRaise;
    }
    if (used > UINT64_MAX / policy.reset_denominator) return SRMediaAlertHold;
    return used * policy.reset_denominator <= limit * policy.reset_numerator
        ? SRMediaAlertClear : SRMediaAlertHold;
}

SRMediaLedger *SRMediaLedgerCreate(SRMediaPolicy policy) {
    if (!SRMediaPolicyIsValid(policy)) return NULL;
    SRMediaLedger *ledger = calloc(1, sizeof(*ledger));
    if (!ledger) return NULL;
    if (pthread_mutex_init(&ledger->lock, NULL) != 0) { free(ledger); return NULL; }
    ledger->policy = policy;
    ledger->scan_valid = false;
    return ledger;
}

void SRMediaLedgerDestroy(SRMediaLedger *ledger) {
    if (!ledger) return;
    pthread_mutex_destroy(&ledger->lock);
    free(ledger->entries);
    free(ledger);
}

SRMediaStatus SRMediaLedgerRecordScan(SRMediaLedger *ledger, uint64_t committed_bytes,
                                      uint64_t reclaimable_bytes, uint64_t file_count) {
    if (!ledger) return SRMediaStatusInvalidArgument;
    pthread_mutex_lock(&ledger->lock);
    ledger->committed_bytes = committed_bytes;
    ledger->reclaimable_bytes = reclaimable_bytes;
    ledger->file_count = file_count;
    ledger->scan_valid = true;
    pthread_mutex_unlock(&ledger->lock);
    return SRMediaStatusOK;
}

SRMediaStatus SRMediaLedgerRecordScanFailure(SRMediaLedger *ledger) {
    if (!ledger) return SRMediaStatusInvalidArgument;
    pthread_mutex_lock(&ledger->lock);
    ledger->scan_valid = false;
    pthread_mutex_unlock(&ledger->lock);
    return SRMediaStatusOK;
}

static ssize_t SRMediaFind(const SRMediaLedger *ledger, uint64_t id) {
    for (size_t i = 0; i < ledger->count; i++)
        if (ledger->entries[i].id == id) return (ssize_t)i;
    return -1;
}

static bool SRMediaGrow(SRMediaLedger *ledger) {
    if (ledger->count < ledger->capacity) return true;
    if (ledger->capacity >= SR_MEDIA_RESERVATION_CAPACITY) return false;
    size_t next = ledger->capacity ? ledger->capacity * 2 : 8;
    if (next > SR_MEDIA_RESERVATION_CAPACITY) next = SR_MEDIA_RESERVATION_CAPACITY;
    SRMediaReservationEntry *grown = realloc(ledger->entries, next * sizeof(*grown));
    if (!grown) return false;
    ledger->entries = grown;
    ledger->capacity = next;
    return true;
}

SRMediaStatus SRMediaLedgerReserve(SRMediaLedger *ledger, uint64_t bytes, bool reuse_only,
                                   SRMediaReservation *reservation, uint64_t *shortfall) {
    if (!ledger || !reservation) return SRMediaStatusInvalidArgument;
    if (shortfall) *shortfall = 0;
    if (!reuse_only) {
        if (bytes == 0) return SRMediaStatusInvalidArgument;
        if (bytes > SR_MEDIA_SINGLE_FILE_LIMIT_BYTES) return SRMediaStatusSingleFileExceeded;
    }
    SRMediaStatus status = SRMediaStatusOK;
    pthread_mutex_lock(&ledger->lock);
    /* The whole check-then-add runs under the ledger lock: two importers cannot
     * both observe the same remaining space and both be admitted. */
    if (!reuse_only) {
        if (!ledger->scan_valid) {
            status = SRMediaStatusScanUnavailable;
        } else {
            uint64_t used = ledger->committed_bytes + ledger->reserved_bytes;
            if (used < ledger->committed_bytes) used = UINT64_MAX; /* saturate */
            uint64_t limit = ledger->policy.limit_bytes;
            uint64_t remaining = limit > used ? limit - used : 0;
            if (bytes > remaining) {
                if (shortfall) *shortfall = bytes - remaining;
                status = SRMediaStatusQuotaExceeded;
            }
        }
    }
    if (status == SRMediaStatusOK && !SRMediaGrow(ledger)) status = SRMediaStatusReservationLimit;
    if (status == SRMediaStatusOK) {
        if (ledger->next_id == UINT64_MAX) {
            status = SRMediaStatusReservationLimit;
        } else {
            uint64_t id = ++ledger->next_id;
            ledger->entries[ledger->count].id = id;
            ledger->entries[ledger->count].bytes = reuse_only ? 0 : bytes;
            ledger->entries[ledger->count].reuse_only = reuse_only;
            ledger->count += 1;
            if (!reuse_only) ledger->reserved_bytes += bytes;
            reservation->id = id;
            reservation->bytes = reuse_only ? 0 : bytes;
            reservation->reuse_only = reuse_only;
        }
    }
    pthread_mutex_unlock(&ledger->lock);
    return status;
}

SRMediaStatus SRMediaLedgerCommit(SRMediaLedger *ledger, uint64_t reservation_id, uint64_t written_bytes) {
    if (!ledger) return SRMediaStatusInvalidArgument;
    SRMediaStatus status = SRMediaStatusInvalidArgument;
    pthread_mutex_lock(&ledger->lock);
    ssize_t index = SRMediaFind(ledger, reservation_id);
    if (index >= 0) {
        SRMediaReservationEntry entry = ledger->entries[index];
        /* A write can never exceed what it reserved; anything else is a bug and
         * must not silently inflate the committed total. */
        if (written_bytes <= entry.bytes) {
            uint64_t used = ledger->committed_bytes + written_bytes;
            ledger->committed_bytes = used < ledger->committed_bytes ? UINT64_MAX : used;
            ledger->reserved_bytes = ledger->reserved_bytes >= entry.bytes
                ? ledger->reserved_bytes - entry.bytes : 0;
            ledger->entries[index] = ledger->entries[ledger->count - 1];
            ledger->count -= 1;
            status = SRMediaStatusOK;
        }
    }
    pthread_mutex_unlock(&ledger->lock);
    return status;
}

SRMediaStatus SRMediaLedgerRelease(SRMediaLedger *ledger, uint64_t reservation_id) {
    if (!ledger) return SRMediaStatusInvalidArgument;
    SRMediaStatus status = SRMediaStatusInvalidArgument;
    pthread_mutex_lock(&ledger->lock);
    ssize_t index = SRMediaFind(ledger, reservation_id);
    if (index >= 0) {
        uint64_t bytes = ledger->entries[index].bytes;
        ledger->reserved_bytes = ledger->reserved_bytes >= bytes
            ? ledger->reserved_bytes - bytes : 0;
        ledger->entries[index] = ledger->entries[ledger->count - 1];
        ledger->count -= 1;
        status = SRMediaStatusOK;
    }
    pthread_mutex_unlock(&ledger->lock);
    return status;
}

bool SRMediaLedgerHasReservation(SRMediaLedger *ledger, uint64_t reservation_id) {
    if (!ledger) return false;
    pthread_mutex_lock(&ledger->lock);
    bool found = SRMediaFind(ledger, reservation_id) >= 0;
    pthread_mutex_unlock(&ledger->lock);
    return found;
}

SRMediaSnapshot SRMediaLedgerSnapshot(SRMediaLedger *ledger) {
    SRMediaSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    if (!ledger) return snapshot;
    pthread_mutex_lock(&ledger->lock);
    snapshot.committed_bytes = ledger->committed_bytes;
    snapshot.reserved_bytes = ledger->reserved_bytes;
    snapshot.limit_bytes = ledger->policy.limit_bytes;
    snapshot.reclaimable_bytes = ledger->reclaimable_bytes;
    snapshot.file_count = ledger->file_count;
    snapshot.scan_valid = ledger->scan_valid;
    pthread_mutex_unlock(&ledger->lock);
    return snapshot;
}
