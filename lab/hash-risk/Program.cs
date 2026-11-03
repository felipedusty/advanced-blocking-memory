using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

const ulong Prime = 1099511628211UL;
const ulong Golden = 0x9E3779B97F4A7C15UL;
const int Threads = 6;

string mode = args.Length > 0 ? args[0] : "";
long arg1 = args.Length > 1 ? long.Parse(args[1]) : 0;

static ulong SplitMix(ref ulong state)
{
    ulong z = (state += 0x9E3779B97F4A7C15UL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    return z ^ (z >> 31);
}

static ulong BasisFor(long r)
{
    ulong s = 0xC0FFEE0000000000UL + (ulong)r * 7919UL;
    return SplitMix(ref s) | 1UL;
}

static ulong Fnv(string s, ulong basis)
{
    ulong h = basis;
    foreach (char c in s)
        h = (h ^ c) * Prime;

    return h;
}

static ulong FnvMix(string s, ulong basis)
{
    ulong h = basis;
    foreach (char c in s)
    {
        h = (h ^ c) * Prime;
        h ^= h >> 32;
    }

    return h;
}

static ulong Sha(string s, ulong basis)
{
    byte[] buf = new byte[8 + Encoding.UTF8.GetMaxByteCount(s.Length)];
    BitConverter.TryWriteBytes(buf, basis);
    int n = Encoding.UTF8.GetBytes(s, 0, s.Length, buf, 8);
    Span<byte> digest = stackalloc byte[32];
    SHA256.HashData(buf.AsSpan(0, 8 + n), digest);
    return BitConverter.ToUInt64(digest);
}

static string[] Load(string path) => File.ReadAllLines(path).Where(l => l.Length > 0).ToArray();

static long Heap()
{
    for (int i = 0; i < 2; i++)
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        GC.WaitForPendingFinalizers();
    }

    GCMemoryInfo info = GC.GetGCMemoryInfo(GCKind.FullBlocking);
    if (Environment.GetEnvironmentVariable("HEAPDEBUG") == "1")
        Console.Error.WriteLine($"  [heap] total {GC.GetTotalMemory(false) / 1048576.0:F1} MiB, heap size {info.HeapSizeBytes / 1048576.0:F1}, fragmented {info.FragmentedBytes / 1048576.0:F1}, committed {info.TotalCommittedBytes / 1048576.0:F1}");

    return GC.GetTotalMemory(true);
}

static string? Parent(string d)
{
    int i = d.IndexOf('.');
    return i < 0 ? null : d.Substring(i + 1);
}

static long PairsInSorted(ulong[] sorted, int shiftRight)
{
    long pairs = 0;
    long run = 1;
    for (int i = 1; i < sorted.Length; i++)
    {
        if ((sorted[i] >> shiftRight) == (sorted[i - 1] >> shiftRight))
        {
            run++;
        }
        else
        {
            pairs += run * (run - 1) / 2;
            run = 1;
        }
    }

    return pairs + run * (run - 1) / 2;
}

static string Z(double observed, double expected)
{
    double z = expected > 0 ? (observed - expected) / Math.Sqrt(expected) : 0;
    return $"obs {observed,10:N0}  exp {expected,12:N1}  ratio {(expected > 0 ? observed / expected : 0),6:F3}  z {z,+6:F2}";
}

// ---------------------------------------------------------------- collide: pair collisions among the real entries at reduced widths
void Collide()
{
    string[] entries = Load("lists/union.txt");
    long n = entries.Length;
    double pairsTotal = (double)n * (n - 1) / 2;
    Console.WriteLine($"entries: {n:N0}; expected colliding pairs per base at width k = C(n,2)/2^k");
    (string name, Func<string, ulong, ulong> f, int r)[] variants =
    [
        ("fnv1a (the patch)", Fnv, 100),
        ("fnv1a + xorshift per step", FnvMix, 100),
        ("sha256 truncated (ideal control)", Sha, 12),
    ];
    int[] hi = [32, 36, 40, 44, 48];
    int[] lo = [32, 40];

    foreach ((string name, Func<string, ulong, ulong> f, int r) in variants)
    {
        long[] obsHi = new long[hi.Length];
        long[] obsLo = new long[lo.Length];
        Stopwatch sw = Stopwatch.StartNew();
        Parallel.For(0, r, new ParallelOptions { MaxDegreeOfParallelism = Threads }, i =>
        {
            ulong basis = BasisFor(i);
            ulong[] h = new ulong[n];
            for (int e = 0; e < n; e++)
                h[e] = f(entries[e], basis);

            ulong[] sorted = (ulong[])h.Clone();
            Array.Sort(sorted);
            for (int k = 0; k < hi.Length; k++)
                Interlocked.Add(ref obsHi[k], PairsInSorted(sorted, 64 - hi[k]));

            for (int k = 0; k < lo.Length; k++)
            {
                ulong mask = (1UL << lo[k]) - 1;
                ulong[] m = new ulong[n];
                for (int e = 0; e < n; e++)
                    m[e] = h[e] & mask;

                Array.Sort(m);
                Interlocked.Add(ref obsLo[k], PairsInSorted(m, 0));
            }
        });

        Console.WriteLine($"\n{name}: {r} random bases, {sw.Elapsed.TotalSeconds:F0} s");
        for (int k = 0; k < hi.Length; k++)
            Console.WriteLine($"  top {hi[k],2} bits   {Z(obsHi[k], r * pairsTotal / Math.Pow(2, hi[k]))}");

        for (int k = 0; k < lo.Length; k++)
            Console.WriteLine($"  low {lo[k],2} bits   {Z(obsLo[k], r * pairsTotal / Math.Pow(2, lo[k]))}");

        // full 64 bits
        long full = 0;
        Parallel.For(0, Math.Min(r, 12), new ParallelOptions { MaxDegreeOfParallelism = Threads }, i =>
        {
            ulong basis = BasisFor(1000 + i);
            ulong[] h = new ulong[n];
            for (int e = 0; e < n; e++)
                h[e] = f(entries[e], basis);

            Array.Sort(h);
            Interlocked.Add(ref full, PairsInSorted(h, 0));
        });
        Console.WriteLine($"  all 64 bits   colliding pairs over {Math.Min(r, 12)} bases: {full} (expected {Math.Min(r, 12) * pairsTotal / Math.Pow(2, 64):E2})");
    }
}

