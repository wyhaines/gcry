# Sunlight tic-build, 2026-11-20

Sunlight uses tic-build to turn insurers’ negotiated-rate tables into price
files organized by billing code. Each Crystal worker keeps table indexes live
while it builds short-lived records and writes intermediate files. A coordinator
collects the results.

All five runs used the same prepared tables and 25 selected codes, Crystal
1.22.3 release builds, two workers, four in-flight requests, CPUs 8–15 on one
Linux x86-64 host, a 52 GiB cgroup limit and no swap. The table gives the runs
in execution order. There was one run per gcry configuration. The gcry parent
already includes the finalizer index and large free-list changes.

| Collector | Wall (s) | Coordinator peak RSS (GiB) | Settled coordinator RSS (GiB) | Mean job memory (GiB) | Peak job memory (GiB) |
|---|---:|---:|---:|---:|---:|
| Boehm opening | 3599.5 | 10.969 | 10.9673 | 16.843 | 23.039 |
| gcry parent (`d8bbc363`) | 5123.1 | 14.604 | 6.7869 | 13.464 | 29.564 |
| Refill only (`c758b92a`) | 3471.7 | 14.588 | 6.7837 | 16.167 | 33.247 |
| Refill and IO (`316f21cf`) | 3367.1 | 15.939 | 6.9719 | 14.805 | 33.852 |
| Boehm closing | 3553.6 | 10.651 | 10.6465 | 16.507 | 20.938 |

Coordinator peaks are one-second RSS samples. The kernel recorded a 14.800 GiB
high-water mark for refill only. Settled RSS is the median of five-minute
window medians after the first ten minutes. Whole-job memory is cgroup usage
and includes file cache. All four comparisons against the opening control matched on 8,821
files. Of those, 8,818 were byte-identical and three matched after normalizing
run paths and timing fields.

The refill change cut 1,651 seconds from this run. Adding the IO change cut
another 105 seconds, raised the coordinator and whole-job peaks, and lowered
mean job memory. These measurements apply to the revisions shown.
