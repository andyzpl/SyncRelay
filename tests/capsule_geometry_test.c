#include "UI/SRCapsuleGeometry.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(SRCapsuleDockSide(20, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(240, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(-8, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(268, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(-9, 20, 240, true, false) == -1);
    assert(SRCapsuleDockSide(269, 20, 240, true, false) == 1);
    assert(SRCapsuleDockSide(130, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(300, 20, 240, false, false) == 0);
    assert(SRCapsuleDockSide(300, 20, 240, true, true) == 0);
    assert(SRCapsuleDockSide(NAN, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(INFINITY, 20, 240, true, false) == 0);
    assert(SRCapsuleDockSide(300, 240, 20, true, false) == 0);
    puts("PASS: capsule edge docking requires explicit ended outward overshoot; restoration is display-only");
    return 0;
}