static ulong FnvMul(string s, ulong basis, ulong mul)
{
    ulong h = basis;
    foreach (char c in s)
        h = (h ^ c) * mul;

    return h;
}

// ---------------------------------------------------------------- pair128: two lanes with independent bases, joint key truncated
void Pair128()
{
    string[] entries = Load("lists/union.txt");
    long n = entries.Length;
    double pairsTotal = (double)n * (n - 1) / 2;
    Console.WriteLine($"entries: {n:N0}; the key is lane A (the patch's FNV-1a) with lane B; each lane keeps w bits, so the joint key has 2w bits;");
    Console.WriteLine("expected colliding pairs per base pair = C(n,2)/2^(2w)");
    (string name, Func<string, ulong, ulong> a, Func<string, ulong, ulong> b, int r)[] variants =
    [
        ("lane B: FNV-1a with another basis", Fnv, Fnv, 100),
        ("lane B: FNV-1a with the multiplier 0x9E3779B97F4A7C15", Fnv, (s, x) => FnvMul(s, x, 0x9E3779B97F4A7C15UL), 100),
        ("control: sha256 in both lanes", Sha, Sha, 12),
    ];
    int[] hi = [16, 18, 20, 22];
    int[] lo = [16, 20];

    foreach ((string name, Func<string, ulong, ulong> fa, Func<string, ulong, ulong> fb, int r) in variants)
    {
        long[] obsHi = new long[hi.Length];
        long[] obsLo = new long[lo.Length];
        Stopwatch sw = Stopwatch.StartNew();
        Parallel.For(0, r, new ParallelOptions { MaxDegreeOfParallelism = Threads }, i =>
        {
            ulong basisA = BasisFor(5000 + 2 * i), basisB = BasisFor(5001 + 2 * i);
            ulong[] a = new ulong[n];
            ulong[] b = new ulong[n];
            for (int e = 0; e < n; e++)
            {
                a[e] = fa(entries[e], basisA);
                b[e] = fb(entries[e], basisB);
            }

            ulong[] key = new ulong[n];
            for (int k = 0; k < hi.Length; k++)
            {
                int w = hi[k];
                for (int e = 0; e < n; e++)
                    key[e] = ((a[e] >> (64 - w)) << w) | (b[e] >> (64 - w));

                Array.Sort(key);
                Interlocked.Add(ref obsHi[k], PairsInSorted(key, 0));
            }

            for (int k = 0; k < lo.Length; k++)
            {
                int w = lo[k];
                ulong mask = (1UL << w) - 1;
                for (int e = 0; e < n; e++)
                    key[e] = ((a[e] & mask) << w) | (b[e] & mask);

                Array.Sort(key);
                Interlocked.Add(ref obsLo[k], PairsInSorted(key, 0));
            }
        });

        Console.WriteLine($"\n{name}: {r} base pairs, {sw.Elapsed.TotalSeconds:F0} s");
        for (int k = 0; k < hi.Length; k++)
            Console.WriteLine($"  top {hi[k]}+{hi[k]} bits   {Z(obsHi[k], r * pairsTotal / Math.Pow(2, 2 * hi[k]))}");

        for (int k = 0; k < lo.Length; k++)
            Console.WriteLine($"  low {lo[k]}+{lo[k]} bits   {Z(obsLo[k], r * pairsTotal / Math.Pow(2, 2 * lo[k]))}");
    }
}

// ---------------------------------------------------------------- pair96: 64 bits of lane A with the top 32 bits of lane B, reduced
void Pair96()
{
    string[] entries = Load("lists/union.txt");
    long n = entries.Length;
    double pairsTotal = (double)n * (n - 1) / 2;
    Console.WriteLine($"entries: {n:N0}; key = low w bits of lane A (the weak end of FNV-1a) with the top w bits of lane B; expected pairs per base pair = C(n,2)/2^(2w)");
    int[] widths = [16, 18, 20, 22];
    long[] obs = new long[widths.Length];
    const int R = 100;
    Parallel.For(0, R, new ParallelOptions { MaxDegreeOfParallelism = Threads }, i =>
    {
        ulong basisA = BasisFor(7000 + 2 * i), basisB = BasisFor(7001 + 2 * i);
        ulong[] key = new ulong[n];
        for (int k = 0; k < widths.Length; k++)
        {
            int w = widths[k];
            ulong mask = (1UL << w) - 1;
            for (int e = 0; e < n; e++)
            {
                (ulong a, ulong b) = (Fnv(entries[e], basisA), FnvMul(entries[e], basisB, Golden));
                key[e] = ((a & mask) << w) | (b >> (64 - w));
            }

            Array.Sort(key);
            Interlocked.Add(ref obs[k], PairsInSorted(key, 0));
        }
    });

    for (int k = 0; k < widths.Length; k++)
        Console.WriteLine($"  low {widths[k]} of A + top {widths[k]} of B   {Z(obs[k], R * pairsTotal / Math.Pow(2, 2 * widths[k]))}");
}

// ---------------------------------------------------------------- persistence: do collisions survive a new basis?
void Persistence()
{
    string[] entries = Load("lists/union.txt");
    int n = entries.Length;
    HashSet<(int, int)>[] pairs = new HashSet<(int, int)>[2];
    for (int b = 0; b < 2; b++)
    {
        ulong basis = BasisFor(5000 + b);
        (ulong h, int i)[] arr = new (ulong, int)[n];
        for (int i = 0; i < n; i++)
            arr[i] = (Fnv(entries[i], basis), i);

        Array.Sort(arr, (x, y) => x.h.CompareTo(y.h));
        pairs[b] = [];
        int start = 0;
        for (int i = 1; i <= n; i++)
        {
            if (i == n || (arr[i].h >> 32) != (arr[start].h >> 32))
            {
                for (int a = start; a < i; a++)
                    for (int c = a + 1; c < i; c++)
                        pairs[b].Add((Math.Min(arr[a].i, arr[c].i), Math.Max(arr[a].i, arr[c].i)));

                start = i;
            }
        }
    }

    int overlap = pairs[0].Count(p => pairs[1].Contains(p));
    Console.WriteLine($"top-32-bit colliding pairs with basis A: {pairs[0].Count}, with basis B: {pairs[1].Count}, pairs that collide under both: {overlap}");
    Console.WriteLine($"expected overlap if the bases are independent: {pairs[0].Count * (double)pairs[1].Count / ((double)n * (n - 1) / 2):E2}");
}

