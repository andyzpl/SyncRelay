#ifndef SR_OPERATIONS_STATE_H
#define SR_OPERATIONS_STATE_H
#include <stdbool.h>
#include <stdint.h>

/* Value-only coordinator policy. No event can invoke a sender. Persistence and
 * host effects must succeed before their corresponding event is applied. */
typedef enum {
    SROpsWaiting, SROpsPreparing, SROpsReady, SROpsRunning,
    SROpsDraining, SROpsPaused, SROpsGroupCompleted, SROpsContentCompleted,
    SROpsCancelling, SROpsGroupCancelled
} SROpsPhase;
typedef struct {
    bool trusted, enabled, foreground, occupied, sourceVerified, fault;
    uint64_t generation;
    SROpsPhase phase;
} SROperationsState;
typedef enum {
    SROpsEnableCommitted, SROpsDisable, SROpsForeground, SROpsBackground,
    SROpsAccountInvalidated, SROpsConfigurationChanged,
    SROpsCandidateCommitted, SROpsMaterialReady, SROpsManualStartAccepted,
    SROpsPause, SROpsDrained, SROpsRunCompleted, SROpsContentEndCommitted,
    SROpsCancelCommitted, SROpsCancelDrained
} SROpsEvent;
bool SROpsVisible(SROperationsState state);
bool SROpsCaptureAllowed(SROperationsState state);
bool SROpsDispatchAllowed(SROperationsState state);
/* Stale asynchronous events are rejected; lifecycle events use current token. */
bool SROpsApply(SROperationsState *state, SROpsEvent event, uint64_t generation);
/* On process restoration a running task is always manual-resume only. */
void SROpsRestore(SROperationsState *state, bool enabled, bool occupied, SROpsPhase phase);
/* Adapter evidence, never callback arrival time. Same-second/old/invalid times
 * fail closed; image preparation must retain the original receive evidence. */
bool SROpsNewMessage(double createdAt, double listeningSince, double receivedAt);
#endif
