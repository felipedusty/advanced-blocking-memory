// Lookup cost of the set structures on the real biggest list, in isolation from the DNS server.
//
//   dotnet run -c Release -- <list file> [queries] [repetitions]
//
// Reads the ||domain^ names of one list, builds each structure from them and times `queries` lookups of
// listed names (hits) and of names that are not listed (misses) in random order, `repetitions` times,
// printing the median nanoseconds per lookup. The query hashes are computed before the timer starts, so the
// table isolates the search; the last block times the hash of a name on its own.
using System.Diagnostics;
using System.Security.Cryptography;

string path = args[0];
int queryCount = args.Length > 1 ? int.Parse(args[1]) : 1_000_000;
int repetitions = args.Length > 2 ? int.Parse(args[2]) : 7;

List<string> names = [];
foreach (string raw in File.ReadLines(path))
{
    if (!raw.StartsWith("||", StringComparison.Ordinal))
        continue;

    int i = raw.IndexOf('^');
    if (i > 2)
        names.Add(raw.Substring(2, i - 2));
}

names = names.Distinct().ToList();
int n = names.Count;
Console.WriteLine($"{n} names, {Environment.ProcessorCount} cpus, {RuntimeInformation()}");

ulong basis = BitConverter.ToUInt64(RandomNumberGenerator.GetBytes(8)) | 1UL;

ulong Hash(string s)
{
    ulong h = basis;
    foreach (char c in s)
        h = (h ^ c) * 1099511628211UL;
    return h;
}

ulong[] hashes = names.Select(Hash).ToArray();
Array.Sort(hashes);

Random random = new Random(12345);
string[] hitNames = new string[queryCount];
string[] missNames = new string[queryCount];
for (int q = 0; q < queryCount; q++)
{
    hitNames[q] = new string(names[random.Next(n)]);
    missNames[q] = "q" + names[random.Next(n)];
}

ulong[] hitHashes = hitNames.Select(Hash).ToArray();
ulong[] missHashes = missNames.Select(Hash).ToArray();

// structures
HashSet<string> stringSet = new HashSet<string>(names);
HashSet<ulong> ulongSet = new HashSet<ulong>(hashes);

int bits = Math.Max(1, 32 - System.Numerics.BitOperations.LeadingZeroCount((uint)(n / 4)));
uint[] index = new uint[(1 << bits) + 1];
{
    int pos = 0;
    for (int p = 0; p < index.Length; p++)
    {
        while (pos < n && (hashes[pos] >> (64 - bits)) < (ulong)p)
            pos++;
        index[p] = (uint)pos;
    }
}

int shift = 64 - bits;

int tableSize = 1;
while (tableSize < 2L * n)
    tableSize <<= 1;
ulong[] table = new ulong[tableSize];
foreach (ulong h in hashes)
{
    int s = (int)(h >> 7) & (tableSize - 1);
    while (table[s] != 0)
        s = (s + 1) & (tableSize - 1);
    table[s] = h | 1UL; // 0 marks an empty slot
}

bool BinaryContains(ulong h) => hashes.AsSpan().BinarySearch(h) >= 0;

bool IndexContains(ulong h)
{
    int p = (int)(h >> shift);
    int start = (int)index[p];
    return hashes.AsSpan(start, (int)index[p + 1] - start).BinarySearch(h) >= 0;
}

bool InterpContains(ulong h)
{
    ReadOnlySpan<ulong> a = hashes;
    int low = 0, high = a.Length - 1;
    for (int i = 0; i < 4 && low <= high && h >= a[low] && h <= a[high]; i++)
    {
        ulong range = a[high] - a[low];
        if (range == 0)
            return true;
        int mid = low + (int)((double)(h - a[low]) / range * (high - low));
        if (a[mid] == h)
            return true;
        if (a[mid] < h)
            low = mid + 1;
        else
            high = mid - 1;
    }

    return low <= high && a.Slice(low, high - low + 1).BinarySearch(h) >= 0;
}

bool TableContains(ulong h)
{
    ulong key = h | 1UL;
    int s = (int)(h >> 7) & (tableSize - 1);
    while (true)
    {
        ulong v = table[s];
        if (v == key)
            return true;
        if (v == 0)
            return false;
        s = (s + 1) & (tableSize - 1);
    }
}

double Median(List<double> values)
{
    values.Sort();
    return values[values.Count / 2];
}