// ---------------------------------------------------------------- probe: false positives of unlisted names against the real entries at reduced widths
string Lower(ulong state, int len)
{
    char[] c = new char[len];
    for (int i = 0; i < len; i++)
        c[i] = (char)('a' + (int)(SplitMix(ref state) % 26));

    return new string(c);
}

void Probe()
{
    string[] entries = Load("lists/union.txt");
    HashSet<string> entrySet = new HashSet<string>(entries);
    int n = entries.Length;
    string[] tlds = ["com", "net", "org", "io", "xyz", "top", "shop", "info"];
    const string Alpha = "abcdefghijklmnopqrstuvwxyz0123456789-";

    (string name, long count, Func<long, string> gen)[] families =
    [
        ("random names 8-20 letters + tld", 20_000_000, i => { ulong s = (ulong)i * 2654435761UL + 17; int len = 8 + (int)(SplitMix(ref s) % 13); return Lower(s, len) + "." + tlds[(int)(SplitMix(ref s) % 8)]; }),
        ("neighbours of every entry (x+e, e+x, e[1..], e[..^1], swap, upper, tld)", (long)n * 7, i =>
        {
            string e = entries[i / 7];
            return (int)(i % 7) switch
            {
                0 => "x" + e,
                1 => e + "x",
                2 => e.Substring(1),
                3 => e.Substring(0, e.Length - 1),
                4 => e.Length > 2 ? e[1].ToString() + e[0] + e.Substring(2) : e + "y",
                5 => e.ToUpperInvariant(),
                _ => e.Substring(0, e.Length - 1) + (e[^1] == 'z' ? 'y' : 'z'),
            };
        }),
        ("counters: host{i}.example.com and a{i}.net", 8_000_000, i => i < 4_000_000 ? $"host{i}.example.com" : $"a{i}.net"),
        ("every label up to 4 chars over [a-z0-9-] + .com", 37L + 37 * 37 + 37L * 37 * 37 + 37L * 37 * 37 * 37, i =>
        {
            long idx = i;
            int len = 1;
            long block = 37;
            while (idx >= block)
            {
                idx -= block;
                block *= 37;
                len++;
            }

            char[] c = new char[len];
            for (int p = len - 1; p >= 0; p--)
            {
                c[p] = Alpha[(int)(idx % 37)];
                idx /= 37;
            }

            return new string(c) + ".com";
        }),
    ];

    bool joint = mode == "probe128";
    int[] hi = joint ? [16, 18, 20] : [32, 36, 40, 44];
    int[] lo = joint ? [16] : [32, 40];
    int Bits(int w) => joint ? 2 * w : w;
    ulong KeyHi(ulong x, ulong y, int w) => joint ? ((x >> (64 - w)) << w) | (y >> (64 - w)) : x >> (64 - w);
    ulong KeyLo(ulong x, ulong y, int w) => joint ? ((x & ((1UL << w) - 1)) << w) | (y & ((1UL << w) - 1)) : x & ((1UL << w) - 1);
    const int R = 3;
    long[,] obsHi = new long[families.Length, hi.Length];
    long[,] obsLo = new long[families.Length, lo.Length];
    long[] counted = new long[families.Length];

    for (int r = 0; r < R; r++)
    {
        ulong basis = BasisFor(9000 + r);
        ulong basisB = BasisFor(9500 + r);
        ulong[] h = new ulong[n];
        ulong[] g = new ulong[n];
        Parallel.For(0, n, new ParallelOptions { MaxDegreeOfParallelism = Threads }, e =>
        {
            h[e] = Fnv(entries[e], basis);
            g[e] = joint ? FnvMul(entries[e], basisB, Golden) : 0;
        });

        ulong[][] keysHi = new ulong[hi.Length][];
        for (int k = 0; k < hi.Length; k++)
        {
            int w = hi[k];
            keysHi[k] = Enumerable.Range(0, n).Select(e => KeyHi(h[e], g[e], w)).Distinct().Order().ToArray();
        }

        ulong[][] keysLo = new ulong[lo.Length][];
        for (int k = 0; k < lo.Length; k++)
        {
            int w = lo[k];
            keysLo[k] = Enumerable.Range(0, n).Select(e => KeyLo(h[e], g[e], w)).Distinct().Order().ToArray();
        }

        for (int fi = 0; fi < families.Length; fi++)
        {
            (string name, long count, Func<long, string> gen) = families[fi];
            long[] localHi = new long[hi.Length];
            long[] localLo = new long[lo.Length];
            long used = 0;
            Parallel.For(0, Threads, new ParallelOptions { MaxDegreeOfParallelism = Threads }, t =>
            {
                long[] lh = new long[hi.Length];
                long[] ll = new long[lo.Length];
                long lu = 0;
                for (long i = t; i < count; i += Threads)
                {
                    string q = gen(i);
                    if (q.Length == 0 || entrySet.Contains(q))
                        continue;

                    lu++;
                    ulong x = Fnv(q, basis);
                    ulong y = joint ? FnvMul(q, basisB, Golden) : 0;
                    for (int k = 0; k < hi.Length; k++)
                        if (Array.BinarySearch(keysHi[k], KeyHi(x, y, hi[k])) >= 0)
                            lh[k]++;

                    for (int k = 0; k < lo.Length; k++)
                        if (Array.BinarySearch(keysLo[k], KeyLo(x, y, lo[k])) >= 0)
                            ll[k]++;
                }

                lock (localHi)
                {
                    for (int k = 0; k < hi.Length; k++)
                        localHi[k] += lh[k];

                    for (int k = 0; k < lo.Length; k++)
                        localLo[k] += ll[k];

                    used += lu;
                }
            });

            counted[fi] += used;
            for (int k = 0; k < hi.Length; k++)
                obsHi[fi, k] += localHi[k];

            for (int k = 0; k < lo.Length; k++)
                obsLo[fi, k] += localLo[k];
        }
    }

    Console.WriteLine($"entries {n:N0}; {R} random bases; a false positive = an unlisted probe whose reduced hash equals one of the entries' reduced hashes");
    for (int fi = 0; fi < families.Length; fi++)
    {
        Console.WriteLine($"\n{families[fi].name}: {counted[fi]:N0} unlisted probes over {R} bases");
        for (int k = 0; k < hi.Length; k++)
        {
            double pHit = -double.ExpM1(n * double.LogP1(-Math.Pow(2, -Bits(hi[k]))));
            Console.WriteLine($"  top {hi[k]}{(joint ? "+" + hi[k] : "")} bits   {Z(obsHi[fi, k], counted[fi] * pHit)}");
        }

        for (int k = 0; k < lo.Length; k++)
        {
            double pHit = -double.ExpM1(n * double.LogP1(-Math.Pow(2, -Bits(lo[k]))));
            Console.WriteLine($"  low {lo[k]}{(joint ? "+" + lo[k] : "")} bits   {Z(obsLo[fi, k], counted[fi] * pHit)}");
        }
    }
}

