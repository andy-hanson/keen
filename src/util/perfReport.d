module util.perfReport;

@safe @nogc pure nothrow:

import util.alloc.alloc :
	Alloc,
	AllocKind,
	AllocKindMemorySummary,
	MemorySummary,
	MetaAlloc,
	MetaMemorySummary,
	summarizeMemory,
	totalBytes;
import util.col.arrayBuilder : buildArray, Builder, arrayBuilderSort;
import util.col.array : map;
import util.col.enumMap : EnumMap;
import util.col.map : KeyValuePair;
import util.comparison : compareUlong, oppositeComparison;
import util.json : field, Json, jsonObject, optionalField;
import util.opt : none, Opt, some;
import util.perf : Perf, PerfMeasure, PerfMeasureResult, PerfResult, perfResult;
import util.symbol : symbolOfEnum;
import util.writer : makeStringWithWriter, Writer;

Json perfReport(ref Alloc alloc, in Perf perf, in MetaAlloc metaAlloc, Json stats) =>
	jsonObject(alloc, [
		field!"memory"(showMemorySummary(alloc, summarizeMemory(metaAlloc))),
		field!"time"(showTimeSummary(alloc, perfResult(perf))),
		field!"stats"(stats)]);

private:

Json showTimeSummary(ref Alloc alloc, in PerfResult a) =>
	jsonObject(alloc, [
		field!"total"(showTimeAmount(alloc, a.totalNanoseconds)),
		field!"byMeasure"(jsonOfEnumMap!(PerfMeasure, PerfMeasureResult, perfMeasureNanoseconds)(
			alloc,
			a.byMeasure,
			(in PerfMeasureResult x) =>
				jsonObject(alloc, [
					field!"time"(showTimeAmount(alloc, x.nanoseconds)),
					field!"bytes"(showMemoryAmount(alloc, x.bytesAllocated)),
					field!"times"(x.count)])))]);
ulong perfMeasureNanoseconds(in PerfMeasureResult a) =>
	a.nanoseconds;

Json showMemorySummary(ref Alloc alloc, in MetaMemorySummary a) =>
	jsonObject(alloc, [
		field!"total"(showMemory(alloc, a.total)),
		field!"mallocs"(a.timesFetchedMemory),
		field!"freeBlocks"(a.countFreeBlocks),
		field!"byAlloc"(jsonOfEnumMap!(AllocKind, AllocKindMemorySummary, allocKindTotalBytes)(
			alloc,
			a.byAllocKind,
			(in AllocKindMemorySummary x) =>
				showMemory(alloc, x)))]);
ulong allocKindTotalBytes(in AllocKindMemorySummary a) =>
	totalBytes(a.summary);

Json jsonOfEnumMap(E, V, alias getQuantity)(
	ref Alloc alloc,
	in immutable EnumMap!(E, V) a,
	in Json delegate(in V) @safe @nogc pure nothrow cb,
) {
	alias Pair = immutable KeyValuePair!(E, V);
	Pair[] pairs = buildArray!Pair(alloc, (scope ref Builder!Pair res) {
		foreach (E key, ref immutable V value; a)
			if (getQuantity(value) != 0)
				res ~= Pair(key, value);
		arrayBuilderSort!(Pair, (in Pair x, in Pair y) =>
			oppositeComparison(compareUlong(getQuantity(x.value), getQuantity(y.value)))
		)(res);
	});
	return Json(map(alloc, pairs, (ref Pair pair) =>
		Json.ObjectField(symbolOfEnum(pair.key), cb(pair.value))));
}

Json showMemory(ref Alloc alloc, in AllocKindMemorySummary a) =>
	showMemoryCommon(alloc, some(a.countAllocs), a.summary);

Json showMemory(ref Alloc alloc, in MemorySummary a) =>
	showMemoryCommon(alloc, none!size_t, a);

Json showMemoryCommon(ref Alloc alloc, Opt!size_t countAllocs, in MemorySummary a) =>
	jsonObject(alloc, [
		field!"total"(showMemoryAmount(alloc, totalBytes(a))),
		field!"used"(showMemoryAmount(alloc, a.usedBytes)),
		field!"free"(showMemoryAmount(alloc, a.freeBytes)),
		field!"overhead"(showMemoryAmount(alloc, a.overheadBytes)),
		field!"count-blocks"(a.countBlocks),
		optionalField!"count-allocs"(countAllocs)]);

string showMemoryAmount(ref Alloc alloc, size_t bytes) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		size_t KB = 0x400;
		size_t MB = KB * KB;
		if (bytes > MB) {
			writer ~= bytes / MB;
			writer ~= "MB ";
		}
		if (bytes > 1024) {
			writer ~= (bytes % MB) / KB;
			writer ~= "KB ";
		}
		writer ~= (bytes % KB);
		writer ~= "B";
	});

string showTimeAmount(ref Alloc alloc, ulong nanoseconds) =>
	makeStringWithWriter(alloc, (scope ref Writer writer) {
		writer ~= divRound(nanoseconds, 1_000_000);
		writer ~= "ms";
	});

ulong divRound(ulong a, ulong b) {
	ulong div = a / b;
	ulong rem = a % b;
	return div + (rem >= b / 2 ? 1 : 0);
}
static assert(divRound(15, 10) == 2);
static assert(divRound(14, 10) == 1);
