#ifndef SR_MEDIA_QUOTA_H
#define SR_MEDIA_QUOTA_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One shared budget for every SyncRelay-owned media file: group-sync snapshots,
 * message-library media, previews/derived files and in-flight temporary files,
 * across every verified account. SQLite text/metadata and WeChat's own cache are
 * outside this budget. The number is not per type and not per account. */
#define SR_MEDIA_LIMIT_BYTES 268435456ULL /* 256 MiB */

/* Per-object ceiling. A single logical media object may never exceed this even
 * though the shared budget is larger. */
#define SR_MEDIA_SINGLE_FILE_LIMIT_BYTES (20ULL * 1024 * 1024)

/* A temporary file younger than this can belong to a live writer; it is counted
 * but never reclaimed as an interrupted leftover. */
#define SR_MEDIA_TEMPORARY_GRACE_SECONDS 300.0

typedef enum {
    SRMediaStatusOK = 0,
    SRMediaStatusInvalidArgument = 1,
    SRMediaStatusSingleFileExceeded = 2,
    SRMediaStatusQuotaExceeded = 3,
    SRMediaStatusScanUnavailable = 4,
    SRMediaStatusReservationLimit = 5,
} SRMediaStatus;

typedef enum {
    SRMediaLevelNormal = 0,
    SRMediaLevelWarning = 1,
    SRMediaLevelFull = 2,
} SRMediaLevel;

/* Thresholds are ratios, never rounded percentages: a 79.6% usage is not 80%.
 * The reset ratio is a hysteresis band, not a product decision baked into a
 * call site; it is a value callers may override. */
typedef struct {
    uint64_t limit_bytes;
    uint64_t warn_numerator;
    uint64_t warn_denominator;
    uint64_t reset_numerator;
    uint64_t reset_denominator;
} SRMediaPolicy;

SRMediaPolicy SRMediaDefaultPolicy(void); /* 256 MiB, warn at 4/5, reset at 3/4 */
bool SRMediaPolicyIsValid(SRMediaPolicy policy);

typedef struct {
    uint64_t committed_bytes;   /* owned files currently on disk, counted once each */
    uint64_t reserved_bytes;    /* accepted but not yet written or committed */
    uint64_t limit_bytes;
    uint64_t reclaimable_bytes; /* subset of committed that is safe to delete */
    uint64_t file_count;
    bool scan_valid;            /* false: the numbers below are stale, not zero */
} SRMediaSnapshot;

uint64_t SRMediaSnapshotUsedBytes(SRMediaSnapshot snapshot);
uint64_t SRMediaSnapshotRemainingBytes(SRMediaSnapshot snapshot);
SRMediaLevel SRMediaSnapshotLevel(SRMediaSnapshot snapshot, SRMediaPolicy policy);

/* Raise once per upward crossing; clear only after falling back to the reset
 * ratio. Unknown usage never raises or clears. */
typedef enum {
    SRMediaAlertHold = 0,
    SRMediaAlertRaise = 1,
    SRMediaAlertClear = 2,
} SRMediaAlertAction;

SRMediaAlertAction SRMediaAlertStep(bool raised, SRMediaSnapshot snapshot, SRMediaPolicy policy);

typedef struct {
    uint64_t id;
    uint64_t bytes;     /* 0 for an exact-reuse reservation */
    bool reuse_only;
} SRMediaReservation;

/* Serialized reservation ledger. Every check-then-add happens under one mutex,
 * so concurrent importers cannot all pass the same remaining-space test. */
typedef struct SRMediaLedger SRMediaLedger;

SRMediaLedger *SRMediaLedgerCreate(SRMediaPolicy policy);
void SRMediaLedgerDestroy(SRMediaLedger *ledger);

/* Records a completed on-disk scan. Failure must be recorded explicitly so the
 * ledger never reports a made-up zero. */
SRMediaStatus SRMediaLedgerRecordScan(SRMediaLedger *ledger, uint64_t committed_bytes,
                                      uint64_t reclaimable_bytes, uint64_t file_count);
SRMediaStatus SRMediaLedgerRecordScanFailure(SRMediaLedger *ledger);

/* reuse_only marks "these exact bytes are already stored and the caller only
 * needs a reference"; it consumes no budget and is allowed at full quota.
 * shortfall receives the bytes that must be freed before a rejected request
 * would fit. */
SRMediaStatus SRMediaLedgerReserve(SRMediaLedger *ledger, uint64_t bytes, bool reuse_only,
                                   SRMediaReservation *reservation, uint64_t *shortfall);
SRMediaStatus SRMediaLedgerCommit(SRMediaLedger *ledger, uint64_t reservation_id, uint64_t written_bytes);
SRMediaStatus SRMediaLedgerRelease(SRMediaLedger *ledger, uint64_t reservation_id);
SRMediaSnapshot SRMediaLedgerSnapshot(SRMediaLedger *ledger);
bool SRMediaLedgerHasReservation(SRMediaLedger *ledger, uint64_t reservation_id);

#ifdef __cplusplus
}
#endif
#endif
