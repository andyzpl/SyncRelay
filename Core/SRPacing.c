#include "SRPacing.h"
#include <math.h>

bool SRPacingConfigure(SRPacing *p, double minimum, double maximum) {
    if (!p || !isfinite(minimum) || !isfinite(maximum) ||
        minimum < 10.0 || maximum < minimum) return false;
    p->minimum = minimum;
    p->maximum = maximum;
    return true;
}

bool SRPacingReady(const SRPacing *p, double now) {
    return p && isfinite(now) && now >= p->next_monotonic && p->minimum >= 10.0;
}

bool SRPacingSubmitted(SRPacing *p, double now, double random) {
    if (!p || !isfinite(now) || !isfinite(random) || random < 0 || random >= 1 ||
        !isfinite(p->minimum) || !isfinite(p->maximum) ||
        p->minimum < 10 || p->maximum < p->minimum) return false;
    double next = now + p->minimum + (p->maximum - p->minimum) * random;
    if (!isfinite(next)) return false;
    p->next_monotonic = next;
    return true;
}

bool SRPacingResume(SRPacing *p, double now, double random) {
    return SRPacingSubmitted(p, now, random);
}