// ---------------------------------------------------------------- scale: memory and lookup of one big set
string GenName(long i)
{
    ulong s = (ulong)i * 0x9E3779B97F4A7C15UL + 12345;
    string[] tlds = ["com", "net", "org", "io", "xyz", "top", "shop", "info"];
    int l1 = 3 + (int)(SplitMix(ref s) % 14);
    int l2 = 3 + (int)(SplitMix(ref s) % 10);
    return Lower(s, l1) + "." + Lower(s ^ 0xABCDEF, l2) + "." + tlds[(int)(SplitMix(ref s) % 8)];
}

void Scale(bool asString)
{
    long n = arg1;
    ulong basis = BasisFor(777);
    long baseline = Heap();
    Stopwatch sw = Stopwatch.StartNew();
    HashSet<string>? sset = asString ? new HashSet<string>((int)n) : null;
    HashSet<ulong>? uset = asString ? null : new HashSet<ulong>((int)n);
    for (long i = 0; i < n; i++)
    {
        string name = GenName(i);
        if (asString)
            sset!.Add(name);
        else
            uset!.Add(Fnv(name, basis));
    }

    sw.Stop();
    long heap = Heap() - baseline;
    long count = asString ? sset!.Count : uset!.Count;
    string[] hits = Enumerable.Range(0, 200_000).Select(i => GenName((i * 7919L) % n)).ToArray();
    string[] misses = Enumerable.Range(0, 200_000).Select(i => GenName(n + 1 + i)).ToArray();

    double Time(string[] qs)
    {
        long sum = 0;
        double[] runs = new double[5];
        for (int w = 0; w < 6; w++)
        {
            Stopwatch t = Stopwatch.StartNew();
            foreach (string q in qs)
            {
                string? d = q;
                while (d is not null)
                {
                    if (asString ? sset!.Contains(d) : uset!.Contains(Fnv(d, basis)))
                    {
                        sum++;
                        break;
                    }

                    d = Parent(d);
                }
            }

            t.Stop();
            if (w > 0)
                runs[w - 1] = t.Elapsed.TotalMilliseconds * 1e6 / qs.Length;
        }

        GC.KeepAlive(sum.ToString());
        Array.Sort(runs);
        return runs[2];
    }

    double miss = Time(misses);
    double hit = Time(hits);
    Console.WriteLine($"{(asString ? "HashSet<string>" : "HashSet<ulong> "),-16} N {n,12:N0} (unique {count:N0})  heap {heap / 1048576.0,8:F1} MiB  {heap / (double)n,6:F1} B/entry  build {sw.Elapsed.TotalSeconds,5:F1} s  miss {miss,6:F0} ns  hit {hit,6:F0} ns");
    GC.KeepAlive(sset);
    GC.KeepAlive(uset);
}

// ---------------------------------------------------------------- shape: worst-case query shapes against 21 per-list sets
void Shape()
{
    string[] files = Directory.GetFiles("lists", "*.txt").Where(f => !f.EndsWith("union.txt")).Order().ToArray();
    ulong basis = BasisFor(321);
    HashSet<string>[] a = files.Select(f => new HashSet<string>(Load(f))).ToArray();
    HashSet<ulong>[] b = files.Select(f => new HashSet<ulong>(Load(f).Select(s => Fnv(s, basis)).ToArray())).ToArray();
    Console.WriteLine($"{files.Length} per-list sets; the app's scan: lists in order, label levels inside each list");

    int FindA(string q)
    {
        for (int i = 0; i < a.Length; i++)
        {
            string? d = q;
            while (d is not null)
            {
                if (a[i].Contains(d))
                    return i;

                d = Parent(d);
            }
        }

        return -1;
    }

    int FindB(string q)
    {
        for (int i = 0; i < b.Length; i++)
        {
            string? d = q;
            while (d is not null)
            {
                if (b[i].Contains(Fnv(d, basis)))
                    return i;

                d = Parent(d);
            }
        }

        return -1;
    }

    (string name, string query, int reps)[] shapes =
    [
        ("typical: 3 labels, not listed", "www.example-unlisted-name.com", 200_000),
        ("4 labels of 63 characters", string.Join(".", Enumerable.Repeat(new string('a', 63), 4)), 20_000),
        ("127 one-character labels (253 characters)", string.Join(".", Enumerable.Repeat("a", 127)), 2_000),
        ("deep subdomain of a listed name", "a.b.c.d.e.f.g.h." + a[0].First(), 100_000),
    ];

    foreach ((string name, string q, int reps) in shapes)
    {
        long sum = 0;
        Stopwatch t = Stopwatch.StartNew();
        for (int i = 0; i < reps; i++)
            sum += FindA(q);

        t.Stop();
        double nsA = t.Elapsed.TotalMilliseconds * 1e6 / reps;
        t.Restart();
        for (int i = 0; i < reps; i++)
            sum += FindB(q);

        t.Stop();
        double nsB = t.Elapsed.TotalMilliseconds * 1e6 / reps;
        GC.KeepAlive(sum.ToString());
        Console.WriteLine($"  {name,-44} HashSet<string> {nsA,10:F0} ns   HashSet<ulong> {nsB,10:F0} ns   ratio {nsB / nsA,5:F2}");
    }
}

