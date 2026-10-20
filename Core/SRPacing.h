#ifndef SR_PACING_H
#define SR_PACING_H
#include <stdbool.h>

typedef struct {
    double minimum;
    double maximum;
    double next_monotonic;
} SRPacing;

bool SRPacingConfigure(SRPacing *pacing, double minimum, double maximum);
bool SRPacingReady(const SRPacing *pacing, double monotonic_now);
/* unit_random must be in [0, 1); callers supply their random source. */
bool SRPacingSubmitted(SRPacing *pacing, double monotonic_now, double unit_random);
/* Resume waits a fresh interval; it never catches up missed ticks. */
bool SRPacingResume(SRPacing *pacing, double monotonic_now, double unit_random);
#endif

