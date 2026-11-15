/* NarrowArgs's C side (test/mac.sh): built by cc into a library, which
   the raz program links; with -DMAIN, built as a program that prints
   what NarrowArgs.expect holds, so that C itself says what is right. */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

/* A running hash: each value changes every digit after it */
static int64_t mix(int64_t h, int64_t v) { return (int64_t)((uint64_t)h * 1000003u + (uint64_t)v); }

/* Eight integers in x0 to x7; then, on the stack, packed by size as
   Apple's convention has it, i at 0, j at 1, k at 2, l at 4, m at 8, n
   at 16, y at 24, z at 32 and last at 40; the reals p to w in v0 to v7 */
int64_t narrow(int8_t a, uint8_t b, int16_t c, int32_t d, int64_t e, uint8_t f, int16_t g, int32_t h,
               int8_t i, uint8_t j, int16_t k, int32_t l, int8_t m, int64_t n,
               float p, double q, float r, double s, float t, double u, float v, double w,
               float y, double z, int8_t last) {
    int64_t x = 7;
    x = mix(x, a); x = mix(x, b); x = mix(x, c); x = mix(x, d);
    x = mix(x, e); x = mix(x, f); x = mix(x, g); x = mix(x, h);
    x = mix(x, i); x = mix(x, j); x = mix(x, k); x = mix(x, l);
    x = mix(x, m); x = mix(x, n);
    x = mix(x, (int64_t)(p * 4)); x = mix(x, (int64_t)(q * 4));
    x = mix(x, (int64_t)(r * 4)); x = mix(x, (int64_t)(s * 4));
    x = mix(x, (int64_t)(t * 4)); x = mix(x, (int64_t)(u * 4));
    x = mix(x, (int64_t)(v * 4)); x = mix(x, (int64_t)(w * 4));
    x = mix(x, (int64_t)(y * 4)); x = mix(x, (int64_t)(z * 4));
    x = mix(x, last);
    return x;
}

/* A variadic procedure: its arguments past n all go on the stack, each 8 bytes */
int64_t varsum(int n, ...) {
    va_list ap;
    int64_t x = 7;
    int k;
    va_start(ap, n);
    for (k = 0; k < n; k++) {
        if (k % 2 == 0) x = mix(x, va_arg(ap, int)); else x = mix(x, (int64_t)(va_arg(ap, double) * 4));
    }
    va_end(ap);
    return x;
}

/* C calls back a procedure of ten integers, the last two on the stack */
int64_t callback(int64_t (*cb)(int64_t, int64_t, int64_t, int64_t, int64_t,
                               int64_t, int64_t, int64_t, int64_t, int64_t)) {
    return cb(1, -2, 3, -4, 5, -6, 7, -8, 9, -10);
}

#ifdef MAIN
static int64_t mine(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e,
                    int64_t f, int64_t g, int64_t h, int64_t i, int64_t j) {
    int64_t x = 7;
    x = mix(x, a); x = mix(x, b); x = mix(x, c); x = mix(x, d); x = mix(x, e);
    x = mix(x, f); x = mix(x, g); x = mix(x, h); x = mix(x, i); x = mix(x, j);
    return x;
}

int main(void) {
    printf("%lld\n", (long long)narrow(-1, 200, -300, -70000, -5000000000LL, 255, -32768, 2147483647,
                                       -128, 129, -2, -100000, 127, 9000000000LL,
                                       1.5f, -2.25, 3.5f, 4.75, -5.5f, 6.25, 7.5f, -8.75,
                                       9.5f, 10.25, -100));
    printf("%lld\n", (long long)varsum(5, 1, 1.5, -3, -2.25, 5));
    printf("%lld\n", (long long)callback(mine));
    return 0;
}
#endif
