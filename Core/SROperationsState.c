#include "SROperationsState.h"
#include <math.h>

bool SROpsVisible(SROperationsState s) { return s.trusted && s.enabled && s.foreground; }
bool SROpsCaptureAllowed(SROperationsState s) {
    return SROpsVisible(s) && !s.occupied && s.sourceVerified && !s.fault;
}
bool SROpsDispatchAllowed(SROperationsState s) {
    return SROpsVisible(s) && s.occupied && s.phase == SROpsRunning && !s.fault;
}
bool SROpsPauseRequired(SROperationsState s, bool configurationReady, bool lifecyclePending) {
    return !SROpsVisible(s) || !configurationReady || s.fault || lifecyclePending;
}
static void stop(SROperationsState *s) {
    s->generation++;
    if (s->phase == SROpsRunning) s->phase = SROpsDraining;
}
void SROpsRestore(SROperationsState *s, bool enabled, bool occupied, SROpsPhase phase) {
    uint64_t next = s->generation + 1;
    *s = (SROperationsState){ .trusted = true, .enabled = enabled,
        .occupied = occupied, .generation = next,
        .phase = occupied ? phase : SROpsWaiting };
    if (s->phase == SROpsRunning || s->phase == SROpsDraining) s->phase = SROpsPaused;
}
bool SROpsNewMessage(double createdAt, double listeningSince, double receivedAt) {
    return isfinite(createdAt) && isfinite(listeningSince) && isfinite(receivedAt) &&
        createdAt > 0 && listeningSince > 0 && receivedAt >= listeningSince &&
        floor(createdAt) > floor(listeningSince) && createdAt <= receivedAt;
}
bool SROpsApply(SROperationsState *s, SROpsEvent event, uint64_t generation) {
    if (!s || generation != s->generation) return false;
    switch (event) {
        case SROpsEnableCommitted:
            if (!s->trusted) return false;
            s->enabled = true; s->generation++; break;
        case SROpsDisable: s->enabled = false; stop(s); break;
        case SROpsForeground: s->foreground = true; break;
        case SROpsBackground: s->foreground = false; stop(s); break;
        case SROpsAccountInvalidated:
            stop(s); s->trusted = false; s->enabled = false;
            s->occupied = false; s->phase = SROpsWaiting;
            s->sourceVerified = false; s->fault = false; break;
        case SROpsConfigurationChanged: s->generation++; s->sourceVerified = false; break;
        case SROpsCandidateCommitted:
            if (!SROpsCaptureAllowed(*s)) return false;
            s->occupied = true; s->phase = SROpsPreparing; s->generation++; break;
        case SROpsMaterialReady:
            if (!s->trusted || !s->occupied || s->phase != SROpsPreparing) return false;
            s->phase = SROpsReady; break;
        case SROpsManualStartAccepted:
            if (!SROpsVisible(*s) || !s->occupied || s->fault ||
                (s->phase != SROpsReady && s->phase != SROpsPaused &&
                 s->phase != SROpsGroupCompleted && s->phase != SROpsGroupCancelled)) return false;
            s->phase = SROpsRunning; break;
        case SROpsPause:
            if (s->phase != SROpsRunning) return false;
            stop(s); break;
        case SROpsDrained:
            if (s->phase != SROpsDraining) return false;
            s->phase = SROpsPaused; break;
        case SROpsRunCompleted:
            if (!s->occupied || (s->phase != SROpsRunning && s->phase != SROpsDraining)) return false;
            s->phase = SROpsGroupCompleted; break;
        case SROpsContentEndCommitted:
            if (!s->occupied || s->phase == SROpsRunning || s->phase == SROpsDraining || s->phase == SROpsCancelling) return false;
            s->occupied = false; s->phase = SROpsContentCompleted; s->generation++; break;
        case SROpsCancelCommitted:
            if (!s->occupied || (s->phase != SROpsRunning && s->phase != SROpsDraining && s->phase != SROpsPaused)) return false;
            s->phase = SROpsCancelling; s->generation++; break;
        case SROpsCancelDrained:
            if (!s->occupied || s->phase != SROpsCancelling) return false;
            s->phase = SROpsGroupCancelled; break;
        default: return false;
    }
    return true;
}