static (ulong, ulong) FnvPair(string s, ulong basisA, ulong basisB)
{
    ulong a = basisA;
    ulong b = basisB;
    foreach (char c in s)
    {
        a = (a ^ c) * Prime;
        b = (b ^ c) * 0x9E3779B97F4A7C15UL;
    }

    return (a, b);
}

static UInt128 Key128(string s, ulong basisA, ulong basisB)
{
    (ulong a, ulong b) = FnvPair(s, basisA, basisB);
    return ((UInt128)a << 64) | b;
}

static (uint, uint, uint) Key96(string s, ulong basisA, ulong basisB)
{
    (ulong a, ulong b) = FnvPair(s, basisA, basisB);
    return ((uint)(a >> 32), (uint)a, (uint)(b >> 32));
}

// ---------------------------------------------------------------- width: cost of a 128-bit key
void Width(string kind)
{
    string[] files = Directory.GetFiles("lists", "*.txt").Where(f => !f.EndsWith("union.txt")).Order().ToArray();
    ulong b1 = BasisFor(11), b2 = BasisFor(12);
    long baseline = Heap();
    object sets;
    Func<string, bool>[] contains;
    switch (kind)
    {
        case "string":
            {
                HashSet<string>[] s = files.Select(f => new HashSet<string>(Load(f))).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(d))).ToArray();
                break;
            }

        case "u64":
            {
                HashSet<ulong>[] s = files.Select(f => new HashSet<ulong>(Load(f).Select(x => Fnv(x, b1)).ToArray())).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(Fnv(d, b1)))).ToArray();
                break;
            }

        case "u128":
            {
                HashSet<UInt128>[] s = files.Select(f => new HashSet<UInt128>(Load(f).Select(x => Key128(x, b1, b2)).ToArray())).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(Key128(d, b1, b2)))).ToArray();
                break;
            }

        case "tuple":
            {
                HashSet<(ulong, ulong)>[] s = files.Select(f => new HashSet<(ulong, ulong)>(Load(f).Select(x => FnvPair(x, b1, b2)).ToArray())).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(FnvPair(d, b1, b2)))).ToArray();
                break;
            }

        case "tuple-cmp":
            {
                PairComparer cmp = new PairComparer();
                HashSet<(ulong, ulong)>[] s = files.Select(f => new HashSet<(ulong, ulong)>(Load(f).Select(x => FnvPair(x, b1, b2)).ToArray(), cmp)).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(FnvPair(d, b1, b2)))).ToArray();
                break;
            }

        case "tuple3":
            {
                HashSet<(uint, uint, uint)>[] s = files.Select(f => new HashSet<(uint, uint, uint)>(Load(f).Select(x => Key96(x, b1, b2)).ToArray())).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(Key96(d, b1, b2)))).ToArray();
                break;
            }

        case "tuple3-cmp":
            {
                TripleComparer cmp = new TripleComparer();
                HashSet<(uint, uint, uint)>[] s = files.Select(f => new HashSet<(uint, uint, uint)>(Load(f).Select(x => Key96(x, b1, b2)).ToArray(), cmp)).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(Key96(d, b1, b2)))).ToArray();
                break;
            }

        case "front":
            {
                int block = int.Parse(Environment.GetEnvironmentVariable("BLOCK") ?? "32");
                FrontCodedSet[] s = files.Select(f => new FrontCodedSet(Load(f), block)).ToArray();
                Console.WriteLine($"front: {s.Sum(x => x.Bytes) / 1048576.0:F1} MiB encoded (data + block offsets) for {files.Sum(f => Load(f).Length):N0} names, average name {files.SelectMany(Load).Average(n => (double)n.Length):F2} chars");
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d =>
                {
                    Span<byte> buf = stackalloc byte[256];
                    int n = Encoding.UTF8.GetBytes(d, buf);
                    return x.Contains(buf[..n]);
                })).ToArray();
                break;
            }

        case "open64":
            {
                double load = double.Parse(Environment.GetEnvironmentVariable("LOAD") ?? "0.75", System.Globalization.CultureInfo.InvariantCulture);
                OpenSet64[] s = files.Select(f => new OpenSet64(Load(f).Select(x => Fnv(x, b1)).ToArray(), load)).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(Fnv(d, b1)))).ToArray();
                break;
            }

        case "open128":
            {
                double load = double.Parse(Environment.GetEnvironmentVariable("LOAD") ?? "0.75", System.Globalization.CultureInfo.InvariantCulture);
                OpenSet128[] s = files.Select(f => new OpenSet128(Load(f).Select(x => FnvPair(x, b1, b2)).ToArray(), load)).ToArray();
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d => x.Contains(FnvPair(d, b1, b2)))).ToArray();
                break;
            }

        default:
            {
                int dropped = 0;
                Dictionary<ulong, uint>[] s = files.Select(f =>
                {
                    string[] names = Load(f);
                    Dictionary<ulong, uint> dict = new Dictionary<ulong, uint>(names.Length);
                    foreach (string x in names)
                    {
                        (ulong k, ulong c) = FnvPair(x, b1, b2);
                        if (!dict.TryAdd(k, (uint)(c >> 32)))
                            dropped++;
                    }

                    return dict;
                }).ToArray();
                Console.WriteLine($"dict96: {dropped} entries share their 64-bit key with an earlier entry (same name listed twice or a real 64-bit collision)");
                sets = s;
                contains = s.Select(x => (Func<string, bool>)(d =>
                {
                    (ulong k, ulong c) = FnvPair(d, b1, b2);
                    return x.TryGetValue(k, out uint check) && check == (uint)(c >> 32);
                })).ToArray();
                break;
            }
    }

    long heap = Heap() - baseline;
    string[] all = Load("lists/union.txt");
    Random rng = new Random(5);
    string[] hits = Enumerable.Range(0, 200_000).Select(_ => all[rng.Next(all.Length)]).ToArray();
    string[] misses = Enumerable.Range(0, 200_000).Select(i => GenName(100_000_000L + i)).ToArray();

    double Time(string[] qs)
    {
        long sum = 0;
        double[] runs = new double[5];
        for (int w = 0; w < 6; w++)
        {
            Stopwatch t = Stopwatch.StartNew();
            foreach (string q in qs)
            {
                for (int i = 0; i < contains.Length; i++)
                {
                    string? d = q;
                    bool found = false;
                    while (d is not null)
                    {
                        if (contains[i](d))
                        {
                            found = true;
                            break;
                        }

                        d = Parent(d);
                    }

                    if (found)
                    {
                        sum++;
                        break;
                    }
                }
            }

            t.Stop();
            if (w > 0)
                runs[w - 1] = t.Elapsed.TotalMilliseconds * 1e6 / qs.Length;
        }

        GC.KeepAlive(sum.ToString());
        Array.Sort(runs);
        return runs[2];
    }

    double miss = Time(misses);
    double hit = Time(hits);
    Console.WriteLine($"{kind,-7} 21 per-list sets  heap {heap / 1048576.0,7:F1} MiB  miss {miss,7:F0} ns  hit {hit,7:F0} ns");
    GC.KeepAlive(sets);
}

