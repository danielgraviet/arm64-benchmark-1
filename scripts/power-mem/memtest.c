/* memtest.c - STREAM-style triad (a = b + s*c) for one vCPU inside a sandbox.
 * usage: memtest N_ELEMENTS SECONDS      prints one JSON line.
 * Bytes per pass use the STREAM convention: 3 arrays x N x 8 bytes (2 reads + 1 write; write-allocate traffic not counted).
 * Times are CLOCK_MONOTONIC per pass; t_start/t_end are CLOCK_REALTIME epoch seconds so concurrent runs can be aligned. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double mono(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static double wall(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : (1L << 25);
    double secs = argc > 2 ? atof(argv[2]) : 20.0;
    double *a = aligned_alloc(64, n * sizeof(double)), *b = aligned_alloc(64, n * sizeof(double)), *c = aligned_alloc(64, n * sizeof(double));
    if (!a || !b || !c) { printf("{\"error\":\"alloc failed\",\"n\":%ld}\n", n); return 2; }
    for (long i = 0; i < n; i++) { a[i] = 1.0; b[i] = 2.0; c[i] = 0.5; }
    const double s = 3.0;
    for (long i = 0; i < n; i++) a[i] = b[i] + s * c[i];          /* warm pass, not timed */
    double ws = wall(), t0 = mono(), tend = t0 + secs, best = 1e30; long passes = 0;
    while (mono() < tend) {
        double t = mono();
        for (long i = 0; i < n; i++) a[i] = b[i] + s * c[i];
        t = mono() - t; if (t < best) best = t;
        passes++;
        double *x = b; b = c; c = x;                                /* rotate so the data changes every pass */
    }
    double total = mono() - t0, we = wall(), chk = 0;
    for (long i = 0; i < n; i += 4096) chk += a[i];
    double bytes = 3.0 * n * sizeof(double);
    printf("{\"task\":\"memtest-triad-v1\",\"n\":%ld,\"array_mib\":%.0f,\"passes\":%ld,\"duration_ms\":%.1f,"
           "\"mean_gbs\":%.3f,\"best_gbs\":%.3f,\"t_start\":%.3f,\"t_end\":%.3f,\"checksum\":%.6g}\n",
           n, n * 8.0 / 1048576, passes, total * 1e3, passes * bytes / total / 1e9, bytes / best / 1e9, ws, we, chk);
    return 0;
}
