#ifndef SR_CAPSULE_GEOMETRY_H
#define SR_CAPSULE_GEOMETRY_H
#include <stdbool.h>
#include <math.h>

/* A 44pt control contains a fixed 22 x 90pt visible handle. Horizontal
 * placement uses the physical window edge, never the inset capsule bounds. */
static inline double SRCapsuleHandleOriginX(double windowWidth, bool left) {
    return left ? 0 : windowWidth - 44.0;
}
static inline double SRCapsuleHandleSurfaceX(bool left) { return left ? 0 : 22.0; }
static inline bool SRCapsuleRestoresInward(double translation, bool left) {
    return isfinite(translation) && (left ? translation > 14.0 : translation < -14.0);
}

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