// ---------------------------------------------------------------- dense: every string up to 5 characters over a 38-character alphabet
void Dense()
{
    const string Alpha = "abcdefghijklmnopqrstuvwxyz0123456789-.";
    int a = Alpha.Length;
    long[] counts = new long[6];
    long total = 0;
    long pw = 1;
    for (int len = 1; len <= 5; len++)
    {
        pw *= a;
        counts[len] = pw;
        total += pw;
    }

    Console.WriteLine($"every string of 1 to 5 characters over {a} characters: {total:N0} strings; expected colliding pairs per base at width k = C(n,2)/2^k");
    double pairsTotal = (double)total * (total - 1) / 2;
    bool joint = mode.EndsWith("128");
    int[] widths = joint ? [20, 22, 24] : [40, 44, 48, 52, 56, 64];
    long[] obs = new long[widths.Length];
    const int Bases = 2;

    ulong[] Gen(ulong basis, ulong mul)
    {
        ulong[] h = new ulong[total];
        long offset = 0;
        for (int len = 1; len <= 5; len++)
        {
            long count = counts[len];
            long off = offset;
            int l = len;
            Parallel.For(0, Threads, new ParallelOptions { MaxDegreeOfParallelism = Threads }, t =>
            {
                for (long i = t; i < count; i += Threads)
                {
                    long idx = i;
                    ulong hash = basis;
                    for (int p = 0; p < l; p++)
                    {
                        hash = (hash ^ Alpha[(int)(idx % a)]) * mul;
                        idx /= a;
                    }

                    h[off + i] = hash;
                }
            });
            offset += count;
        }

        return h;
    }

    for (int b = 0; b < Bases; b++)
    {
        ulong[] h = Gen(BasisFor(20000 + b), Prime);
        if (!joint)
        {
            Array.Sort(h);
            for (int k = 0; k < widths.Length; k++)
                obs[k] += PairsInSorted(h, 64 - widths[k]);

            continue;
        }

        ulong[] g = Gen(BasisFor(21000 + b), Golden);
        ulong[] key = new ulong[total];
        for (int k = 0; k < widths.Length; k++)
        {
            int w = widths[k];
            for (long e = 0; e < total; e++)
                key[e] = ((h[e] >> (64 - w)) << w) | (g[e] >> (64 - w));

            Array.Sort(key);
            obs[k] += PairsInSorted(key, 0);
        }
    }

    for (int k = 0; k < widths.Length; k++)
        Console.WriteLine($"  top {widths[k]}{(joint ? "+" + widths[k] : "")} bits   {Z(obs[k], Bases * pairsTotal / Math.Pow(2, joint ? 2 * widths[k] : widths[k]))}");
}