void Time(string label, string[] hitInputs, string[] missInputs, Func<string, bool> stringContains, ulong[]? hitKeys, ulong[]? missKeys, Func<ulong, bool>? keyContains, double bytesPerEntry)
{
    double Run(string[] strings, ulong[]? keys, out int found)
    {
        List<double> samples = [];
        int total = 0;
        for (int r = 0; r < repetitions; r++)
        {
            int count = 0;
            long t0 = Stopwatch.GetTimestamp();
            if (keys is null)
            {
                foreach (string s in strings)
                    if (stringContains(s))
                        count++;
            }
            else
            {
                foreach (ulong k in keys)
                    if (keyContains!(k))
                        count++;
            }

            long t1 = Stopwatch.GetTimestamp();
            samples.Add((t1 - t0) * 1e9 / Stopwatch.Frequency / queryCount);
            total = count;
        }

        found = total;
        return Median(samples);
    }

    double hit = Run(hitInputs, hitKeys, out int hits);
    double miss = Run(missInputs, missKeys, out int misses);
    Console.WriteLine($"{label,-34} hit {hit,7:F1} ns   miss {miss,7:F1} ns   (found {hits} of {queryCount} / {misses} of {queryCount})   {bytesPerEntry,5:F1} B/entry");
}

// prefix index density: hashes per start (the index costs 4 bytes per start)
foreach (int density in new[] { 1, 2, 4, 8, 16, 32, 64 })
{
    int b = Math.Max(1, 32 - System.Numerics.BitOperations.LeadingZeroCount((uint)(n / density)));
    uint[] starts = new uint[(1 << b) + 1];
    foreach (ulong h in hashes)
        starts[(int)(h >> (64 - b)) + 1]++;
    for (int i = 1; i < starts.Length; i++)
        starts[i] += starts[i - 1];

    int sh = 64 - b;
    bool Contains(ulong h)
    {
        int p = (int)(h >> sh);
        int start = (int)starts[p];
        return hashes.AsSpan(start, (int)starts[p + 1] - start).BinarySearch(h) >= 0;
    }

    Time($"index, {density} hashes per start", hitNames, missNames, _ => false, hitHashes, missHashes, Contains, 8 + 4.0 * starts.Length / n);
}

// warm up the JIT with a short pass of everything
Time("warm-up", hitNames[..10000], missNames[..10000], stringSet.Contains, null, null, null, 0);

Time("HashSet<string>", hitNames, missNames, stringSet.Contains, null, null, null, 80);
Time("HashSet<ulong>", hitNames, missNames, _ => false, hitHashes, missHashes, ulongSet.Contains, 20);
Time("sorted ulong[] binary search", hitNames, missNames, _ => false, hitHashes, missHashes, BinaryContains, 8);
Time("sorted + prefix index", hitNames, missNames, _ => false, hitHashes, missHashes, IndexContains, 8 + 4.0 * index.Length / n);
Time("sorted + interpolation", hitNames, missNames, _ => false, hitHashes, missHashes, InterpContains, 8);
Time("open addressing ulong[] (load .5)", hitNames, missNames, _ => false, hitHashes, missHashes, TableContains, 8.0 * tableSize / n);

// the hash of a name on its own
{
    List<double> samples = [];
    ulong sink = 0;
    for (int r = 0; r < repetitions; r++)
    {
        long t0 = Stopwatch.GetTimestamp();
        foreach (string s in hitNames)
            sink ^= Hash(s);
        long t1 = Stopwatch.GetTimestamp();
        samples.Add((t1 - t0) * 1e9 / Stopwatch.Frequency / queryCount);
    }

    double fnv = Median(samples);

    samples = [];
    int sinkInt = 0;
    for (int r = 0; r < repetitions; r++)
    {
        long t0 = Stopwatch.GetTimestamp();
        foreach (string s in hitNames)
            sinkInt ^= s.GetHashCode();
        long t1 = Stopwatch.GetTimestamp();
        samples.Add((t1 - t0) * 1e9 / Stopwatch.Frequency / queryCount);
    }

    Console.WriteLine($"hash of a name: FNV-1a {fnv:F1} ns, string.GetHashCode {Median(samples):F1} ns (sinks {sink ^ (ulong)sinkInt})");
}

static string RuntimeInformation() => System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture + " " + System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription;
