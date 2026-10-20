#include "Core/SRPacing.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    SRPacing pacing = {0};
    assert(!SRPacingConfigure(&pacing, 9, 20));
    assert(!SRPacingConfigure(&pacing, 20, 10));
    assert(!SRPacingConfigure(&pacing, NAN, 20));
    assert(!SRPacingConfigure(&pacing, 10, INFINITY));
    assert(SRPacingConfigure(&pacing, 10, 20));
    assert(SRPacingSubmitted(&pacing, 100, 0));
    assert(!SRPacingReady(&pacing, 109.99));
    assert(SRPacingReady(&pacing, 110));
    assert(SRPacingSubmitted(&pacing, 110, 0.5));
    assert(pacing.next_monotonic == 125);
    assert(!SRPacingSubmitted(&pacing, 110, 1));
    assert(!SRPacingSubmitted(&pacing, NAN, 0));
    assert(SRPacingResume(&pacing, 10000, 0.5));
    assert(!SRPacingReady(&pacing, 10000));
    assert(pacing.next_monotonic == 10015);
    assert(SRPacingConfigure(&pacing, 10, 10));
    assert(SRPacingSubmitted(&pacing, 0, 0.9));
    assert(pacing.next_monotonic == 10);
    for (int i = 0; i < 2000; i++) {
        assert(SRPacingConfigure(&pacing, 10, 20));
        double now = i * 20.0;
        assert(SRPacingSubmitted(&pacing, now, i / 2000.0));
        assert(pacing.next_monotonic - now >= 10);
        assert(pacing.next_monotonic - now < 20);
    }
    puts("PASS: pacing bounds, fixed intervals, resume and 2000 samples");
    return 0;
}