// ---------------------------------------------------------------- longsub: every one- and two-position substitution in a 250-character name
void LongSub()
{
    const string Alpha = "abcdefghijklmnopqrstuvwxyz0123456789-";
    int a = Alpha.Length;
    const int Len = 250;
    ulong seed = 99;
    char[] baseChars = new char[Len];
    for (int i = 0; i < Len; i++)
        baseChars[i] = Alpha[(int)(SplitMix(ref seed) % (ulong)a)];

    long singles = (long)Len * (a - 1);
    long[] offsets = new long[Len];
    long total = singles;
    for (int i = 0; i < Len - 1; i++)
    {
        offsets[i] = total;
        total += (long)(Len - 1 - i) * (a - 1) * (a - 1);
    }

    Console.WriteLine($"one- and two-position substitutions in a {Len}-character name: {total:N0} distinct strings; expected colliding pairs per base at width k = C(n,2)/2^k");
    double pairsTotal = (double)total * (total - 1) / 2;
    bool joint = mode.EndsWith("128");
    int[] widths = joint ? [20, 22, 24] : [40, 44, 48, 52, 56, 64];
    long[] obs = new long[widths.Length];
    const int Bases = 2;

    ulong[] Gen(ulong basis, ulong mul)
    {
        ulong[] h = new ulong[total];
        ulong[] prefix = new ulong[Len + 1];
        prefix[0] = basis;
        for (int i = 0; i < Len; i++)
            prefix[i + 1] = (prefix[i] ^ baseChars[i]) * mul;

        // singles
        Parallel.For(0, Len, new ParallelOptions { MaxDegreeOfParallelism = Threads }, i =>
        {
            long o = (long)i * (a - 1);
            foreach (char c in Alpha)
            {
                if (c == baseChars[i])
                    continue;

                ulong hash = (prefix[i] ^ c) * mul;
                for (int p = i + 1; p < Len; p++)
                    hash = (hash ^ baseChars[p]) * mul;

                h[o++] = hash;
            }
        });

        // pairs
        Parallel.For(0, Len - 1, new ParallelOptions { MaxDegreeOfParallelism = Threads }, i =>
        {
            long o = offsets[i];
            foreach (char ci in Alpha)
            {
                if (ci == baseChars[i])
                    continue;

                ulong hi = (prefix[i] ^ ci) * mul;
                for (int j = i + 1; j < Len; j++)
                {
                    ulong mid = hi;
                    for (int p = i + 1; p < j; p++)
                        mid = (mid ^ baseChars[p]) * mul;

                    foreach (char cj in Alpha)
                    {
                        if (cj == baseChars[j])
                            continue;

                        ulong hash = (mid ^ cj) * mul;
                        for (int p = j + 1; p < Len; p++)
                            hash = (hash ^ baseChars[p]) * mul;

                        h[o++] = hash;
                    }
                }
            }
        });

        return h;
    }

    for (int b = 0; b < Bases; b++)
    {
        ulong[] h = Gen(BasisFor(30000 + b), Prime);
        if (!joint)
        {
            Array.Sort(h);
            for (int k = 0; k < widths.Length; k++)
                obs[k] += PairsInSorted(h, 64 - widths[k]);

            continue;
        }

        ulong[] g = Gen(BasisFor(31000 + b), Golden);
        ulong[] key = new ulong[total];
        for (int k = 0; k < widths.Length; k++)
        {
            int w = widths[k];
            for (long e = 0; e < total; e++)
                key[e] = ((h[e] >> (64 - w)) << w) | (g[e] >> (64 - w));

            Array.Sort(key);
            obs[k] += PairsInSorted(key, 0);
        }
    }

    for (int k = 0; k < widths.Length; k++)
        Console.WriteLine($"  top {widths[k]}{(joint ? "+" + widths[k] : "")} bits   {Z(obs[k], Bases * pairsTotal / Math.Pow(2, joint ? 2 * widths[k] : widths[k]))}");
}

// ---------------------------------------------------------------- entrysize: bytes per entry of a HashSet<T> for keys of 8 to 16 bytes
void EntrySize()
{
    const int N = 2_000_000;
    Console.WriteLine($"HashSet<T> with {N:N0} distinct keys and the exact capacity; heap bytes per entry (live arrays: buckets + entries)");
    Console.WriteLine($"sizeof: ulong {System.Runtime.CompilerServices.Unsafe.SizeOf<ulong>()}, (ulong,ulong) {System.Runtime.CompilerServices.Unsafe.SizeOf<(ulong, ulong)>()}, (uint,uint,uint) {System.Runtime.CompilerServices.Unsafe.SizeOf<(uint, uint, uint)>()}, Key96 {System.Runtime.CompilerServices.Unsafe.SizeOf<Key96>()}, UInt128 {System.Runtime.CompilerServices.Unsafe.SizeOf<UInt128>()}");

    void Run<T>(string name, Func<int, T> make)
    {
        long before = Heap();
        HashSet<T> set = new HashSet<T>(N);
        for (int i = 0; i < N; i++)
            set.Add(make(i));

        long after = Heap();
        Console.WriteLine($"{name,-22} {(after - before) / (double)N,6:F2} B/entry   {(after - before) / 1048576.0,7:F1} MiB");
        GC.KeepAlive(set);
    }

    Run("ulong", i => (ulong)i * 0x9E3779B97F4A7C15UL);
    Run("(ulong,ulong)", i => ((ulong)i * 0x9E3779B97F4A7C15UL, (ulong)i));
    Run("UInt128", i => new UInt128((ulong)i, (ulong)i * 31));
    Run("(uint,uint,uint)", i => ((uint)i * 2654435761u, (uint)i, (uint)i * 7u));
    Run("Key96 (custom struct)", i => new Key96((uint)i * 2654435761u, (uint)i, (uint)i * 7u));
}

switch (mode)
{
    case "probe128": Probe(); break;
    case "dense128": Dense(); break;
    case "longsub128": LongSub(); break;
    case "pair128": Pair128(); break;
    case "collide": Collide(); break;
    case "persist": Persistence(); break;
    case "probe": Probe(); break;
    case "dense": Dense(); break;
    case "longsub": LongSub(); break;
    case "scale-string": Scale(true); break;
    case "scale-u64": Scale(false); break;
    case "shape": Shape(); break;
    case "width-string": Width("string"); break;
    case "width-u64": Width("u64"); break;
    case "width-u128": Width("u128"); break;
    case "width-tuple": Width("tuple"); break;
    case "width-tuple-cmp": Width("tuple-cmp"); break;
    case "width-dict96": Width("dict96"); break;
    case "pair96": Pair96(); break;
    case "width-tuple3": Width("tuple3"); break;
    case "width-tuple3-cmp": Width("tuple3-cmp"); break;
    case "entrysize": EntrySize(); break;
    case "width-open64": Width("open64"); break;
    case "width-open128": Width("open128"); break;
    case "width-front": Width("front"); break;
    default: Console.WriteLine("modes: collide pair128 pair96 persist probe probe128 dense dense128 longsub longsub128 scale-string N scale-u64 N shape width-string width-u64 width-u128 width-tuple width-tuple-cmp width-tuple3 width-tuple3-cmp width-dict96"); break;
}

sealed class PairComparer : IEqualityComparer<(ulong, ulong)>
{
    public bool Equals((ulong, ulong) x, (ulong, ulong) y) => x == y;

    public int GetHashCode((ulong, ulong) k) => (int)k.Item1 ^ (int)(k.Item1 >> 32);
}

