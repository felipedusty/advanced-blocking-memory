| build | round | queries in the reload window | replies >= 10 ms in it | >= 50 ms | worst reply in it (ms) | worst reply in the settle window (ms) | >= 100 ms anywhere |
|---|---|---|---|---|---|---|---|
| `original` | 1 | 12000 | 20 | 0 | 21.9 | 36.5 | 0 |
| `original` | 2 | 12207 | 29 | 0 | 34.9 | 16.8 | 0 |
| `original-gc` | 1 | 12600 | 56 | 22 | 175.7 | 302.9 | 6 |
| `original-gc` | 2 | 12156 | 49 | 21 | 256.3 | 207.2 | 9 |
| `exact-frontcoded-gc` | 1 | 12200 | 2 | 0 | 20.9 | 1.7 | 0 |
| `exact-frontcoded-gc` | 2 | 12200 | 1 | 0 | 19.4 | 2.4 | 0 |
| `hash64-set` | 1 | 12000 | 1 | 0 | 15.3 | 2.0 | 0 |
| `hash64-set` | 2 | 10505 | 2 | 0 | 18.5 | 3.1 | 0 |
| `hash64-index2` | 1 | 11800 | 1 | 0 | 15.3 | 3.3 | 0 |
| `hash64-index2` | 2 | 11800 | 0 | 0 | 3.7 | 9.3 | 0 |
| `exact-tags` | 1 | 11800 | 0 | 0 | 3.7 | 2.5 | 0 |
| `exact-tags` | 2 | 11712 | 1 | 0 | 15.1 | 2.7 | 0 |
