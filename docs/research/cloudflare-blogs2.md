# Cloudflare blog, full-text sweep #2: compact sets, filters and bytes per domain

Research note, 2026-11-02. Read-only investigation. This file is the *second* pass over
`blog.cloudflare.com`; the first pass is `docs/research-cloudflare.md` (tag-page sweep, 167
posts, plus ~24 named posts read in full). Nothing here is duplicated from that file except
one item that was marked UNVERIFIED there and is now verified (§3.4).

Every factual claim carries the URL I actually opened. Numbers in quotes are the blog's own.
Anything I derived by arithmetic is labelled **[ARITH]**, anything I inferred is
**[INFERENCE]**. Nothing was benchmarked by me except where stated.

---

## 0. What this pass adds

1. **Coverage is now complete by construction, not by tag page.** I enumerated the blog from
   its sitemap (8,077 `<loc>` entries → **3,686 distinct posts**, 2009–2026), downloaded all
   of them as text (41 MB), and ran a fixed regex battery over the whole corpus. The first
   pass could only see the latest 18 posts of each tag page; this pass sees every post ever
   published. §1 is the method, §2 is the audit table of every candidate the battery raised.
2. **The closest thing Cloudflare has published to a per-customer DNS set at the edge is a
   counting Bloom filter** — Advanced DNS Protection builds one per Magic Transit customer
   from observed query names and ships it to every server (§3.1). This is new material and it
   is the most directly relevant thing in the whole corpus.
3. **Cloudflare benchmarked three perfect-hashing crates against a plain branchless
   direct-index table and the perfect hashes lost** (§3.2, 2024). That is direct evidence
   against the MPHF direction the first pass left open (its R7).
4. **Quicksilver v1 is a sorted-key mmap B+tree (LMDB), and Cloudflare published its failure
   modes with numbers**: 1.5×–80× write amplification, "1 megabyte … consumes at least 10
   gigabytes globally", `SIGBUS` when a mapped page hits an I/O error (§3.3). This is the
   strongest argument yet *against* backing our block list with any COW/paged store.
5. **Negatives are now evidence, not absence of search**: `Roaring` appears once in 3,686
   posts and it is the phrase "the Roaring Twenties"; `xor filter`, `ribbon filter`,
   `quotient filter`, `binary fuse` appear **zero** times; `front coding`/`dictionary
   encoding` zero; `FST` once (the post already analysed). §4 lists the full ledger.
6. **Three new ideas ranked at the end** (§7): a two-pass hash-bucketed build that removes
   the 2× reload peak, 6-bit alphabet compaction of the name arena, and the append-only /
   never-COW artifact rule with its numbers.

---

## 1. Method

### 1.1 Enumeration

| Step | What | Result |
|---|---|---|
| `https://blog.cloudflare.com/sitemap.xml` | sitemap index | 5 post sitemaps + archives + authors + tags |
| `sitemap-posts{,-2,-3,-4,-5}.xml` | `<loc>` union | **8,077** URL entries |
| de-duplication by final path segment | language mirrors (`/ja-jp/…`, `/de-de/…`, 20 locales) collapse | **3,686** distinct posts |
| `sitemap-archives.xml` | 21 entries | only the 21 language homepages — there is **no** monthly archive sitemap |
| publish date | `article:published_time` meta tag | 2009-04-28 to 2026-10-30 (2 posts 2009, 299 posts 2026) |

Errors: the first crawl (12 workers) hit HTTP 429 on 327 URLs; a retry at 3 workers with
backoff fetched all of them. Final corpus: 3,686 files, 41 MB of extracted text.

### 1.2 Extraction

`<article>` element only, tags stripped, whitespace collapsed, `URL/DATE/TITLE` header line
prepended. Language editions share a slug, so one file per slug survives; where the surviving
copy was a translation I re-fetched the English page (done for `radar-domain-rankings` and
`quicksilver-v2-…-part-2-of-2`). One file (`shared-dictionaries`) is the Japanese machine
translation; no number from it is used below.

### 1.3 Query battery (fixed, run over the whole corpus)

Filters, rejectors and membership: `roaring`, `bit-?map`, `bitset|bit set`, `bloom filter`,
`cuckoo`, `xor filter|ribbon filter|quotient filter|binary fuse`, `fingerprint`, `perfect
hash|mphf|minimal perfect`, `succinct|rank/select|elias-fano|wavelet`, `trie|radix
tree|patricia`, `finite state transducer|\bfst\b`, `false positive`, `probabilistic`,
`hyperloglog|\bhll\b`, `count-min sketch|\bcm sketch\b|ams sketch|t-digest`, `hash ?table`,
`open address|linear prob`, `hash ?set`.

Layouts and bytes: `bytes? per (entry|key|item|record|row|element|domain)`, `per-entry`,
`footprint`, `resident|\brss\b`, `struct packing|\bu8\b|\bu16\b|\bu32\b|bit-?pack`,
`sorted array|binary search|merge-sort`, `sstable|lsm tree|b-?tree`, `columnar`, `front-cod|
dictionary encod`, `intern(ing|ed)`, `mmap|zero-copy`, `compress|zstd|brotli|snappy`, `dedup`.

Domain/set semantics: `suffix|parent domain|wildcard`, `block ?list|deny ?list|allow
?list|domain categor`, `list of (domains|hostnames|urls)`, `set intersection|jaccard|minhash`,
`punycode|idna|internationalized domain`, `cache key`.

A document scoring ≥8 over these classes was read; the score is a discovery aid only, verdicts
below come from reading.

### 1.4 Secondary: web search