sealed class TripleComparer : IEqualityComparer<(uint, uint, uint)>
{
    public bool Equals((uint, uint, uint) x, (uint, uint, uint) y) => x == y;

    public int GetHashCode((uint, uint, uint) k) => (int)k.Item1;
}

readonly struct Key96 : IEquatable<Key96>
{
    public readonly uint A;
    public readonly uint B;
    public readonly uint C;

    public Key96(uint a, uint b, uint c)
    {
        A = a;
        B = b;
        C = c;
    }

    public bool Equals(Key96 other) => A == other.A && B == other.B && C == other.C;

    public override bool Equals(object? obj) => obj is Key96 k && Equals(k);

    public override int GetHashCode() => (int)A;
}

// Linear-probing sets of raw hashes, as in Cloudflare's mmuniq-hash ("When Bloom filters don't bloom"):
// no bucket array, no next link, no stored hash code; a slot is 8 bytes (64-bit key) or 16 bytes (128-bit key).
sealed class OpenSet64
{
    readonly ulong[] _t;

    public OpenSet64(ulong[] hashes, double load)
    {
        _t = new ulong[(int)Math.Ceiling(hashes.Length / load) + 1];
        foreach (ulong h in hashes)
        {
            ulong k = h == 0 ? 1 : h;
            int i = Slot(k);
            while (_t[i] != 0 && _t[i] != k)
                i = i + 1 == _t.Length ? 0 : i + 1;

            _t[i] = k;
        }
    }

    int Slot(ulong k) => (int)(((ulong)(uint)(k >> 32) * (ulong)(uint)_t.Length) >> 32);

    public bool Contains(ulong h)
    {
        ulong k = h == 0 ? 1 : h;
        int i = Slot(k);
        ulong v;
        while ((v = _t[i]) != 0)
        {
            if (v == k)
                return true;

            i = i + 1 == _t.Length ? 0 : i + 1;
        }

        return false;
    }
}

sealed class OpenSet128
{
    readonly ulong[] _t;
    readonly int _cap;

    public OpenSet128((ulong, ulong)[] hashes, double load)
    {
        _cap = (int)Math.Ceiling(hashes.Length / load) + 1;
        _t = new ulong[2 * _cap];
        foreach ((ulong a0, ulong b) in hashes)
        {
            ulong a = a0 == 0 && b == 0 ? 1 : a0;
            int i = Slot(a);
            while ((_t[2 * i] != 0 || _t[2 * i + 1] != 0) && (_t[2 * i] != a || _t[2 * i + 1] != b))
                i = i + 1 == _cap ? 0 : i + 1;

            _t[2 * i] = a;
            _t[2 * i + 1] = b;
        }
    }

    int Slot(ulong a) => (int)(((ulong)(uint)(a >> 32) * (ulong)(uint)_cap) >> 32);

    public bool Contains((ulong, ulong) h)
    {
        ulong a = h.Item1 == 0 && h.Item2 == 0 ? 1 : h.Item1;
        ulong b = h.Item2;
        int i = Slot(a);
        while (true)
        {
            ulong x = _t[2 * i], y = _t[2 * i + 1];
            if (x == 0 && y == 0)
                return false;

            if (x == a && y == b)
                return true;

            i = i + 1 == _cap ? 0 : i + 1;
        }
    }
}

// Exact set of sorted UTF-8 names in blocks, each block starts with a full key and the rest drop the prefix shared with the
// previous key: [lcp byte][suffix length byte][suffix]. Same layout as LevelDB blocks (restart interval = block size).
sealed class FrontCodedSet
{
    readonly byte[] _data;
    public long Bytes => _data.Length + 4L * _blockAt.Length;
    readonly int[] _blockAt;

    public FrontCodedSet(string[] names, int block)
    {
        byte[][] keys = names.Distinct(StringComparer.Ordinal).Select(Encoding.UTF8.GetBytes).ToArray();
        Array.Sort(keys, (a, b) => a.AsSpan().SequenceCompareTo(b));
        List<int> blockAt = new List<int>(keys.Length / block + 1);
        MemoryStream data = new MemoryStream(keys.Length * 14);
        byte[] prev = [];
        for (int i = 0; i < keys.Length; i++)
        {
            byte[] key = keys[i];
            if (i % block == 0)
            {
                blockAt.Add((int)data.Length);
                data.WriteByte((byte)key.Length);
                data.Write(key);
            }
            else
            {
                int lcp = 0;
                while (lcp < prev.Length && lcp < key.Length && prev[lcp] == key[lcp])
                    lcp++;

                data.WriteByte((byte)lcp);
                data.WriteByte((byte)(key.Length - lcp));
                data.Write(key, lcp, key.Length - lcp);
            }

            prev = key;
        }

        _data = data.ToArray();
        _blockAt = blockAt.ToArray();
    }

    public bool Contains(ReadOnlySpan<byte> key)
    {
        int lo = 0, hi = _blockAt.Length - 1;
        if (hi < 0)
            return false;

        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            int p = _blockAt[mid];
            if (new ReadOnlySpan<byte>(_data, p + 1, _data[p]).SequenceCompareTo(key) <= 0)
                lo = mid;
            else
                hi = mid - 1;
        }

        int pos = _blockAt[lo];
        int end = lo + 1 < _blockAt.Length ? _blockAt[lo + 1] : _data.Length;
        Span<byte> cur = stackalloc byte[256];
        int curLen = _data[pos];
        new ReadOnlySpan<byte>(_data, pos + 1, curLen).CopyTo(cur);
        pos += 1 + curLen;
        while (true)
        {
            int cmp = cur[..curLen].SequenceCompareTo(key);
            if (cmp == 0)
                return true;

            if (cmp > 0 || pos >= end)
                return false;

            int lcp = _data[pos], suffix = _data[pos + 1];
            new ReadOnlySpan<byte>(_data, pos + 2, suffix).CopyTo(cur[lcp..]);
            curLen = lcp + suffix;
            pos += 2 + suffix;
        }
    }
}
