original, start of session : startup 292.2  anon 262.1  reload 468.8 MiB
original, end of session   : startup 297.4  anon 259.1  reload 434.8 MiB
reference original         : startup 294.8  anon 260.6  reload 451.8 MiB

| candidate | lines + / - | startup peak | steady anon | reload peak | anon ratio | startup ratio | reload ratio | p50 (paired) | qps (paired) | 500 reports |
|---|---|---|---|---|---|---|---|---|---|---|
| exact-tags | +160 / -27 | 111.7 | 84.0 | 226.7 | 3.10x | 2.64x | 1.99x | 214.9 vs 207.5 µs (+3.6%) | 3446 vs 3562 (-3.2%, overlap) | identical to hash64-set (the original was not queried) |
| hash64-index2 | +101 / -32 | 72.1 | 46.1 | 143.7 | 5.65x | 4.09x | 3.15x | 205.6 vs 206.3 µs (-0.3%) | 3601 vs 3537 (+1.8%, no overlap) | identical to hash64-set (the original was not queried) |
| hash64-set | +56 / -32 | 106.0 | 79.5 | 211.6 | 3.28x | 2.78x | 2.14x | 207.0 vs 206.6 µs (+0.2%) | 3470 vs 3582 (-3.1%, overlap) | identical to hash64-set (the original was not queried) |
