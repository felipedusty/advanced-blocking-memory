#!/usr/bin/env bash
# Boundary tests for HashIndex (patch/experiments/hash64-index2) in the built app: the sorted list of 64-bit hashes
# with a prefix index. The class is a private nested type, so the test loads the real assembly and drives it through
# reflection, then compares it with a HashSet<ulong>.
#
#   lab/hash-index-test.sh
#
# Requires lab/.work/out-patched built with PATCH_DIR=patch/experiments/hash64-index2. The record goes to
# results/hash-index.boundary.txt, or to $HASH_INDEX_OUT.
set -euo pipefail
cd "$(dirname "$0")/.."

out=lab/.work/out-patched
[ -f "$out/AdvancedBlockingApp.dll" ] || {
	echo "missing $out/AdvancedBlockingApp.dll; run PATCH_DIR=patch/experiments/hash64-index2 lab/build-app.sh patched" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$out"/*.dll "$tmp"/
work=$PWD/lab/.work
cp "$work/DnsServer/DnsServerCore.ApplicationCommon/bin/Release/DnsServerCore.ApplicationCommon.dll" "$tmp"/ 2>/dev/null || true
cp "$work"/TechnitiumLibrary/bin/TechnitiumLibrary.Net.dll "$tmp"/ 2>/dev/null || true
[ -f "$tmp/DnsServerCore.ApplicationCommon.dll" ] && [ -f "$tmp/TechnitiumLibrary.Net.dll" ] || {
	echo "missing DnsServerCore.ApplicationCommon.dll or TechnitiumLibrary.Net.dll; run lab/build-app.sh patched" >&2
	exit 1
}

cat >"$tmp/hash-index-test.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>hash-index-test</AssemblyName>
  </PropertyGroup>
</Project>
EOF

cat >"$tmp/Program.cs" <<'EOF'
using System.Reflection;
using System.Runtime.Loader;

string dllPath = Environment.GetEnvironmentVariable("HASH_INDEX_DLL")
    ?? throw new InvalidOperationException("HASH_INDEX_DLL is not set");
string dllDir = Path.GetDirectoryName(Path.GetFullPath(dllPath))!;

AssemblyLoadContext.Default.Resolving += (context, name) =>
{
    string candidate = Path.Combine(dllDir, name.Name + ".dll");
    return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
};

Type type = Assembly.LoadFrom(dllPath).GetType("AdvancedBlocking.App+HashIndex", throwOnError: true)!;
const BindingFlags All = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
MethodInfo contains = type.GetMethod("Contains", All)!;
FieldInfo shiftField = type.GetField("_shift", All)!;

int failures = 0;

void Check(bool ok, string what)
{
    if (ok)
    {
        Console.WriteLine($"ok: {what}");
    }
    else
    {
        failures++;
        Console.Error.WriteLine($"FAIL: {what}");
    }
}

object Build(IEnumerable<ulong> hashes) => Activator.CreateInstance(type, All, null, new object[] { new List<ulong>(hashes) }, null)!;
bool Has(object index, ulong hash) => (bool)contains.Invoke(index, new object[] { hash })!;

// Number of probes that disagree with the model, over every member, its two neighbours and some random values.
int Mismatches(object index, HashSet<ulong> model, Random rng, int randomProbes)
{
    int bad = 0;
    foreach (ulong v in model)
    {
        foreach (ulong p in new[] { v, v - 1, v + 1 })
            if (Has(index, p) != model.Contains(p))
                bad++;
    }
    for (int i = 0; i < randomProbes; i++)
    {
        ulong p = rng.NextUInt64();
        if (Has(index, p) != model.Contains(p))
            bad++;
    }
    return bad;
}

Random rng = new Random(20261103);

object empty = Build(Array.Empty<ulong>());
Check(!Has(empty, 0) && !Has(empty, 1) && !Has(empty, ulong.MaxValue) && !Has(empty, rng.NextUInt64()),
    "an empty index contains nothing, including 0 and ulong.MaxValue");

object single = Build(new[] { 0x8000_0000_0000_0001UL });
Check(Has(single, 0x8000_0000_0000_0001UL) && !Has(single, 0x8000_0000_0000_0000UL) && !Has(single, 0x8000_0000_0000_0002UL)
        && !Has(single, 0) && !Has(single, ulong.MaxValue),
    "a one-entry index finds only the entry, not its neighbours or the extremes");

object extremes = Build(new[] { ulong.MaxValue, 0UL });
Check(Has(extremes, 0) && Has(extremes, ulong.MaxValue) && !Has(extremes, 1) && !Has(extremes, ulong.MaxValue - 1),
    "0 and ulong.MaxValue (first and last bucket) are stored and found, and nothing next to them");

object duplicates = Build(new ulong[] { 5, 5, 5, 5 });
Check(Has(duplicates, 5) && !Has(duplicates, 4) && !Has(duplicates, 6), "repeated values behave like one value");

int[] sizes = Enumerable.Range(1, 80)
    .Concat(new[] { 127, 128, 129, 255, 256, 257, 1023, 1024, 1025, 8191, 8192, 8193, 65535, 65536, 65537 }).ToArray();
int sizeMismatches = 0;
foreach (int n in sizes)
{
    HashSet<ulong> model = new HashSet<ulong>();
    for (int i = 0; i < n; i++)
        model.Add(rng.NextUInt64());
    sizeMismatches += Mismatches(Build(model), model, rng, 300);
}
Check(sizeMismatches == 0, $"{sizes.Length} sizes around every power of two where the number of index bits changes, random hashes: {sizeMismatches} mismatches");

HashSet<ulong> clustered = new HashSet<ulong>();
for (int i = 0; i < 5000; i++)
    clustered.Add((ulong)rng.Next(0, 1 << 20));
object oneBucket = Build(clustered);
int badOneBucket = Mismatches(oneBucket, clustered, rng, 5000) + (Has(oneBucket, ulong.MaxValue) ? 1 : 0);
Check(badOneBucket == 0, $"5,000 hashes that all fall in the first bucket (a long slice searched by binary search): {badOneBucket} mismatches");

HashSet<ulong> boundary = new HashSet<ulong>();
for (int i = 0; i < 100000; i++)
    boundary.Add(rng.NextUInt64());
object boundaryIndex = Build(boundary);
int shift = (int)shiftField.GetValue(boundaryIndex)!;
HashSet<ulong> edges = new HashSet<ulong>(boundary);
ulong sliceMask = (1UL << shift) - 1;
for (int i = 0; i < 4000; i++)
{
    ulong lower = (ulong)rng.NextInt64() >> shift << shift;
    edges.Add(lower);
    edges.Add(lower | sliceMask);
}
object edgeIndex = Build(edges);
int badEdges = Mismatches(edgeIndex, edges, rng, 100000);
Check(badEdges == 0,
    $"{edges.Count} hashes including the first and last value of 4,000 buckets (shift {shift}): {badEdges} mismatches over every member, neighbour and random probe");

foreach ((int centers, int perCenter, int entries) in new[] { (50, 2000, 100000), (5, 40000, 200000) })
{
    HashSet<ulong> model = new HashSet<ulong>();
    ulong[] c = Enumerable.Range(0, centers).Select(_ => rng.NextUInt64()).ToArray();
    for (int i = 0; i < entries; i++)
        model.Add(c[i % centers] + (ulong)rng.Next(0, perCenter));
    int bad = Mismatches(Build(model), model, rng, 200000);
    Check(bad == 0, $"differential against HashSet<ulong>, {model.Count} hashes in {centers} dense clusters: {bad} mismatches");
}

HashSet<ulong> large = new HashSet<ulong>();
while (large.Count < 200000)
    large.Add(rng.NextUInt64());
int badLarge = Mismatches(Build(large), large, rng, 400000);
Check(badLarge == 0, $"differential against HashSet<ulong>, 200,000 random hashes: {badLarge} mismatches");

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} boundary check(s) failed");
    return 1;
}

Console.WriteLine("all HashIndex boundary checks passed");
return 0;

static class RandomExtensions
{
    public static ulong NextUInt64(this Random rng)
    {
        Span<byte> bytes = stackalloc byte[8];
        rng.NextBytes(bytes);
        return BitConverter.ToUInt64(bytes);
    }
}
EOF

out_file=${HASH_INDEX_OUT:-results/hash-index.boundary.txt}
mkdir -p "$(dirname "$out_file")"
{
	printf 'variant: hash64-index2\n'
	printf 'app_sha256: %s\n\n' "$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)"
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		-e HOME=/tmp -e DOTNET_CLI_HOME=/tmp/dotnet -e DOTNET_NOLOGO=1 \
		-e HASH_INDEX_DLL=/test/AdvancedBlockingApp.dll \
		-v "$tmp":/test -w /test \
		mcr.microsoft.com/dotnet/sdk:10.0 \
		dotnet run --project hash-index-test.csproj -c Release 2>&1
} | tee "$out_file"
