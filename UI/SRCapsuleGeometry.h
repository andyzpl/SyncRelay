#ifndef SR_CAPSULE_GEOMETRY_H
#define SR_CAPSULE_GEOMETRY_H
#include <stdbool.h>
#include <math.h>

// Display-only docking decision. Touching an edge, cancelled drags and the
// inward restoration gesture never request a new dock operation.
static inline int SRCapsuleDockSide(double desiredX, double minimumX, double maximumX,
                                    bool ended, bool startedDocked) {
    if (!ended || startedDocked || !isfinite(desiredX) || !isfinite(minimumX) ||
        !isfinite(maximumX) || maximumX < minimumX) return 0;
    if (desiredX < minimumX - 28.0) return -1;
    if (desiredX > maximumX + 28.0) return 1;
    return 0;
}
#endif
