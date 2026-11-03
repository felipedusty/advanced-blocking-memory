#!/usr/bin/env bash
# Boundary tests for the DomainSet class in the built Advanced Blocking app.
#
# The class is a private nested type, so the test loads the real assembly and
# drives it through reflection. It covers the 255-character guard, the 255-byte
# UTF-8 scratch buffer, sort/dedup, ordinal membership, Add-after-Sort, prefix and
# empty-name edge cases, and a seeded differential against HashSet<string>.
# A 253-character name is the longest one a DNS query can carry; 254 and 255
# characters are stored but not queryable, and 256 is skipped.
#
#   lab/domain-set-test.sh [patched]   (default: patched)
#
# Requires lab/.work/out-<variant> (lab/build-app.sh) and the .NET SDK image.
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:-patched}
case "$variant" in
original)
	echo "original has no DomainSet; use patched" >&2
	exit 2
	;;
patched) ;;
*)
	echo "usage: $0 [patched]" >&2
	exit 2
	;;
esac

out=lab/.work/out-$variant
[ -f "$out/AdvancedBlockingApp.dll" ] || {
	echo "missing $out/AdvancedBlockingApp.dll; run lab/build-app.sh $variant" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$out"/*.dll "$tmp"/
# The declaring type implements IDnsApplication (and the request blocking
# handler), whose base interfaces live in DnsServerCore.ApplicationCommon; the
# type lookup therefore loads that assembly. The app build output does not ship
# it, but the pinned clone built it.
work=$PWD/lab/.work
cp "$work/DnsServer/DnsServerCore.ApplicationCommon/bin/Release/DnsServerCore.ApplicationCommon.dll" "$tmp"/ 2>/dev/null || true
cp "$work"/TechnitiumLibrary/bin/TechnitiumLibrary.Net.dll "$tmp"/ 2>/dev/null || true
[ -f "$tmp/DnsServerCore.ApplicationCommon.dll" ] || {
	echo "missing DnsServerCore.ApplicationCommon.dll; run lab/build-app.sh $variant" >&2
	exit 1
}
[ -f "$tmp/TechnitiumLibrary.Net.dll" ] || {
	echo "missing TechnitiumLibrary.Net.dll; run lab/build-app.sh $variant" >&2
	exit 1
}

cat >"$tmp/domain-set-test.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>domain-set-test</AssemblyName>
  </PropertyGroup>
</Project>
EOF

cat >"$tmp/Program.cs" <<'EOF'
using System.Reflection;
using System.Runtime.Loader;

string dllPath = Environment.GetEnvironmentVariable("DOMAIN_SET_DLL")
    ?? throw new InvalidOperationException("DOMAIN_SET_DLL is not set");
string dllDir = Path.GetDirectoryName(Path.GetFullPath(dllPath))!;

AssemblyLoadContext.Default.Resolving += (context, name) =>
{
    string candidate = Path.Combine(dllDir, name.Name + ".dll");
    return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
};

Type type = Assembly.LoadFrom(dllPath).GetType("AdvancedBlocking.App+DomainSet", throwOnError: true)!;
const BindingFlags All = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

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

object Create() => Activator.CreateInstance(type, All, null, new object[] { 1024 }, null)!;
void Add(object set, string domain) => type.GetMethod("Add", All)!.Invoke(set, new object[] { domain });
void Sort(object set) => type.GetMethod("Sort", All)!.Invoke(set, null);
bool Contains(object set, string domain) => (bool)type.GetMethod("Contains", All)!.Invoke(set, new object[] { domain })!;
int RawCount(object set) => (int)type.GetProperty("RawCount", All)!.GetValue(set)!;

static string Name(params int[] labels) => string.Join(".", labels.Select(n => new string('a', n)));

string n253 = Name(63, 63, 63, 61);
string n254 = Name(63, 63, 63, 62);
string n255 = Name(63, 63, 63, 63);
string n256 = Name(63, 63, 63, 62, 1);

Check(n253.Length == 253 && n254.Length == 254 && n255.Length == 255 && n256.Length == 256,
    "test names have the expected lengths");

foreach ((string name, bool stored) in new[] { (n253, true), (n254, true), (n255, true), (n256, false) })
{
    object set = Create();
    Add(set, name);
    Sort(set);
    Check(Contains(set, name) == stored && RawCount(set) == (stored ? 1 : 0),
        $"{name.Length}-character name is {(stored ? "stored and found" : "skipped")}");
}

string twoByteFits = new('é', 127); // 127 characters, 254 UTF-8 bytes
object fits = Create();
Add(fits, twoByteFits);
Sort(fits);
Check(Contains(fits, twoByteFits), "a 254-byte name in 127 characters is stored");

string twoByteTooLong = new('é', 128); // 128 characters, 256 UTF-8 bytes
object tooLong = Create();
Add(tooLong, twoByteTooLong);
Sort(tooLong);
Check(!Contains(tooLong, twoByteTooLong) && RawCount(tooLong) == 0,
    "a 256-byte name in 128 characters is skipped by the byte guard");

object unsorted = Create();
Add(unsorted, "z.example");
Add(unsorted, "a.example");
Add(unsorted, "m.example");
Add(unsorted, "a.example");
Sort(unsorted);
Check(RawCount(unsorted) == 4, "RawCount keeps the raw parser count");
Check(Contains(unsorted, "a.example") && Contains(unsorted, "m.example") && Contains(unsorted, "z.example"),
    "all entries are found after an unsorted Add and Sort");
Check(!Contains(unsorted, "n.example"), "a missing entry is not found");
Check(!Contains(unsorted, n256), "a 256-character name is not found on a populated set");
Check(!Contains(unsorted, twoByteTooLong), "a 256-byte name is not found on a populated set");

var sortedCount = type.GetField("_sortedCount", All);
if (sortedCount is not null)
{
    Check((int)sortedCount.GetValue(unsorted)! == 3, "Sort removed the duplicate (4 raw, 3 unique)");
}
else
{
    Console.WriteLine("SKIP: this variant has no _sortedCount, so the dedup assertion cannot run");
}

object cased = Create();
Add(cased, "Edge.Example");
Sort(cased);
Check(Contains(cased, "Edge.Example") && !Contains(cased, "edge.example"),
    "membership is ordinal, so case is significant");

Check(!Contains(Create(), "x.example"), "an empty set contains nothing");

object grown = Create();
for (int i = 0; i < 5000; i++)
{
    Add(grown, $"grow-{i}.example");
}
Sort(grown);
Check(RawCount(grown) == 5000, "RawCount keeps 5000 added entries");
bool allFound = true;
for (int i = 0; i < 5000; i++)
{
    if (!Contains(grown, $"grow-{i}.example"))
    {
        allFound = false;
        Check(false, $"grow-{i}.example is missing after growth");
        break;
    }
}
Check(allFound, "all 5000 entries are found after the buffer and offsets grow and Sort");
Check(!Contains(grown, "grow-5000.example"), "a missing entry is absent after growth");

object single = Create();
Add(single, "example.com");
Sort(single);
Check(Contains(single, "example.com") && !Contains(single, "example.co") && !Contains(single, "xexample.com")
        && !Contains(single, "ample.com") && !Contains(single, "example.com.") && !Contains(single, "com"),
    "a one-entry set finds only the entry, not its prefixes, suffixes or neighbours");

object prefixed = Create();
Add(prefixed, "ab");
Add(prefixed, "abc");
Sort(prefixed);
Check(Contains(prefixed, "ab") && Contains(prefixed, "abc") && !Contains(prefixed, "a")
        && !Contains(prefixed, "abcd") && !Contains(prefixed, "abd") && !Contains(prefixed, "b"),
    "entries that are prefixes of each other stay distinct");

object emptyName = Create();
Add(emptyName, "");
Sort(emptyName);
Check(Contains(emptyName, "") && !Contains(emptyName, "a") && RawCount(emptyName) == 1,
    "the empty name is stored and found, and nothing else is");

object longShared = Create();
string common = new('a', 240);
List<string> longNames = Enumerable.Range(0, 100).Select(i => common + i.ToString("D3")).ToList();
foreach (string longName in longNames)
    Add(longShared, longName);

Sort(longShared);
Check(longNames.All(longName => Contains(longShared, longName)) && !Contains(longShared, common)
        && !Contains(longShared, common + "100") && !Contains(longShared, common + "00") && !Contains(longShared, common + "0000"),
    "entries sharing 240 bytes are all found, and their prefix and neighbours are not");

static string RandomName(Random rng)
{
    int labels = rng.Next(1, 4);
    return string.Join(".", Enumerable.Range(0, labels)
        .Select(_ => new string(Enumerable.Range(0, rng.Next(1, 5)).Select(__ => "abc"[rng.Next(3)]).ToArray())));
}

Random rng = new Random(20261101);
HashSet<string> model = new HashSet<string>();
object differential = Create();
for (int i = 0; i < 3000; i++)
{
    string name = RandomName(rng);
    model.Add(name);
    Add(differential, name);
}
Sort(differential);
int mismatches = 0, present = 0, absent = 0;
for (int i = 0; i < 100000; i++)
{
    string probe = RandomName(rng);
    bool expected = model.Contains(probe);
    if (Contains(differential, probe) != expected)
    {
        mismatches++;
    }
    if (expected)
    {
        present++;
    }
    else
    {
        absent++;
    }
}
Check(mismatches == 0 && present > 1000 && absent > 1000,
    $"seeded differential against HashSet<string>: {present} present and {absent} absent probes, {mismatches} mismatches");

object sorted = Create();
Add(sorted, "x.example");
Sort(sorted);
try
{
    Add(sorted, "y.example");
    Check(false, "Add after Sort throws");
}
catch (TargetInvocationException ex) when (ex.InnerException is InvalidOperationException)
{
    Check(true, "Add after Sort throws InvalidOperationException");
}

object beforeSort = Create();
Add(beforeSort, "z.example");
try
{
    Contains(beforeSort, "z.example");
    Check(false, "Contains before Sort throws");
}
catch (TargetInvocationException ex) when (ex.InnerException is InvalidOperationException)
{
    Check(true, "Contains before Sort throws InvalidOperationException");
}

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} boundary check(s) failed");
    return 1;
}

Console.WriteLine("all DomainSet boundary checks passed");
return 0;
EOF

out_file=results/$variant.boundary.txt
mkdir -p results
{
	printf 'variant: %s\n' "$variant"
	printf 'app_sha256: %s\n\n' "$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)"
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		-e HOME=/tmp -e DOTNET_CLI_HOME=/tmp/dotnet -e DOTNET_NOLOGO=1 \
		-e DOMAIN_SET_DLL=/test/AdvancedBlockingApp.dll \
		-v "$tmp":/test -w /test \
		mcr.microsoft.com/dotnet/sdk:10.0 \
		dotnet run --project domain-set-test.csproj -c Release 2>&1
} | tee "$out_file"

if [ "$variant" = patched ] && grep -q "SKIP:" "$out_file"; then
	echo "patched must expose _sortedCount for the dedup check" >&2
	exit 1
fi