Ten `site:blog.cloudflare.com` variants were run (roaring bitmap; "bytes per entry" memory;
memory footprint data structure; HyperLogLog; Quicksilver LMDB; compressing lists of IP
prefixes; xor/cuckoo/ribbon; deduplication billions of records; Radar top domains; "perfect
hash"/"succinct"/"fst"). **Their recall was poor**: most queries returned the same one or two
posts (usually `dns-cache-memory-optimization-1111`), and several returned only tag pages.
The corpus grep found every post that the search engine found, plus ~60 it did not. Search was
used only to seed candidate names (e.g. `moving-quicksilver-into-production`,
`making-waf-ai-models-go-brr`), never as evidence.

### 1.5 Exclusion rule

Posts already analysed in `research-cloudflare.md` §2–§6 are **not** re-analysed here. The
only reintroduced one is §3.4 (previously UNVERIFIED, now read).

---

## 2. Candidate posts examined

`F` = read the relevant sections in full; `S` = screened from full text by the battery, verdict
from the passage that matched. All dates are the post's publish date.

| Date | Post | Depth | Verdict (one line) |
|---|---|---|---|
| 2024-03-07 | [Advanced DNS Protection](https://blog.cloudflare.com/advanced-dns-protection) | F | **yes** — per-customer counting Bloom on DNS query names, shipped to every edge server |
| 2024-07-25 | [Making WAF ML models go brrr](https://blog.cloudflare.com/making-waf-ai-models-go-brr) | F | **yes** — perfect-hash crates benchmarked and rejected; alphabet compaction + dense index |
| 2020-03-30 | [Introducing Quicksilver](https://blog.cloudflare.com/introducing-quicksilver-configuration-distribution-at-internet-scale) | F | **yes** — v1 = LMDB, sorted keys, mmap, multi-process, append-only |
| 2020-11-25 | [Moving Quicksilver into production](https://blog.cloudflare.com/moving-quicksilver-into-production) | F | **yes** — write amplification 1.5–80×, 1 MB → 30 MB flushed, SIGBUS on mmap I/O error |
| 2025-07-17 | [Quicksilver v2, part 2](https://blog.cloudflare.com/quicksilver-v2-evolution-of-a-globally-distributed-key-value-store-part-2-of-2) | F | **yes** — 5 B pairs / 1.6 TB; full-copy-per-server abandoned; random-subset shards |
| 2021-10-14 | [Privacy-Preserving Compromised Credential Checking](https://blog.cloudflare.com/privacy-preserving-compromised-credential-checking) | F | **yes** — hash-prefix bucketing, 20-bit → 2^20 buckets, 25 MB bucket cap (was UNVERIFIED) |
| 2017-05-10 | [How Cloudflare analyzes 1M DNS queries/s](https://blog.cloudflare.com/how-cloudflare-analyzes-1m-dns-queries-per-second) | F | **yes** — HLL 20–100 B/row vs 8 B counter; query names do not aggregate (0–60× row reduction) |
| 2020-03-24 | [Why we started putting unpopular assets in memory](https://blog.cloudflare.com/why-we-started-putting-unpopular-assets-in-memory) | F | **yes** — why Bloom/counting-Bloom/CM-sketch admission filters were rejected ("missed at least twice") |
| 2018-03-05 | [Squeezing the firehose: Kafka compression](https://blog.cloudflare.com/squeezing-the-firehose) | F | partial — measured gzip/lz4/snappy on log records (1594 B → 455 B avg) |
| 2022-09-02 | [Log analytics using ClickHouse](https://blog.cloudflare.com/log-analytics-using-clickhouse) | F | partial — 600 B/row (Elasticsearch doc) → 60 B/row; columnar+sorted |
| 2026-09-01 | [Saving petabytes of cache storage with Zstandard](https://blog.cloudflare.com/cache-transcoding) | F | partial — zstd on stored objects; 11.3 % smaller than gzip at comparable speed |
| 2025-04-11 | [Azul certificate transparency log](https://blog.cloudflare.com/azul-certificate-transparency-log) | F | partial — intern the low-cardinality dimension, store only its hash |
| 2022-02-17 | [Production ready eBPF / tubular](https://blog.cloudflare.com/tubular-fixing-the-socket-api-with-ebpf) | F | partial — LPM map, and the "encode precedence into the key" trick |
| 2023-11-15 | [Hostname and ASN lists](https://blog.cloudflare.com/hostname-asn-lists) | F | partial — list semantics are exact-host + `*` wildcard, *not* suffix inheritance |
| 2023-07-24 | [Trending domains on Radar](https://blog.cloudflare.com/radar-trending-domains) | F | no — popularity is an ML estimate over aggregates; no stored structure |
| 2022-09-30 | [Radar Domain Rankings](https://blog.cloudflare.com/radar-domain-rankings) | F | no — same; "popularity = estimated relative size of the user population" |
| 2015-04-09 | [Scaling out PostgreSQL with CitusDB](https://blog.cloudflare.com/scaling-out-postgresql-for-cloudflare-analytics-using-citusdb) | S | no — HLL mentioned as a Postgres extension, no sizing |
| 2021-03-12 | [Lessons from Anomaly Detection](https://blog.cloudflare.com/lessons-learned-from-scaling-up-cloudflare-anomaly-detection-platform) | S | no — HLL in Redis, sparse→dense trade, no byte figures |
| 2023-03-03 | [How Cloudflare runs Prometheus at scale](https://blog.cloudflare.com/how-cloudflare-runs-prometheus-at-scale) | S | no — cardinality as an ops problem, not a structure |
| 2022-05-12 | [Workers Analytics Engine](https://blog.cloudflare.com/workers-analytics-engine) | S | no — "unlimited cardinality" as a product claim, no layout |
| 2022-09-30 | [Don't roll your own high-cardinality analytics](https://blog.cloudflare.com/analytics-engine-open-beta) | S | no — ditto |
| 2017-06-07 | [Rate limiting to millions of domains](https://blog.cloudflare.com/counting-things-a-lot-of-different-things) | F | no — consistent-hashed Twemproxy shards + leaky bucket, no set structure |
| 2017-09-26 | [Geo Key Manager: how it works](https://blog.cloudflare.com/geo-key-manager-how-it-works) | S | no — allow/deny sets are cryptographic (IBBE/IBR), not stored tables |
| 2022-05-25 | [DNS record build 4,000× faster](https://blog.cloudflare.com/dns-build-improvement) | S | no — build *speed* of zone records, not a compact layout |
| 2018-08-09 | [Optimising caching on Pwned Passwords](https://blog.cloudflare.com/optimising-caching-on-pwnedpasswords) | S | no — cache-key design for a prefix API |
| 2020-03-04 | [Pwned Passwords padding](https://blog.cloudflare.com/pwned-passwords-padding-ft-lava-lamps-and-workers) | S | no — padding to hide bucket sizes, not memory |
| 2019-11-06 | [What's new with Workers KV](https://blog.cloudflare.com/whats-new-with-workers-kv) | S | no — bulk upload/list API |
| 2018-09-28 | [Introducing Workers KV](https://blog.cloudflare.com/introducing-workers-kv) | S | no — product intro |
| 2024-09-26 | [Workers KV up to 3× faster](https://blog.cloudflare.com/faster-workers-kv) | S | no — latency work, no per-key bytes |
| 2025-08-08 | [Redesigning Workers KV](https://blog.cloudflare.com/rearchitecting-workers-kv-for-redundancy) | S | no — redundancy/consistency, no structure |
| 2026-10-01 | [Workers KV Instant, powered by Quicksilver](https://blog.cloudflare.com/workers-kv-instant) | S | no — push-based distribution, no layout |
| 2026-07-06 | [Your Worker can now have its own cache](https://blog.cloudflare.com/workers-cache) | S | no — cache key semantics per entrypoint |
| 2026-09-22 | [We just shipped Vary](https://blog.cloudflare.com/vary-support) | S | no — cache-key explosion / variant handling |
| 2026-10-13 | [How D1 scales to millions of databases](https://blog.cloudflare.com/d1-control-plane) | S | no — control plane, not storage layout |
| 2025-09-25 | [R2 SQL deep dive](https://blog.cloudflare.com/r2-sql-deep-dive) | S | no — query engine |
| 2024-10-22 | [Building Vectorize](https://blog.cloudflare.com/building-vectorize-a-distributed-vector-database-on-cloudflare-developer-platform) | S | no — vector index, not set membership |
| 2026-05-14 | [ClickHouse query-plan contention](https://blog.cloudflare.com/clickhouse-query-plan-contention) | S | no — planner CPU |
| 2025-07-08 | [TimescaleDB for analytics](https://blog.cloudflare.com/timescaledb-art) | S | no — columnar compression of metrics |
| 2023-09-26 | [Radar Internet-outage detection](https://blog.cloudflare.com/detecting-internet-outages) | S | no — false-positive rates on signals |
| 2022-09-05 | [WAF data augmentation and sampling](https://blog.cloudflare.com/data-generation-and-sampling-strategies) | S | no — ML sampling |
| 2026-03-04 | [Attack-signature detection](https://blog.cloudflare.com/attack-signature-detection) | S | no — detections, not data structures |
| 2023-05-25 | [Unbounded memory in TCP receive buffers](https://blog.cloudflare.com/unbounded-memory-usage-by-tcp-for-receive-buffers-and-how-we-fixed-it) | S | no — kernel buffer tuning |
| 2025-09-25 | [Node.js compatibility in Workers](https://blog.cloudflare.com/nodejs-workers-2025) | S | no — runtime memory, not our shape |
| 2026-10-20 | [tsrs: TypeScript ported to Rust](https://blog.cloudflare.com/typescript-rust-port) | S | no — compiler performance |
| 2025-09-26 | [Eliminating cold starts 2](https://blog.cloudflare.com/eliminating-cold-starts-2-shard-and-conquer) | S | no — isolate placement |
| 2024-09-26 | [Making Workers AI faster (KV-cache compression)](https://blog.cloudflare.com/making-workers-ai-faster) | S | no — attention KV cache, different problem |
| 2026-03-23 | [Gen 13 servers: trading cache for cores](https://blog.cloudflare.com/gen13-launch) | S | no — hardware ratios |
| 2019-01-15 | [Serverless platforms (video)](https://blog.cloudflare.com/single-process-serverless) | S | no — talk abstract |
| 2026-07-30 | [Migrating cdnjs](https://blog.cloudflare.com/cdnjs-dev-platform-migration) | S | no — migration story |
| 2024-10-31 | [Baselime move to Cloudflare](https://blog.cloudflare.com/80-percent-lower-cloud-cost-how-baselime-moved-from-aws-to-cloudflare) | S | no — cost migration |
| 2024-04-05 | [Cloudflare acquires Baselime](https://blog.cloudflare.com/cloudflare-acquires-baselime-expands-observability-capabilities) | S | no — acquisition |
| 2026-03-03 | [Threat Intelligence Platform](https://blog.cloudflare.com/cloudflare-threat-intelligence-platform) | F | no — thousands of SQLite shards on DOs, no per-row cost |
| 2025-03-20 | [Aegis deep dive](https://blog.cloudflare.com/aegis-deep-dive) | S | no — allowlist of IPs for origin access |
| 2022-03-16 | [Friendly Bots](https://blog.cloudflare.com/friendly-bots) | S | no — verification process, list of IPs |
| 2019-12-18 | [CSAM scanning tool](https://blog.cloudflare.com/the-csam-scanning-tool) | S | no — fuzzy hashes (PhotoDNA) via partner API, no local set |
| 2016-03-30 | [The Trouble with Tor](https://blog.cloudflare.com/the-trouble-with-tor) | S | no — exit-node list used as signal |
| 2017-01-09 | [The Porcupine Attack](https://blog.cloudflare.com/the-porcupine-attack-investigating-millions-of-junk-requests) | S | no — one "bytes per" hit is about request size |
| 2019-06-20 | [Introducing CIRCL](https://blog.cloudflare.com/introducing-circl) | S | no — crypto library |
| 2022-02-21 | [The quantum solace and spectre](https://blog.cloudflare.com/quantum-solace-and-spectre) | S | no — PQ crypto |
| 2025-09-25 | [Safe in the sandbox](https://blog.cloudflare.com/safe-in-the-sandbox-security-hardening-for-cloudflare-workers) | S | no — wasm sandbox |
| 2020-10-27 | [Diving into /proc/[pid]/mem](https://blog.cloudflare.com/diving-into-proc-pid-mem) | S | no — memory forensics |
| 2022-12-15 | [AS112 project](https://blog.cloudflare.com/the-as112-project) | S | no — anycast service |
| 2018-12-12 | [More consistent LuaJIT performance](https://blog.cloudflare.com/more-consistent-luajit-performance) | S | no — "radix" hits are GC/allocator |
| 2020-09-30 | [Introducing Cloudflare Radar](https://blog.cloudflare.com/introducing-cloudflare-radar) | S | no — product intro, no storage |
| 2025-10-27 | [TLD insights on Radar](https://blog.cloudflare.com/introducing-tld-insights-on-cloudflare-radar) | S | no — TLD popularity, no structure |
| 2022-06-29 | [Live-patching with eBPF LSM](https://blog.cloudflare.com/live-patch-security-vulnerabilities-with-ebpf-lsm) | S | no — "LSM" false positive (Linux Security Module) |
| 2017-05-12 | [Detroit and San Diego data centers](https://blog.cloudflare.com/detroit-san-diego) | S | no — the only "Roaring" in 3,686 posts is "the Roaring Twenties" |
| 2026-04-17 | [Shared Dictionaries](https://blog.cloudflare.com/shared-dictionaries) | S | no numbers used (only the JA translation was in corpus) |

Cross-check on posts the first pass already covered (not re-analysed, listed so the reader can
see what the corpus query also hit): `when-bloom-filters-dont-bloom` (2020-03-02),
`brotli-compression-using-a-reduced-dictionary` (2020-11-11), `how-pingora-keeps-count`
(2023-05-12), `dns-cache-memory-optimization-1111` (2026-08-27), `saving-100-tb-of-ram-with-math`
(2026-09-18), `a-deep-dive-into-bpf-lpm-trie-performance-and-optimization` (2025-10-21),
`pingora-saving-compute-1-percent-at-a-time` (2024-09-10), `magic-firewall-optimizing-ip-lists`
(2022-03-29), `scalable-machine-learning-at-cloudflare` (2023-06-19),
`quicksilver-v2-…-part-1` (2025-07-10), `how-we-made-our-dns-stack-3x-faster` (2017-04-11),
`migrating-billions-of-records…` (2024-10-29), `introducing-ip-lists` (2020-07-22),
`agent-registry` (2025-10-30), `egress-policies-by-hostname` (2025-07-07),
`validating-leaked-passwords-with-k-anonymity` (2018-02-21).

---

## 3. The relevant finds

### 3.1 Advanced DNS Protection: a counting Bloom filter per customer, on DNS names

<https://blog.cloudflare.com/advanced-dns-protection>, 2024-03-07.

**Structure.** For Magic Transit customers, every edge server streams DNS query metadata
(query type, queried name — "but not the source of the query") to core data centres; core
computes a *traffic profile per customer* and ships it back to the whole fleet, where it is
consulted at packet-processing time:

> "To solve this challenge, we decided to use a counting Bloom filter for each customer's
> traffic profile. This is a probabilistic data structure that allows us to succinctly store
> and distribute each customer's DNS profile, and then efficiently query it at packet
> processing time."

**Numbers the post gives.** "tens of millions of DNS queries per day" for some customers;
profiles are distributed through R2 and "98% of the bits transferred are served from cache".
**No bit counts, no false-positive rate, no bytes per name.**

**Exactness.** Probabilistic, and the post is explicit that false positives are unavoidable —
newly registered names are absent from the profile by construction. Their mitigation is
architectural rather than structural:

> "…this and other reasons for potential false positives mandate that we need to build a
> certain amount of tolerance into the system… We do so by leveraging token bucket algorithms.
> Customers can configure the size of the token buckets by changing the sensitivity levels."

Also relevant to us: Magic Transit uses direct server return, so "we can not see the DNS origin
server's responses" — there is no feedback loop to catch a wrong profile.

**Transfer.** This is a *precedent*, not a design to copy: Cloudflare already runs a
per-customer probabilistic name filter at the edge, sizes it by tolerance rather than by a
target FPR, and ships it as an immutable blob to every server. For a **block** list the
asymmetry inverts (a false positive blocks a legitimate site) which is exactly why the
upstream proposal must argue for exactness (or a filter used only as a *rejector* in front of
an exact table, as `DomainSet` already does). New, citable sentence for the proposal: Cloudflare's
own DNS-set product at the edge is a counting Bloom plus a tolerance budget — not an exact set —
and it is per-customer, so the fleet-wide category list path is not described here either.

### 3.2 WAF ML preprocessing: perfect hashing loses to a dense direct index

<https://blog.cloudflare.com/making-waf-ai-models-go-brr>, 2024-07-25.

**Problem.** Tokenise request bytes into 3-byte n-grams and map each to a tensor index, for
thousands of distinct n-grams, on every request. Baseline: `HashMap` lookups = 61.8 % of
preprocessing time.

**What they tried, with numbers** (same benchmark cases: 44 B URL, 91 B UA, 1000 B body,
9482 B body; µs):

| Version | long-9482 | avg-body-1000 | avg-url-44 | avg-ua-91 |
|---|---|---|---|---|
| baseline `HashMap` | 248.46 | 28.19 | 1.45 | 2.87 |
| Aho-Corasick (DFA) | 129.59 | 16.47 | 1.01 | 1.90 |
| generated `match` | 112.96 | 13.12 | 0.75 | 1.41 |
| branchless direct index | **21.53** | **2.33** | **0.26** | **0.43** |

Crates that the generated `match` beat — the post says "with benchmarks omitted for brevity":

> "`phf` crate — A library to generate efficient lookup tables at compile time using perfect
> hash functions. `ph` crate — Another Rust library of data structures based on perfect
> hashing. `quickphf` crate — … static compile-time generated hash maps and hash sets using
> PTHash perfect hash functions."

**The winning structure.** Three tables, all small: for each of the three byte positions, a
`NGRAM_OFFSETS[3][256]` mapping a byte to its rank among the bytes actually used; then one
dense array `NGRAM_TENSOR_IDX[N*N*N]` of `u16`, indexed by the sum of the three ranks:

> "…the memory footprint of used lookup arrays is tiny – just ~500 KiB of memory – which easily
> fits into modern CPU L2/L3 caches."

So the key set is *compacted to its own alphabet* and then addressed arithmetically — no hash,
no fingerprints, no comparisons.

**Exactness.** Exact.

**Transfer to us.**
- Direct evidence for the first pass's conclusion that an MPHF is not worth adopting (its R7):
  Cloudflare's own measurement is that three perfect-hash implementations were slower than the
  branchless alternative. Add this as a citation where the proposal currently says "no
  perfect hashing".
- The *useful* half is **alphabet compaction**: a domain-name alphabet is ~39 symbols
  (`a–z`, `0–9`, `-`, `.`, `_`), i.e. 6 bits, and the rank table is 256 bytes. That is a
  size idea even though Cloudflare only used it for speed — see §7 N2.
- The 500 KiB figure is a useful scale reminder: their *entire* index fits in L2/L3. Ours
  cannot (2.46 M keys), so anything that trades a cache-resident index for a bigger one is
  going the wrong way for us.

### 3.3 Quicksilver v1 = LMDB: the sorted-key mmap store, and why it stopped scaling

Three posts, one design.

**v1 layout** — <https://blog.cloudflare.com/introducing-quicksilver-configuration-distribution-at-internet-scale>,
2020-03-30. LMDB chosen after "extensive analysis of different options" because it gives
consistent running snapshots, is "optimized for low read latency rather than write
throughput", and:

> "LMDB also allows multiple processes to concurrently access the same datastore. This is very
> useful for implementing zero downtime upgrades… LMDB is also append-only, meaning it only
> writes new data, it doesn't overwrite existing data. Beyond that, nothing is ever written to
> disk in a state which could be considered corrupted. This makes it crash-proof."

Scale: "tens of millions of reads per second across thousands of machines"; switching from
Kyoto Tycoon cut "the 99th percentile of reads… by two orders of magnitude".

**What went wrong** — <https://blog.cloudflare.com/moving-quicksilver-into-production>,
2020-11-25:

| Problem | The post's number |
|---|---|
| copy-on-write page amplification | "when Quicksilver wrote 1 megabyte, 30 megabytes were flushed to disk"; "amplification factors between 1.5X and 80X" |
| full copy everywhere | "Each and every server in Cloudflare stores the same data. So a piece of data one megabyte in size consumes at least 10 gigabytes globally." |
| mmap + I/O error | "LMDB maps the database file into memory and when the kernel experiences an I/O error while accessing the SSD, it will terminate Quicksilver with a SIGBUS" |
| page-cache thrashing | parallel bootstrap "overwhelmed swapping pages"; readahead had to be **disabled** because it "started evicting useful pages" |

**v2** — <https://blog.cloudflare.com/quicksilver-v2-evolution-of-a-globally-distributed-key-value-store-part-2-of-2>,
2025-07-17: "over five billion key-value pairs with a combined size of 1.6 TB" **[ARITH: ≈320 B
per pair, key + value, on disk]**; V1.5 "halved the disk space used on each server" by making
some instances cache-only proxies; the final design keeps the full set on "a handful of servers
with large disks" and gives everyone else a cache, then reintroduces sharding:

> "shards are well-balanced due to the fact that they contain uniform random subsets of a very
> large key-space."

**Transfer.**
1. **A sorted-key store is the right shape.** LMDB's own header calls it "A Btree-based
   database management library" and its default key comparator is a plain `memcmp`
   (`mdb_cmp_memn`, `diff = memcmp(a->mv_data, b->mv_data, len)`), with `MDB_REVERSEKEY`
   selecting `mdb_cmp_memnr`, a reverse-walking variant — i.e. the engine Cloudflare used for
   configuration is literally a sorted array with a page index, and it ships a *reversed-key*
   comparators mode for the same reason we reverse names.
   <https://github.com/LMDB/lmdb/blob/mdb.master/libraries/liblmdb/mdb.c> (header lines 4–5;
   `mdb_cmp_memn` at line 6047; `MDB_REVERSEKEY` selection at line 10958).
2. **But not as a mutable, page-mapped, copy-on-write file.** The 1.5–80× amplification is a
   write-endurance problem on the SD/eMMC of a 1 GiB device, and `SIGBUS` means a read of a
   cold page can kill the process if the medium errors. Our artifact is rewritten wholesale,
   never patched, so it should be: build a new file, flush, rename, swap — no COW pages ever.
   Note `MDB_REVERSEKEY` is also the caution: a reversed-key *comparator* keeps the stored key
   forward, but a reversed-key *arena* (which is what gives us contiguous children) must be
   written in reversed order, not sorted forward and re-read backwards.
3. **"1 MB = 10 GB globally" is the argument for one shared blob** across lists (first pass
   R2) rather than one table per list.
4. The *random-subset shard* is the pattern I reuse for the two-pass build in §7 N1: bucket
   assignment by hash of the key, so every bucket is balanced without knowing the distribution.

### 3.4 MIGP: hash-prefix bucketing (verified; was UNVERIFIED in pass 1)

<https://blog.cloudflare.com/privacy-preserving-compromised-credential-checking>, 2021-10-14.

> "the MIGP server partitions the breach dataset into buckets based on the hash prefix of the
> username (the bucket identifier), which is usually 16-20 bits in length."

> "we set the username hash prefix length to 20 bits, so that there are a total of 2^20 (or
> just over 1 million) buckets … capping out each bucket size at the current KV value limit of
> 25MB."

Each bucket holds `n·m` ciphertexts ("Our demo server stores 10 ciphertexts per breach entry");
the client downloads one bucket and scans it. Design notes: the precomputation "only needs to
be done rarely"; new data "can be appended to the existing buckets"; bucket counts leak size
information, mitigated by "dummy entries and padding".

**Transfer.** This is a *bucketed* set, i.e. the same family as the multi-probe `mmuniq-hash`
design the first pass already measured, only bucketed by a hash prefix instead of linear
probing. Its one transferable idea is **append-only growth**: new domains append to their
bucket without rebuilding the table. Cost for us is a directory: 2^20 buckets × 4 B =
**4 MiB [ARITH]** for 2.46 M entries, i.e. 2.3 entries per bucket — 32× the directory of a
64-name block index (128 KiB [ARITH], §6). Rejected here, but worth one sentence in the
proposal as "considered".

### 3.5 Query names do not aggregate: HLL state costs 20–100 B/row, counters cost 8 B

<https://blog.cloudflare.com/how-cloudflare-analyzes-1m-dns-queries-per-second>, 2017-05-10.

Two facts that matter to us.

1. **Per-row cost of an approximate, mergeable distinct-count state:**

> "the aforementioned HLL state tends to be 20-100 bytes / row when compressed, while a counter
> is only 8 bytes (1 byte compressed on average)."

2. **Domain names are the high-cardinality column, and the long tail is one-shot noise:**

> "Domain names are subject to popularity… In practice, we see anywhere between 0 - 60x row
> reduction when aggregating by query names"

and the reducer is defeated by "cacheable queries such as typos or random prefix subdomain
attacks".

**Transfer.** Two consequences for the design, both anti-optimisations:
- There is **no cheap exact counting structure** to piggy-back on; anything per-name beyond
  membership costs 8 B minimum, which is the same order as the 64-bit-hash table the first
  pass measured at 8 B/entry. So "store a counter/hit-count next to each domain" doubles the
  table for a signal DNS traffic does not reliably carry.
- **Popularity tiering of block lists is not supportable from query traffic**: random-prefix
  subdomains mean the observed-name distribution is not the block-list distribution. Do not
  build "hot names in RAM, cold names on disk".

### 3.6 The "admission filter" rejection: every asset is missed twice

<https://blog.cloudflare.com/why-we-started-putting-unpopular-assets-in-memory>, 2020-03-24.

They considered remembering which assets had been seen before so they could promote popular
ones, using "Bloom filter, Counting Bloom filter and Count-min sketch … with their specific
trade-offs", and rejected the class:

> "Such an approach solves one problem but introduces a new one: every asset is missed at least
> twice before it is cached. Because the number of cache misses is amplified compared to what we
> do today, this approach multiplies both the cost of bandwidth and server utilization for our
> customers. This is not an acceptable tradeoff in our eyes."

Also, the memory hierarchy numbers from a 256 GB edge box, which is the same tension a 1 GiB
device has at 1/256 scale: "RSS memory consumption for all services is about 87.71 GB, with our
cache service consuming 4.1 GB… page cache usage. Total size is 128.6 GB, with the cache
service using 41.6 GB of it", and "some of our edge services increase their total RSS memory
consumption when performing a 'zero downtime upgrade', which runs both the old and new version
of the service in parallel for a short period of time."

**Transfer.** Exactly our reload problem, stated by Cloudflare: the double-residency during a
zero-downtime upgrade is the peak, and that is what forces the design. It is the argument for
§7 N1 (build in bounded windows) and for the file-backed swap of first pass R4.

### 3.7 Compression data points (why not just gzip the arena)

**Kafka, per-codec, on real log topics** — <https://blog.cloudflare.com/squeezing-the-firehose>,
2018-03-05:

| Codec | Messages consumed | Disk usage | Avg message size |
|---|---|---|---|
| none | 30.18 M | 48,106 MB | 1594 B |
| gzip | 3.17 M | 1,443 MB | **455 B** |
| snappy | 20.99 M | 14,807 MB | 705 B |
| lz4 | 20.93 M | 14,731 MB | 703 B |

Caveat the post itself gives: compression changes batching, so message counts differ between
rows; the comparable figure is average message size. **gzip ≈ 3.5× on log records, lz4/snappy
≈ 2.3×.**

**zstd on stored cache objects** — <https://blog.cloudflare.com/cache-transcoding>, 2026-09-01:
"it compressed data 42% faster than Brotli while producing nearly the same file size, and
produced files 11.3% smaller than gzip at a comparable speed."

**Columnar + sorted beats document storage** — <https://blog.cloudflare.com/log-analytics-using-clickhouse>,
2022-09-02: "Each Elasticsearch document which used 600 bytes, came down to 60 bytes per row in
ClickHouse."

**Transfer.** A general-purpose codec buys 2.3–3.5× on record data, which is in the same league
as front-coding — but it costs a decode on every access. **[INFERENCE]** A 4 KiB Brotli block
decodes at roughly 200–400 MB/s on a small core, i.e. ~10–20 µs per block; a `HashSet` probe is
~50–100 ns, so per-block codecs are 100–400× a probe and unusable on the DNS hot path. Codecs
belong at *build/publish* time (compress the artifact on disk, decompress once during load) and
nowhere on the lookup path. That is a clean "rejected, with numbers" paragraph for the proposal.

### 3.8 Azul CT: intern the low-cardinality dimension, store the index

<https://blog.cloudflare.com/azul-certificate-transparency-log>, 2025-04-11:

> "The static CT API introduces another efficiency by deduplicating intermediate and root
> 'issuer' certificates in a log entry's certificate chain. The number of publicly-trusted
> issuer certificates is small (in the low thousands), so instead of storing them repeatedly for
> each log entry, only the issuer hash is stored."

**Transfer.** Confirms the shape of first pass R2 (per-domain bitmask instead of per-list
membership), and generalises it: when one dimension has ~40 values and the other 10⁶, store the
small dimension as a bit-set inside the record. Also a warning: they store the *hash* (32 B)
because the certificate is large; we store the mask (4 B) because the domain is already there.
No change to our design, useful supporting citation when reviewers ask "why a bitmask".

### 3.9 Radar domain rankings: popularity is modelled, not stored

<https://blog.cloudflare.com/radar-domain-rankings>, 2022-09-30, and
<https://blog.cloudflare.com/radar-trending-domains>, 2023-07-24.

> "Domain Rankings looks at the size of the population of users that look up a domain per unit
> of time."

They explicitly rejected traffic volume as a proxy, and "spent the last six months building a
variety of machine learning models to help us predict the rank of a domain"; the top-100 list is
updated daily, and trending lists needed the top-10,000 band. **No storage structure, no
per-domain bytes, no HLL mention.**

**Transfer.** None for memory. It does dispose of a tempting idea ("rank domains by Radar and
keep only the top N in memory"): the ranking is a modelled estimate published as JSON top-lists,
not a per-domain table we could reuse, and its input is 1.1.1.1 query data we do not have.

### 3.10 tubular: encode precedence into the key instead of storing a tree

<https://blog.cloudflare.com/tubular-fixing-the-socket-api-with-ebpf>, 2022-02-17:
bindings live in "a longest prefix match (LPM) trie" that "stores a mapping from (protocol,
port, prefix) to (ID, prefix length)", and "lookup has complexity proportional to the length of
the key instead of linear complexity for the 'naive' solution." The interesting trick is that
the precedence is baked into the map key (`127.0.0.0/24 = 0x7f 00 00 ??`, with an explicit
"unspecified" byte) rather than represented in a data structure.

**Transfer.** The same shape as our suffix loop: *n* lookups, each a key truncation, longest
match wins, cost ∝ name length. It supports the first pass's argument that a trie is not needed
— the LPM behaviour is reproducible with 3–4 point lookups on truncated keys, which is what
`DomainSet` already does.

### 3.11 Hostname lists are exact-host + wildcard, not suffix-inheriting

<https://blog.cloudflare.com/hostname-asn-lists>, 2023-11-15:

> "you can add domains and subdomains to a list, and a domain doesn't automatically match
> subdomains. For example, if you add example.com to your list… requests for api.example.com
> won't match. Hostname lists accept the `*` wildcard to include subdomains."

**Transfer.** A useful contrast for the proposal: Cloudflare's *WAF* list object deliberately
avoids suffix semantics (one entry = one host, `*` is explicit), so it can be a plain hash set.
Our block lists must inherit to subdomains, which is precisely the requirement that forces a
suffix-capable layout; do not let a reviewer equate the two.

---

## 4. Theme ledger, including the negatives

Counts are documents containing the pattern, over the 3,686-post corpus.

| Theme | Docs | What is actually there |
|---|---|---|
| Roaring / compressed bitmaps | 1 | "the Roaring Twenties" in a data-centre announcement. **No Roaring anywhere.** |
| xor / ribbon / quotient / binary-fuse filters | 0 | absent |
| Succinct structures (rank/select, wavelet, Elias-Fano) | 11 | all the adverb "succinctly"/"succinct"; no structure |
| Bitmaps / bitsets as a data structure | 12 | SVGs, e-paper, an HLL "bitmap", Go's compiler. None is a set layout |
| Bloom filters | 25 | the 2020 Bloom post, Brotli dictionary, Quicksilver v1.5, **Advanced DNS Protection (§3.1)**, a cache-admission discussion (§3.6) |
| Cuckoo filters | 4 | Bloom post (evaluated, rejected), Quicksilver v1.5 (evaluated) |
| Perfect hashing | 3 | **WAF post (§3.2, real)**; Bloom post (one mention); `addressing-agility` (unrelated) |
| FST / finite state transducer | 1 | `pingora-saving-compute…` (already covered) |
| Tries / radix | 8 (`trie`) / 5 (`radix`) | Brotli dictionary, BPF LPM (covered), tubular (§3.10), LuaJIT GC; BGP-route posts are false positives |
| Sorted arrays / binary search | 18 | ClickHouse parts, LMDB keys, Radar lists; no per-entry cost |
| `bytes per entry / key / row` (exact phrase) | 3 | DNS cache post (covered), 2017 HLL post (§3.5), ClickHouse logs (§3.7) |
| HyperLogLog | 3 | §3.5, CitusDB, Anomaly Detection — all counting, none membership |
| Count-min / CM sketch | 3 | pingora-limits (covered), §3.6, one false positive |
| Linear probing / open addressing | 1 | the 2020 Bloom post (covered) |
| Front coding / dictionary encoding | 0 | absent — the first pass's R1 has no Cloudflare precedent |
| String dedup / interning | 10 (`deduplicat`) | only Azul issuers (§3.8, 12 hits) is structural; "virtual interning" is an internship post |
| Set intersection / Jaccard / MinHash | 5 | Pwned Passwords / Privacy Pass comparisons only; no set-intersection structure |
| Compression of domain/IP/URL lists | 0 | nothing; compression posts are about HTTP objects, logs and LLM tensors |
| Domain ranking storage | 3 | §3.9 — a model plus published top-lists |
| Quicksilver v1 (LMDB) layout | 3 | §3.3 |
| Cache keys | 12 | semantics only (Vary, per-entrypoint caches); no per-key byte cost |
| Zero Trust / Spectrum / Magic Transit structures | 0 | those sections' posts are about routing, policy and DDoS; the only data-structure content is the Magic Firewall IP-list post already covered |

---

## 5. Master table: the new numbers in one place

| Source | Structure | Numbers given | Exact? | Suffix lookup? | Transfer |
|---|---|---|---|---|---|
| [ADP](https://blog.cloudflare.com/advanced-dns-protection) (2024-03-07) | counting Bloom per customer, fleet-distributed | tens of M queries/day/customer; 98 % of distribution bytes from cache; **no FPR, no bits/name** | no | n/a (full name) | **high** as precedent + tolerance-budget design |
| [WAF ML](https://blog.cloudflare.com/making-waf-ai-models-go-brr) (2024-07-25) | alphabet-rank offsets + dense `u16[N³]` index | 248.46→21.53 µs (11.5×); index ~500 KiB; `phf`/`ph`/`quickphf` all lost | yes | no | **medium**: alphabet compaction; MPHF negative |
| [Quicksilver v1](https://blog.cloudflare.com/introducing-quicksilver-configuration-distribution-at-internet-scale) (2020-03-30) | LMDB B+tree, mmap, sorted keys, append-only, multi-reader | tens of M reads/s; p99 −2 orders of magnitude | yes | prefix only | **high**: sorted-store shape + snapshot swap |
| [Quicksilver in prod](https://blog.cloudflare.com/moving-quicksilver-into-production) (2020-11-25) | same | 1 MB write → 30 MB flushed; 1.5–80× amplification; 1 MB = 10 GB globally; SIGBUS on mmap I/O error | yes | — | **high** as a negative: no COW store |
| [Quicksilver v2 p2](https://blog.cloudflare.com/quicksilver-v2-evolution-of-a-globally-distributed-key-value-store-part-2-of-2) (2025-07-17) | full set on few nodes + sharded caches | 5 B pairs / 1.6 TB; V1.5 halved per-server disk | yes | — | **medium**: random-subset shards for build |
| [MIGP](https://blog.cloudflare.com/privacy-preserving-compromised-credential-checking) (2021-10-14) | hash-prefix buckets | 16–20 bit prefix; 2²⁰ buckets; 25 MB bucket cap; +append, +padding | yes (client) | no | **low-medium**: append-only growth; directory too big for us |
| [DNS analytics](https://blog.cloudflare.com/how-cloudflare-analyzes-1m-dns-queries-per-second) (2017-05-10) | HLL aggregation state | HLL 20–100 B/row compressed vs 8 B counter; 0–60× row reduction | no | — | **medium** as a negative (no cheap counters) |
| [Unpopular assets](https://blog.cloudflare.com/why-we-started-putting-unpopular-assets-in-memory) (2020-03-24) | transient cache; Bloom/CM rejected | RSS 87.71 GB, page cache 128.6 GB; "missed at least twice" | yes | — | **medium**: the reload peak argument |
| [Kafka compression](https://blog.cloudflare.com/squeezing-the-firehose) (2018-03-05) | gzip / snappy / lz4 on topics | 1594 B → 455 B (gzip), 703–705 B (lz4/snappy) | yes | — | **medium** as a negative for hot-path codecs |
| [ClickHouse logs](https://blog.cloudflare.com/log-analytics-using-clickhouse) (2022-09-02) | columnar, sorted parts | 600 B/row → 60 B/row | yes | — | low |
| [Azul CT](https://blog.cloudflare.com/azul-certificate-transparency-log) (2025-04-11) | intern low-cardinality issuers → hash | issuers "in the low thousands" | yes | — | **medium**: supports bitmask encoding |
| [tubular](https://blog.cloudflare.com/tubular-fixing-the-socket-api-with-ebpf) (2022-02-17) | LPM trie + key encoding | cost ∝ key length | yes | prefix | low-medium: n-lookup suffix loop |

---

## 6. Cost model: layouts for 2.46 M entries / 2.1 M unique names

Our own measured base (from the first pass): `HashSet<string>` ≈ 98 MiB anon; `HashSet<ulong>`
20.1 B/entry; 64-bit open-addressing table 41.0 MiB at 0.8 load; 128-bit table 65.9 MiB.
Directory figures below are **[ARITH]** from those and from the numbers quoted above.

| Layout | Directory / index | Search cost per hit | Notes |
|---|---|---|---|
| sorted arena + 64-name block index | 2.1 M/64 = 32.8 k × 4 B = 131 248 B = **128 KiB** | 1 binary search over 32.8 k (15 cmps) + ≤64 linear | first pass R1 baseline |
| hash-bucketed arena, k = 10 (1024 buckets) | 1024 × 4 B = **4 KiB** | 1 FNV-1a + binary search over ~2 050 (11 cmps) | §7 N1; blocks are 40–60 KB |
| hash-bucketed arena, k = 14 (16 384) | 64 KiB | 1 hash + 7 cmps over ~128 names | block ≈ 2.5 KB, cache-resident |
| MIGP-style 20-bit buckets | 2²⁰ × 4 B = **4 MiB** | 1 hash + scan of 2.3 entries | 32× the directory for no latency win |
| flat open-addressing 64-bit hashes (mmuniq-style) | table itself 41 MiB | 1–2 probes | no names stored → no attribution, no suffix |
| MPHF + stored keys | 2.1–2.7 bits/key ≈ 0.6–0.7 MiB | 1 hash + 1 compare | rejected by WAF measurement (§3.2) and pass-1 R7 |

Two consequences worth stating in the proposal: the directory is never the problem (KiB), and
the only layouts that beat a sorted arena on lookup cost are the ones that stop storing names,
which we cannot do because of per-list attribution and suffix matching.

---

## 7. Ranked: the three most promising new ideas, with the smallest C# form

Ranked by expected value for *our* constraints (2.46 M entries, 1 GiB devices, reload peak,
plain C#, small diff). All three are exact and compose with the first pass's R1/R2.

### N1. Two-pass, hash-bucketed build and layout — removes the 2× reload peak

**Idea, from Quicksilver v2's "uniform random subsets of a very large key-space" sharding and
MIGP's hash-prefix buckets:** bucket by the top bits of a stable hash of the name, build each
bucket independently, and emit the arena in bucket order. Bucket assignment is balanced
*without knowing the distribution*, and the layout that falls out is fast to search.

Why it matters more than bytes: today the reload holds the whole new set in memory beside the
old one (the "~2×" in the problem statement). With 1024 buckets, the build holds ≤ ~2 050
names (~50 KB) at a time. **[INFERENCE]** Peak RSS during reload drops from ≈1.9× to ≈1.1× the
artifact (the residual is the output file being written plus buffers), which is the difference
between fitting and not fitting on a 1 GiB box. The first pass's R4 (mmap + atomic swap) needs
this to be practical: you cannot stream a swap if the build itself needs both copies resident.

Numbers from §6: 4 KiB directory at k=10, 11 comparisons per hit; 64 KiB at k=14, 7
comparisons.

```csharp
// stable hash: string.GetHashCode() is randomized per process, so it cannot key a persisted file
static ulong Fnv1a(ReadOnlySpan<char> s) {
    ulong h = 1469598103934665603UL;
    foreach (char c in s) { h ^= (byte)c; h *= 1099511628211UL; }
    return h;
}

// pass 1: one sequential read of every list; each record goes to its bucket's temp file
const int K = 10, B = 1 << K;
var w = new StreamWriter[B];                        // 4 KiB buffer each => ~4 MiB total
for (int b = 0; b < B; b++) w[b] = new StreamWriter(TempPath(b), false, Utf8NoBom, 1 << 12);

foreach (var (listId, path) in lists)
    foreach (var raw in File.ReadLines(path)) {
        if (!Names.TryNormalize(raw, out var name)) continue;   // lowercase, trim trailing '.'
        int b = (int)(Fnv1a(name) >> (64 - K));
        w[b].Write(name); w[b].Write('\t'); w[b].Write(listId); w[b].Write('\n');
    }
foreach (var s in w) s.Dispose();

// pass 2: per bucket — sort, merge masks, append to the arena, record the offset
var off = new uint[B + 1];
for (int b = 0; b < B; b++) {
    var recs = ReadBucket(TempPath(b));             // ~2 050 (name, listId) pairs ~ 50 KB
    Array.Sort(recs, CompareName);
    off[b] = (uint)arena.Length;
    foreach (var g in MergeByMask(recs)) arena.Add(g.Name, g.Mask);   // one uint mask
    File.Delete(TempPath(b));
}
off[B] = (uint)arena.Length;
```

Peak build memory is the 1024 write buffers (~4 MiB) plus one bucket (~50 KB in RAM, ~40 KB on
disk); the temporary files hold the normalised input once, so disk usage is one pass over the
lists. Lookup is `b = hash >> 54; BinarySearch(arena.Slice(off[b], off[b+1] - off[b]))`.
Between 100 and 130 lines including the bucket reader; no dependency; exact (the hash only
chooses a bucket, names are compared in full).

Two caveats to state: (a) the bucket hash must be **stable across processes** because it is
baked into the file — hence the hand-rolled FNV-1a rather than `string.GetHashCode()`; (b) a
bucket's block is variable-length, so the reader needs `off[]` in the artifact (4 KiB) and
nothing else. One operational detail: 1024 simultaneous writers means 1024 open descriptors,
which needs `ulimit -n` raised past the default 1024. At **K = 8** there are 256 writers, a
1 KiB directory, ~8 200 names per block (~160 KB) and 14 comparisons — the cheaper default if
the descriptor limit is not negotiable.

### N2. 6-bit alphabet compaction of the name arena

**Idea, from the WAF post's `NGRAM_OFFSETS` (§3.2):** replace each byte by its rank in the
*used* alphabet, then pack. Domain names use ~39 symbols (`a–z` 26, `0–9` 10, `-`, `.`, `_`),
which fits 6 bits with 25 codes to spare for an escape byte.

Exactness: exact if any byte outside the alphabet is written as an escape + raw byte (IDN
UTF-8, uppercase if normalisation is skipped). Nothing is lost.

Size **[ARITH, assumption: mean name length 18–22 chars]**:

| Representation | bytes per name | 2.46 M entries |
|---|---|---|
| ASCII arena + 1 B length | ~20 | ~49 MB |
| 6-bit packed | ~15 | ~37 MB |
| front-coded (R1) + 1 B | ~10 | ~25 MB |
| front-coded + 6-bit packed | ~7.5–8 | ~19 MB |

So ~25 % off the name arena, and it stacks with front-coding. It does **not** help the offset
array or the mask. Against that: every comparison now decodes, so a comparator has to unpack
into a stack buffer or compare packed codes with a bit cursor. That cost lands on the hot
path, which is why this is ranked below N1.

```csharp
static readonly sbyte[] Rank = BuildRank();   // 256 entries, -1 = escape
// 39 symbols -> 6 bits; codes 0..38 = alphabet, 60 = escape, 61..63 unused
static void Pack(ReadOnlySpan<byte> ascii, ref BitWriter w) {
    foreach (byte c in ascii) {
        int r = Rank[c];
        if (r >= 0) w.Write(r, 6);
        else { w.Write(60, 6); w.Write(c, 8); }
    }
}
```

40–60 lines with the bit cursor. It pays only if the arena dominates the artifact after R1; if
front-coding already lands at ~10 B/name, expect ~6 MB, not 12.

### N3. The artifact rule: append-only file, atomic rename, never a COW/paged store, no codec on the hot path

**Idea, from Quicksilver v1's production post-mortem (§3.3) and the codec numbers (§3.7).**
This is the cheapest of the three (a rule, not a structure) and it prevents a class of
regressions on 1 GiB devices with flash storage.

The rules, each with its citation:

1. **Never mutate the live artifact.** LMDB's copy-on-write cost Cloudflare 1.5–80× write
   amplification and "when Quicksilver wrote 1 megabyte, 30 megabytes were flushed to disk".
   Our artifact is rewritten wholesale anyway: write `blocklist.v N+1`, flush, `File.Move`
   with overwrite, then swap the in-memory root pointer. No pages, no journal, no WAL.
2. **mmap read-only, if at all.** "LMDB maps the database file into memory and when the kernel
   experiences an I/O error while accessing the SSD, it will terminate Quicksilver with a
   SIGBUS." A read-only mapping of an immutable file can still fault on media error; treat a
   failed read as "reload from disk", not as a crash of the DNS service.
3. **Do not compress the arena for lookup.** gzip buys 3.5× on records (§3.7) but a per-block
   decode is ~10–20 µs **[INFERENCE]** against a ~50–100 ns probe. Compress the *file on
   disk* if disk matters; decompress once into the arena at load.
4. **One shared arena, not one per list** — "a piece of data one megabyte in size consumes at
   least 10 gigabytes globally" (§3.3). This is the same conclusion as first pass R2, now with
   a number attached to the cost of duplication.
5. **Budget for double residency during reload** — "some of our edge services increase their
   total RSS memory consumption when performing a 'zero downtime upgrade', which runs both the
   old and new version of the service in parallel" (§3.6). Which is why N1 exists.

`MemoryMappedFile` + `CreateViewAccessor` + `AcquirePointer` is ~30 lines, but the point of N3
is the *policy*, so it can also be delivered as five sentences in the proposal's "risks"
section without any code.

---

## 8. What I could not verify, and what does not exist

**Could not verify.**
- **The block-list structure behind 1.1.1.1 for Families / Gateway.** Nothing new. The corpus
  search for `block ?list|deny ?list|allow ?list|domain categor` returns 14 posts; read at the
  passage that matched, none describes a per-domain set — they are about WAF/IP lists, policy
  management, seccomp allowlists, or a post-mortem. The Advanced DNS Protection counting Bloom
  (§3.1) is the *nearest* published thing, and it is a per-customer traffic profile, not a
  category list.
- **ADP's filter size and false-positive rate.** The post gives no bits, no counters, no FPR,
  and no per-name cost. I did not find a follow-up post or doc page with them.
- **Quicksilver v2 part 2's per-key layout.** The post gives the aggregate 1.6 TB / 5 B pairs
  only; the shard/cache design is described qualitatively, with no per-entry byte figure.
- **`shared-dictionaries`** existed in the corpus only as the Japanese machine translation; I
  used no number from it. Its English page was not read.
- **Web-search recall.** Ten `site:` queries surfaced ~10 posts total, several already known.
  I cannot claim they exercise the search engine's full index; that is exactly why §1.1 was
  used instead.

**Does not exist (searched, zero or false-positive hits over 3,686 posts).**
- No Roaring bitmap, no compressed-bitmap post of any kind.
- No xor / ribbon / quotient / binary-fuse filter post.
- No succinct-structure (rank/select, wavelet tree, Elias-Fano) post.
- No post on front-coding, dictionary-encoding, or compressing a list of domains/IPs/URLs.
- No post that quotes a bytes-per-domain or bytes-per-entry figure for a name set. The three
  `bytes per entry/key/row` hits are the DNS cache (memory layout of a record), HyperLogLog
  state, and ClickHouse rows.
- No `bytes/entry` figure for Workers KV, D1 or R2 — those posts discuss latency and
  consistency, never footprint.

**Consequence for the upstream proposal.** The claim "Cloudflare has not published the
structure it uses for DNS block lists, and has published no per-domain byte figure for any
name set" now rests on a complete enumeration of the blog rather than on tag pages, and can be
stated with the numbers in §1 and §4. The strongest *positive* citations available for our
design are: a sorted-key, mmap'd, append-only store as the shape (Quicksilver v1), a bitmask
over a low-cardinality dimension as the attribution encoding (Azul, Magic Firewall), a
counting Bloom with a tolerance budget as the only published DNS-name filter (ADP), and a
branchless alphabet-compacted index as the only published alternative to hashing (WAF ML) —
which, at 500 KiB, also marks the point where that technique stops applying to a 2.46 M-key
set.
