# Jobs per watt

sampler: # domains=rapl_pkg_all wall=none cpufreq=no host=vedran-test (adapted from gapfill sampler)

Idle (88 samples): processor_w 178 W

| level | jobs/s | failures | processor_w (W) | jobs/s per processor W ×1000 | J per job (processor) | J per job above idle | busy-core GHz | busy CPUs |
|---|---|---|---|---|---|---|---|---|
| 44 | 5.5 | 0 | 599 | 9.2 | 108.9 | 76.5 | nan | nan |
| 88 | 10.58 | 0 | 858 | 12.3 | 81.1 | 64.3 | nan | nan |
| 176 | 17.86 | 0 | 968 | 18.5 | 54.2 | 44.2 | nan | nan |
| 352 | 20.15 | 0 | 936 | 21.5 | 46.4 | 37.6 | nan | nan |
| 528 | 22.32 | 0 | 955 | 23.4 | 42.8 | 34.8 | nan | nan |
| 704 | 22.27 | 0 | 972 | 22.9 | 43.6 | 35.6 | nan | nan |
| 880 | 22.25 | 0 | 974 | 22.8 | 43.8 | 35.7 | nan | nan |
| 1056 | 22.17 | 0 | 967 | 22.9 | 43.6 | 35.6 | nan | nan |
| 1408 | 22.12 | 0 | 973 | 22.7 | 44.0 | 35.9 | nan | nan |
| 1760 | 22.13 | 0 | 974 | 22.7 | 44.0 | 35.9 | nan | nan |
| 2000 | 22.15 | 0 | 977 | 22.7 | 44.1 | 36.0 | nan | nan |

processor_w = Vera 'AP Power' (both sockets) or AMD RAPL package (both sockets); module_w = Vera 'Total Power' incl. on-module memory; wall_w = BMC reading if available. Confirm the Vera domain definitions before quoting; AMD RAPL excludes DRAM.
