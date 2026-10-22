#include "Core/SROperationsState.h"
#include <assert.h>
#include <stdio.h>
#include <math.h>
#define APPLY(event) assert(SROpsApply(&s, event, s.generation))
int main(void) {
    SROperationsState s = {0};
    assert(!SROpsVisible(s));
    assert(!SROpsApply(&s, SROpsEnableCommitted, 0));
    SROpsRestore(&s, true, false, SROpsWaiting);
    APPLY(SROpsForeground);
    assert(SROpsVisible(s) && !SROpsCaptureAllowed(s));
    s.sourceVerified = true;
    assert(SROpsCaptureAllowed(s) && !SROpsDispatchAllowed(s));
    uint64_t old = s.generation;
    APPLY(SROpsCandidateCommitted);
    assert(!SROpsApply(&s, SROpsCandidateCommitted, old));
    assert(!SROpsCaptureAllowed(s) && !SROpsDispatchAllowed(s));
    APPLY(SROpsMaterialReady);
    APPLY(SROpsManualStartAccepted);
    assert(SROpsDispatchAllowed(s));
    assert(!SROpsPauseRequired(s, true, false));
    assert(SROpsPauseRequired(s, true, true));
    assert(!SROpsApply(&s, SROpsManualStartAccepted, s.generation));
    APPLY(SROpsBackground);
    assert(!SROpsVisible(s) && !SROpsDispatchAllowed(s));
    APPLY(SROpsForeground);
    assert(!SROpsApply(&s, SROpsManualStartAccepted, s.generation));
    assert(SROpsPauseRequired(s, true, true));
    APPLY(SROpsDrained);
    assert(!SROpsDispatchAllowed(s));
    APPLY(SROpsManualStartAccepted);
    APPLY(SROpsRunCompleted);
    assert(SROpsVisible(s) && !SROpsDispatchAllowed(s) && !SROpsCaptureAllowed(s));
    APPLY(SROpsManualStartAccepted); /* Same content, explicitly selected next group. */
    APPLY(SROpsDisable);
    assert(s.occupied && !SROpsVisible(s) && !SROpsDispatchAllowed(s));
    APPLY(SROpsDrained);
    APPLY(SROpsEnableCommitted);
    assert(s.occupied && !SROpsDispatchAllowed(s));
    APPLY(SROpsContentEndCommitted);
    assert(SROpsVisible(s) && SROpsCaptureAllowed(s));
    old = s.generation;
    APPLY(SROpsConfigurationChanged);
    assert(!SROpsCaptureAllowed(s));
    assert(!SROpsApply(&s, SROpsCandidateCommitted, old));
    SROpsRestore(&s, true, true, SROpsRunning);
    APPLY(SROpsForeground);
    assert(s.phase == SROpsPaused && !SROpsDispatchAllowed(s));
    APPLY(SROpsCancelCommitted);
    assert(s.phase == SROpsCancelling && !SROpsDispatchAllowed(s));
    assert(!SROpsApply(&s, SROpsManualStartAccepted, s.generation));
    assert(!SROpsApply(&s, SROpsContentEndCommitted, s.generation));
    APPLY(SROpsDisable);
    APPLY(SROpsEnableCommitted);
    assert(s.phase == SROpsCancelling);
    SROpsRestore(&s, true, true, SROpsCancelling);
    assert(s.phase == SROpsCancelling && !SROpsDispatchAllowed(s));
    APPLY(SROpsCancelDrained);
    assert(s.phase == SROpsGroupCancelled && s.occupied);
    assert(SROpsNewMessage(101, 100.2, 101.5));
    assert(!SROpsNewMessage(100, 100.2, 101.5));
    assert(!SROpsNewMessage(100.8, 100.2, 101.5));
    assert(!SROpsNewMessage(99, 100.2, 101.5));
    assert(!SROpsNewMessage(102, 100.2, 101.5));
    assert(!SROpsNewMessage(NAN, 100.2, 101.5));
    assert(!SROpsNewMessage(101, INFINITY, 101.5));
    assert(!SROpsNewMessage(101, 0, 101.5));
    assert(!SROpsNewMessage(101, 101, 100));
    APPLY(SROpsAccountInvalidated);
    assert(!s.occupied && !SROpsVisible(s) && !SROpsCaptureAllowed(s));
    SROpsRestore(&s, false, false, SROpsWaiting);
    APPLY(SROpsForeground);
    assert(!SROpsVisible(s));
    /* Exhaustively check policy orthogonality, including completed/fault states. */
    for (unsigned mask = 0; mask < 64; mask++) {
        for (int phase = SROpsWaiting; phase <= SROpsGroupCancelled; phase++) {
            s = (SROperationsState){ .trusted = !!(mask & 1), .enabled = !!(mask & 2),
                .foreground = !!(mask & 4), .occupied = !!(mask & 8),
                .sourceVerified = !!(mask & 16), .fault = !!(mask & 32), .phase = phase };
            assert(SROpsVisible(s) == ((mask & 7) == 7));
            assert(!(SROpsCaptureAllowed(s) && SROpsDispatchAllowed(s)));
            if (!SROpsVisible(s)) assert(!SROpsCaptureAllowed(s) && !SROpsDispatchAllowed(s));
            for (unsigned ready = 0; ready < 2; ready++) {
                for (unsigned deferred = 0; deferred < 2; deferred++) {
                    bool pause = SROpsPauseRequired(s, ready != 0, deferred != 0);
                    assert(pause == (!SROpsVisible(s) || !ready || s.fault || deferred));
                    if (deferred) assert(pause);
                }
            }
        }
    }
    puts("operations state tests passed");
    return 0;
}
