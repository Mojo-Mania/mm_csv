# Identified improvements

Everything up to "Choosing the scan automatically" was measured on an Apple M4
Max. The x86 work, on an AMD Ryzen AI 9 HX 370, is in its own section, "x86:
the scan was running the portable path", near the end.

## What simdcsv does that this does not

[geofflangdale/simdcsv](https://github.com/geofflangdale/simdcsv) is a
structural scanner for RFC 4180 built on the simdjson techniques. Measured on
the M4 against the same two documents, it finds exactly the same
delimiters -- 2 042 888 in `no_escaping.csv`, matching commas plus line feeds
-- and it does so **about eleven times faster**:

| | `no_escaping.csv` | `needs_escaping.csv` |
| --- | ---: | ---: |
| simdcsv, structural scan | **11.1 GB/s** | **12.5 GB/s** |
| this, full parse, two `Int` lists, 16-byte scan | 0.89 GB/s | 0.87 GB/s |
| this, one `UInt32` array, 16-byte scan | 1.01 GB/s | 0.95 GB/s |
| this, 64-byte bitmask scan | 3.97 GB/s | 4.15 GB/s |
| this, plus an unrolled delimiter walk | 6.07 GB/s | 6.55 GB/s |
| this, plus a bulk movemask and `pmull64` | **9.61 GB/s** | **10.37 GB/s** |

Everything on that list has been done, and profiling then found three things
it does not do. **The 1.16x that column arithmetic implies is wrong** -- the
rows were filled in at different sittings and compared as though they were
not. See "Re-measured against simdcsv" below, which puts both sides on the
same machine in the same minute and gets 1.30x to 1.44x.

A caveat on that build: simdcsv's ARM path references `neonmovemask_bulk` and
never defines it -- the README's promised ARM variant was never written -- so
these numbers come from the algorithm with that one function supplied (the
standard simdjson movemask) and `vmull_p64`'s return cast. The C++ measured is
theirs; the ARM completion is not. Built with:

```bash
clang++ -std=c++17 -O3 -mcpu=apple-m4+crypto -Isrc \
  src/main.cpp src/io_util.cpp -o simdcsv
```

The gap looked like it split in two, and the first half turned out to be
smaller than it looked.

## The index: done, and it taught a lesson about microbenchmarks

Recording boundaries into two `List[Int]`s looked like half the cost of
parsing: the same byte walk with the appends replaced by a counter ran at
2.09 GB/s against the full parse's 1.03. **That reading was wrong**, and the
note here used to predict "about 2x" from it.

The index is now one `List[UInt32]` of delimiter offsets, with the top bit
flagging a delimiter that was an LF preceded by a CR, so a field's start comes
from the previous entry and its end needs no byte compare. That is four bytes
a field instead of sixteen. Measured:

| | two `Int` lists | one `UInt32` array |
| --- | ---: | ---: |
| parse, `simd=True` | 852 MiB/s | **965 MiB/s** |
| parse, `simd=False` | 977 MiB/s | **1009 MiB/s** |
| read all, `field` | 6465 MiB/s | 6468 MiB/s |
| read all, `get` | 872 MiB/s | 854 MiB/s |
| index bytes per field | 16 | **4** |

3-13% on parsing and a 4x cut in index memory, not 2x. Worth keeping, and
worth far less than the microbenchmark implied.

The lesson is about the measurement, not the change. "The same loop with the
writes removed" is not the same loop: with nothing to store, everything stays
in registers and the compiler is free to vectorise what it could not before.
The 11 ms that disappeared was the writes *plus* the optimisations their
absence allowed, and only the first part was recoverable.

An intermediate version is also worth recording: keeping one array but
recomputing the CRLF adjustment at read time, with two byte loads per field,
cost 10-15% on reading and gave back most of the parse gain. Moving that one
bit into the index is what made the change free on the read side.

## The scan: done

The scan is now the simdjson shape: sixty-four bytes a step, four `UInt64`
bitmasks, a prefix-XOR for the quote regions, and a count-trailing-zeros walk
over the delimiters that survive. Against the sixteen-byte `compressed_store`
version it replaced:

| | 16-byte scan | 64-byte, hand-rolled packing | 64-byte, `pack_bits` |
| --- | ---: | ---: | ---: |
| `no_escaping.csv` | 965 MiB/s | 2672 MiB/s | **3789 MiB/s** |
| `needs_escaping.csv` | 908 MiB/s | 2700 MiB/s | **3955 MiB/s** |

3.9x and 4.4x, and it turned the SIMD path from something that lost to the
scalar walk on short fields into one that wins at every width measured, from
1.94x at two-byte fields to 6.30x at 256.

### `pack_bits` is the movemask, and then it was not fast enough

An earlier version of this note claimed **Mojo has no movemask**, on the
grounds that `SIMD[bool, N].to_bits()` returns a lane-wise vector rather than a
packed integer. That is true of `to_bits` and it is the wrong function:
`std.memory.pack_bits` bitcasts a `SIMD[bool, 64]` straight to a `UInt64`.
Using it instead of a hand-rolled shift-and-OR was worth 1.42x. One function
had been tried, it was not the one, and "Mojo cannot do this" went into three
files; searching the standard library would have cost a minute.

It is still not what the disassembly wants. On ARM, `pack_bits` over 64 lanes
lowers to four independent sixteen-lane movemasks:

```
and.16b  v17, v17, v29     ; weights
addp.16b v17, v17, v17     ; three pairwise folds, 16 bytes -> 2
addp.16b v17, v17, v17
addp.16b v17, v17, v17
umov.h   w10, v17[0]       ; a crossing out of the vector file
```

Four of those per mask, four masks per chunk: **sixteen crossings and about
ninety instructions** to pack one chunk. simdjson's `neonmovemask_bulk` folds
all four vectors together first -- four `and`, four `addp`, **one** `umov` --
and `llvm_intrinsic["llvm.aarch64.neon.addp", ...]` reaches the instruction it
needs. Over the whole binary that took `umov` from 23 to 3 and the parse from
5854 to 8101 MiB/s, **1.40x**.

### Carry-less multiply: three verdicts, all of them correct

`pmull64` computes the prefix-XOR in one instruction. Whether to use it got
measured three times and the answer changed twice, because the answer was
never a property of the instruction.

| measured | verdict | why |
| --- | --- | --- |
| in isolation, random feed | 1.029 ns against 1.119, **faster** | nothing around it to say where the operand lives |
| in the scan, with `pack_bits` | 0.8% **slower**, 8 pairs of 8 | mask lands in a general-purpose register, so `fmov` in *and* out |
| in the scan, with the `addp` fold | 13% **faster**, 6 pairs of 6 | mask is already in a vector register, so only `fmov` out |

The disassembly of the last one:

```
pmull.1q v0, v0, v9      ; operand already in v0, no fmov in
fmov     x10, d0         ; one crossing out
eor      x8, x10, x8
```

against the middle one:

```
fmov     d4, x9          ; in
pmull.1q v4, v4, v9
fmov     x9, d4          ; out
```

The first measurement was the one that misled, and it was the isolated one.
What an operation costs depends on which register file its operand already
occupies, and that is a fact about the surrounding code. A microbenchmark
removes exactly the context that decides it.

Both the fold and the multiply are behind `CompilationTarget.has_neon()`, with
`pack_bits` and six shift-and-XOR steps as the fallback. On x86 the balance
turned out different again: `pclmulqdq` is worth 7% even though its operand
arrives from a general-purpose register -- see "x86: the scan was running the
portable path" below.

### The empty-chunk skip

The first bitmask version paid for its packing on every chunk whether or not
it held anything, which made it 3x *slower* than the old scan on documents
with long fields -- 2.0 ms against 0.6 at 256-byte fields. Testing the four
masks for zero before doing anything else skips an inert chunk outright, and
that is what makes the scan win at every width rather than only on dense data.

### The profile, and the unrolled walk it argued for

Building the scan up a phase at a time over the real file -- adding work
rather than stubbing it out, so no phase changes what the data is -- put the
time here, on `no_escaping.csv`:

| phase | cumulative | added |
| --- | ---: | ---: |
| load 64 bytes | 0.20 ms | 0.20 |
| + four compares, four `pack_bits` | 0.98 ms | 0.78 |
| + quote, CRLF and delimiter masks | 2.88 ms | 1.90 |
| + walk the delimiter bits | 5.48 ms | **2.60** |
| + store into the index | 5.60 ms | 0.12 |

Loads were 3% and stores 2%; the walk over the delimiter bits was **46%**.
That loop was `while bits != 0: ctz, write, clear lowest bit` -- a branch per
delimiter, 2.04 million of them. Unrolling it into groups of eight, writing
past the count into slack the way simdcsv does, dropped that phase from
2.60 ms to 0.57 ms and the whole parse from 3789 to 5854 MiB/s: **1.5x**.

Two things about doing it are worth recording.

*A nested closure destroyed it.* The first attempt put the eight-wide body in
a `@parameter def` so it could be called four times. Capturing the mutable
`bits` and destination pointer forced them to memory, and the whole scan went
**three times slower** than before the change. Written out inline, the same
logic is 1.5x faster. Same algorithm, 4.7x apart.

*It needed storage this package owns.* Writing past the count means the index
cannot be a `List` -- `append` will not overrun and there is no public way to
set a length after writing through `unsafe_ptr`. `_positions` is now a raw
allocation with an explicit count and capacity, and the scan checks once per
chunk that sixty-four more entries will fit.

That check was not there at first, and the benchmark crashed: the index is
sized at one entry per eight bytes, and a document of two-byte fields has a
delimiter every three, so the unrolled writes ran off the end of the
allocation. Nothing in the test suite was dense enough to catch it.
`test_far_more_delimiters_than_the_index_was_sized_for` is, and it crashes if
the check is removed.

### Chunk buffering and prefetching: tried, both slower

These were the last two things simdcsv does that this did not. Both were
implemented and both lost, on this machine, measured four ways against the
same binary harness -- best of 400 parses, five rounds, microseconds:

| base | prefetch only | buffered only | both |
| ---: | ---: | ---: | ---: |
| 2291 | 2380 | 2347 | 2332 |
| 2292 | 2376 | 2347 | 2334 |
| 2288 | 2373 | 2348 | 2329 |
| 2286 | 2378 | 2345 | 2325 |
| 2287 | 2381 | 2350 | 2330 |

Prefetching is 4% slower, buffering 2.6%, and the two together 1.9% -- every
round, no overlap between the distributions.

**Prefetching** adds one `prfm` per chunk to a walk that is already purely
sequential. The hardware prefetcher needs no help with that, and the
instruction is not free.

**Buffering** computes four chunks' masks into small arrays before flattening
any of them, so the vector-heavy and integer-heavy halves can overlap. It did
not spill -- the disassembly has *fewer* stack references than the unbuffered
version, 17 against 42 -- but the group-of-four unrolling makes the scan
region 3614 instructions where the plain one is 938. Whatever the overlap
bought, it did not cover that.

Neither is kept. simdcsv reports buffering as its biggest win after the
bitmask work, but that was measured on x86 with a different compiler, so both
were tried again there -- and lost again. See "Buffering and prefetching on
x86: tried, neither wins" below.

### Re-profiled, and the index writes are now most of what is left

The earlier phase breakdown predated the bulk movemask and the carry-less
multiply, so it was re-done. It is not reported here, because it turned out
not to be measuring the same thing: the harness put the whole scan at 1305 us
where the real one takes 2293, and a harness that disagrees with reality by
75% has nothing to say about where reality spends its time. Two of its phases
were also invalid on inspection -- the "walk, but do not store" phase
XOR-accumulates each value, which is a dependency chain the real code does not
have, and it measured *slower* than the phase that stores.

Ablating the real scan instead, with the same binary harness used everywhere
else -- best of 400 parses, results deliberately wrong, timing only:

| | microseconds | share |
| --- | ---: | ---: |
| the scan as it stands | 2293 | |
| with the unrolled emit removed | 1408 | |
| **so the emit costs** | **885** | **39%** |
| of which stores alone, timed on their own | 525 | 23% |
| leaving the count-trailing-zeros and flag work | ~360 | 16% |
| the per-chunk capacity check | ~14 | 0.6% |

The store figure is measured separately: writing 2 042 888 `UInt32`s costs
525 us whether the pages are fresh or warm -- they are identical to within
0.4%, so this is not page faults -- which is about one store per cycle. That
is the store port, and no amount of cleverness upstream moves it.

**That reframes the remaining gap.** simdcsv runs the same document at
11.1 GB/s, which is 2077 us against our 2293: 216 us apart. Both have to write
the same 2 042 888 four-byte indexes, so of that, simdcsv spends about 1552 us
on everything that is not storing and this spends 1768. The two
implementations are within about 14% of each other on the work that is
actually optional, and both are carrying the same ~525 us floor.

**That paragraph rests on the 2077 us, and the 2077 us was stale.** Measured
alongside, simdcsv runs this document in about 1870 us in its default build
and 1720 us built with `-DCRLF`; see "Re-measured against simdcsv" below. The
floor argument survives -- both still write the same two million indexes --
but the optional work is 1345 to 1195 us for simdcsv against 1768 here, which
is a gap of 30% to 48%, not 14%.

Anything further, that note said, has to come from writing less rather than
scanning faster, and it proposed two shapes. Both have since been built and
measured. **Both are slower**, and the next three sections say why.

### Not materialising the index: built, and 20% slower

`CsvFields` is the scan with the writes taken out. It walks the same chunks,
does the same bitmask arithmetic, and keeps the chunk's delimiter mask in the
iterator, clearing one bit per `__next__`. Nothing is allocated and nothing is
stored. On `no_escaping.csv`, one variant per process, best of twenty:

| | microseconds |
| --- | ---: |
| build the index | 2338 |
| walk every field of the built index | 1560 |
| **both, fused** | **3848** |
| **stream the same fields, no index** | **4692** |

The prediction was that streaming would save the whole 23% the stores cost.
It does save them. It loses more than that somewhere else, and the somewhere
else is the shape of the emit.

The indexed emit is unrolled into groups of eight and **writes eight offsets
per chunk whether or not eight delimiters are there**, because a junk entry
landing in slack costs nothing and is overwritten by the next chunk. That is
what makes it branch-free: no test per delimiter anywhere. A consumer cannot
be handed junk fields, so `CsvFields` has to test the mask once per field, and
on this document -- eleven bytes a field, so five or six delimiters in a
sixty-four byte chunk -- that branch is not well predicted. It costs more than
the store it saves. Reading the index back afterwards is a flat, predictable
pass with no data-dependent branches at all.

A hand-written version with every piece of state in a local, rather than in
the iterator, runs at 4553 us against the iterator's 4692: the abstraction is
3% of it, and the branch is the rest.

So `CsvFields` ships for what it actually offers -- no index memory, four
bytes a field saved, and no 2 GiB ceiling because its offsets are full-width
integers -- and not for speed. The README says so.

On x86, after the scan got its own x86 paths, the gap closes: indexing and
walking `no_escaping.csv` costs 4.04 ms against 4.08 for streaming, and 4.13
against 4.25 on `needs_escaping.csv`. Level, not faster. The branch per field
is evidently cheaper on that core, but it still does not buy back more than
the stores cost.

That lasted one commit. Once the x86 emit became a `vpcompressb` -- see "The
emit on x86: no chain, one compress" -- indexing and walking is 2.74 ms
against 4.10 on `no_escaping.csv`, and 2.71 against 4.28 on
`needs_escaping.csv`. Streaming is 50-60% slower there, and the reason is
sharper than on ARM: the index got a branch-free, chain-free writer, and
`CsvFields`, which has to hand fields out one at a time, cannot use it.

### Narrowing the index: tried, and slower

Three bytes a slot does **not** address a 16 MiB document, as the note above
claimed: the CRLF flag takes the top bit, so three bytes reach 8 MiB and two
reach 32 KiB. Measured on an 8 MB prefix that a three-byte slot can address,
and on a synthetic document with a delimiter every other byte:

| | 4-byte slots | 3-byte slots |
| --- | ---: | ---: |
| 8 MB, 707 886 fields | **787 us** | 984 us |
| 8 MB, 4 000 000 fields | **2507 us** | 2912 us |

A 25% saving in bytes written turns into a 16-25% *loss* in time, because
narrowing does not change the number of stores -- one per field either way --
and the stores are port-limited, not bandwidth-limited. What it does change is
that every store is now unaligned and roughly one in twenty-one straddles a
cache line.

Two aligned bytes, which only a document under 32 KiB can use, is about 5%
faster on a 32 KB document whose whole index fits in L1. That is a rounding
error on a three-microsecond parse, bought with a crippling size limit.

**A harness lesson, again.** The first version of this measurement had the
scan write into a buffer that nothing ever read. LLVM deleted the allocation
and every store into it, and the harness cheerfully reported that four-byte
and three-byte slots both took 441 us -- and that four million fields took the
same 441 us as seven hundred thousand. That last number is what gave it away:
four million stores cannot happen in 441 us. Reading one entry back at the end
of each repetition restored the stores and the numbers above.

### Sharing the chunk step between the two scans: tried, costs 11%

`CsvTable._scan_simd` and `CsvFields` run the same chunk arithmetic, so the
obvious thing is one `@always_inline` helper returning the masks. It was
written, it passed every test, and it cost **11% of the parse** -- 2560 us
against 2293. The cause was not found: the helper does inline (one `pmull` in
the binary, no separate symbol), and none of the obvious suspects account for
it. Making the returned struct `TrivialRegisterPassable` is worth 2% of the
11%; returning the carry state rather than taking it by `mut` changes nothing;
hoisting the constant comparison vectors in or out of the loop changes
nothing; computing `row_ends` lazily changes nothing; removing the
empty-chunk early return makes it 5% worse still.

So the arithmetic is written out twice, and `test_streaming_matches_the_table`
walks every corpus both ways to stop the copies drifting apart.

### The read path was not being inlined

Found while reconciling two harnesses that disagreed. `CsvTable.field` is a
small function, and with one caller it inlined and cost 0.8 ns a field. Add a
second caller in the same module -- `get` calls it too -- and LLVM stopped
inlining it, at which point every field read paid a call and the raising
convention: **1.8 ns, 2.2x worse**. The benchmark had been reporting the slow
number since the file was written, and adding the streaming row to the same
benchmark is what made the inconsistency visible.

`field` is now `@always_inline`. Reading a whole document went from 3.5 ms to
1.6 ms, and `get`, which calls it, from 26.6 ms to 24.0.

## Re-measured against simdcsv, and the earlier 1.16x was wrong

Every number above was taken when it was taken. Putting both sides on this
machine in one sitting -- five runs each, mean of 100 passes, GiB/s, the same
two documents, the same delimiter counts (2 042 888 and 2 011 820, which both
implementations agree on exactly) -- gives this:

| | `no_escaping.csv` | `needs_escaping.csv` |
| --- | ---: | ---: |
| simdcsv, built with `-DCRLF` | **12.83** | **13.87** |
| simdcsv, default build | 11.66 | 12.66 |
| this | 8.94 | 9.52 |

So 1.30x against simdcsv's default build and 1.44x against its fastest, not
1.16x. Nothing regressed: the scan is byte for byte what it was at the
re-profile, and the same harness that reported 2293 microseconds then reports
2285 now. What was wrong was the comparison, not either measurement.

Two things about that table are worth keeping.

**simdcsv is faster with `-DCRLF` than without it**, by 10%, reproducibly,
interleaved runs. That build does a fourth comparison per chunk and computes
`lf & cr_adjusted` where the default just takes `lf`, so it is strictly more
work for an identical index on these documents. No explanation found; it is
their code and their scheduling. It is reported as the baseline because it is
the faster of the two and because it is the build that does the same job this
one does.

**The order of the runs matters.** A simdcsv run immediately after a Mojo
process measured 8.92 GiB/s where five consecutive runs measured 11.63 to
11.69. Interleaving the two implementations, which is the obvious way to be
fair, is the way to get a contaminated number. Five consecutive runs of each,
then compare.

### Fifteen per cent of the gap is the CRLF flag

This index stores in the top bit of every entry whether that delimiter was an
LF with a CR in front of it, so that reading a field needs no byte compare.
simdcsv stores a bare offset and has nothing to say about CRLF at access time.

Deleting the flag from the emit -- storing `UInt32(offset + lane)` and nothing
else, four unrolled groups, no other change -- takes the parse from **2285 to
1933 microseconds**. That is 15% of the parse and roughly half the distance to
simdcsv's default build, spent on a feature rather than lost to one.

The rest is not accounted for. simdcsv's buffering and prefetching, which are
on by default in its build and which it credits with 24%, were tried here and
were 4% and 2.6% *slower* -- see above -- so whatever is left is not that
either.

## Closing the gap: one win, two losses, and a budget

The re-measurement left 679 microseconds between this and simdcsv's fastest
build. Ablating the real scan says where they are. Baseline 2285
microseconds, best of 400 parses of `no_escaping.csv`:

| removed | microseconds | costs |
| --- | ---: | ---: |
| baseline | 2285 | |
| the compare-and-select in the CRLF flag | 2199 | **86** |
| ...then the CRLF flag entirely | 1930 | **269** |
| ...the carriage-return movemask | 1873 | **326** |
| ...tracking the first row's column count | 2151 | 48 |
| ...the loop-carried quote dependency | 2145 | 54 |
| ...the per-chunk capacity check | 2178 | 21 |

### The win: the flag is arithmetic, not a branch

The emit used to build the flag with a conditional:

```mojo
var flag = Self._CRLF_BIT if (crlf >> UInt64(lane)) & 1 != 0 else UInt32(0)
```

which is a shift, a test, and a select. Shifting the bit into place instead
says the same thing in two instructions, and ARM folds the second into the
`orr` that was already there:

```mojo
var flag = (crlf >> UInt64(lane)).cast[DType.uint32]() << 31
```

The `& 1` is not needed: truncating to 32 bits and shifting left by 31 keeps
bit 0 and nothing else. **86 microseconds, 3.8% of the parse**, for four
lines.

### The losses: two cheaper ways to find CRLF, both much worse

A carriage return only matters immediately before a line feed, and this
document has one row end to every eight delimiters. So a full sixty-four lane
comparison for CR -- 326 microseconds -- looks like a lot to pay for
information about 255 361 positions. Two ways to pay less:

**Flag the slots afterwards.** Emit bare offsets, then walk the row-end bits,
load the byte before each one, and `|=` the flag into the slot already
written, finding it with `pop_count(delimiters & below)`. Correct -- all 26
tests pass -- and **2786 microseconds**, 587 worse than the baseline it was
meant to beat. Read-modify-write on memory written microseconds earlier is a
store-to-forward stall, 255 361 times.

**Build the mask first.** Same byte loads, but into a `crlf` mask before the
emit runs, so the emit is unchanged and there is no read-modify-write.
**2936 microseconds**, worse still. The loop over set bits has a trip count of
zero, one or two and the branch predictor cannot learn it, so 360 224 chunks
pay mispredicts to save a comparison that was branch-free.

Both attempts lose to the same thing: a sixty-four lane SIMD comparison has no
branches in it, and anything that replaces it with a loop over the few
positions that matter pays more in mispredicts than the comparison cost in the
first place. The CR movemask is not an overhead, it is the cheap way.

A side benefit was given up with them. Reading the byte before each line feed
straight from the document needs no `carried_cr` at all -- a CR and its LF may
straddle a chunk boundary and the load does not care -- which would have
deleted the exact piece of state whose tests did not bite for so long.

### Things that turn out not to be worth doing

**Packing with `select` instead of a multiply.** simdjson ANDs the all-ones
comparison result with the bit weights where `_movemask` here casts to 0/1 and
multiplies. Replacing the multiply with `m.select(weights, zeros)` measured
2191-2200 against the baseline's 2199: no difference outside noise. The
compiler was already lowering it well.

**Software-pipelining the chunks.** Breaking the loop-carried quote dependency
entirely -- `carried_quote = 0`, wrong answers, timing only -- is worth 54
microseconds, 2.5%. Out-of-order execution is already hiding that chain, so
buffering chunks to overlap it has almost nothing to win, which agrees with
simdcsv's buffering and prefetch having measured slower here.

### What is left

At 2199 microseconds, with CRLF support costing 595 of them and the column
count and capacity check another 69, the comparable figure against simdcsv's
default build -- which does none of that -- is about 1861. simdcsv's default
build runs 1870. **On the same work, the two are level.** The remaining
distance to simdcsv's `-DCRLF` build, which does the fourth comparison and is
somehow 10% faster than its own default build for an identical index, is not
accounted for.

## Choosing the scan automatically: no longer needed

This section used to argue that the vectorised scan lost to the scalar walk on
short fields -- by 12% at two bytes, and on both real documents -- and that
picking a scan per document needed a better predictor than mean field length.
That was true of the sixteen-byte `compressed_store` scan it measured. The
bitmask scan that replaced it wins at every field width measured, on both
machines: 2.0x to 8.9x on the M4, 4.7x to 15x on x86. There is no losing case
left to predict, so `simd=True` stays the unconditional default.

The same rewrite answered the question the next section here used to ask --
whether Mojo can turn a SIMD comparison into an integer bitmask. It can:
`std.memory.pack_bits`, see "`pack_bits` is the movemask" above.

## x86: the scan was running the portable path

Everything above was tuned on ARM, and every ARM-specific piece -- the `addp`
fold and `pmull64` -- sits behind `has_neon()`. On x86 that left the portable
path: four sixteen-lane loads, and for each of the four masks, four
`pack_bits[DType.uint16]` calls. Disassembled on an AMD Ryzen AI 9 HX 370
(AVX-512), that is sixteen `vpcmpeqb` into mask registers, sixteen `kmovd` out
to general-purpose registers, and then the compiler putting the halves back
together in the vector file:

```
vpcmpeqb k0,xmm1,xmm19
kmovd    esi,k0            ; sixteen of these a chunk
vmovd    xmm1,edi
vpinsrw  xmm1,xmm1,esi,0x1 ; and back into a vector
vpmovzxwq ymm1,xmm1
vpsllq   ymm2,ymm2,0x10
vpternlogq ymm1,ymm2,ymm0,0xfe
```

followed by six shift-and-XOR pairs for the prefix-XOR. The benchmark had
been saying so all along without it being read that way: from eight-byte to
sixty-four-byte fields the simd column sat at exactly 2.5 ms, and 12 MB is
187 500 chunks, so about 13 ns a chunk no matter what the chunk held. The real
document came out the same: 4584 us over 360 223 chunks. A per-chunk constant
that large is packing, not walking.

x86 got the equivalents of the two ARM pieces:

- **With AVX-512BW**, the chunk is loaded as one `SIMD[DType.uint8, 64]`,
  compared once per mask, and `pack_bits[DType.uint64]` lowers to exactly
  `vpcmpeqb zmm` into a mask register and one `kmovq` out. Four crossings a
  chunk where there were sixteen, and none of the reassembly.
- **With AVX2 and no AVX-512BW**, two thirty-two lane halves, and each
  `pack_bits[DType.uint32]` is one `vpmovmskb`: eight crossings.
- **With `pclmul`**, the prefix-XOR is `llvm.x86.pclmulqdq`, one
  `vpclmullqlqdq`.

Best of 400 parses of `no_escaping.csv`:

| | microseconds | |
| --- | ---: | ---: |
| portable path | 4584 | |
| 64-lane compare, shifts for the prefix-XOR | 2720 | 1.69x |
| 64-lane compare and `pclmulqdq` | **2535** | **1.81x** |
| AVX2 build, portable compare, `pclmulqdq` | 3894 | |
| AVX2 build, 32-lane halves, `pclmulqdq` | **2826** | **1.38x** |

The AVX2 rows are the same binary harness built with
`--target-features=-avx512f,-avx512bw`, on the same core, so they say what the
code does without AVX-512, not what an AVX2-only chip would measure.

**`pclmulqdq` pays here where `pmull64` did not on ARM with `pack_bits`.** On
ARM the version whose operand came from a general-purpose register lost 0.8%;
this one takes its operand from a `kmovq` into a general-purpose register and
wins 7%. The six shifts it replaces are the same on both, so the difference is
in the cost of the crossing and of the multiply, and it is one more reason not
to carry a verdict from one instruction set to another.

The ARM path is untouched, and checked: an `aarch64-apple-darwin` build for
`apple-m4` produces the same assembly before and after, apart from line
numbers in one abort message. All 26 tests pass on x86 with the host features,
and with AVX-512, AVX2 and `pclmul` switched off in each combination; the
disassembly of each build carries the instructions it should (`kmovq`,
`pmovmskb`, `pclmul`, or none of them).

Parsing is now 8.3-8.6 GiB/s on x86, from 4.4, against 9.4-10.3 on the M4.
Across the field-width sweep the simd column improved 1.4x at two-byte fields
and 2x to 3.3x everywhere else.

### Buffering and prefetching on x86: tried, neither wins

x86 is what simdcsv was tuned on, and where it found buffering worth the most,
so both were re-implemented on the AVX-512 path and measured the way the ARM
attempt was: four builds of one source, selected with `-D` defines, best of 400
parses, five rounds, microseconds. All four pass the 26 tests.

- **Prefetch**: `prefetch(ptr + offset + 128)` once per chunk, simdcsv's
  distance.
- **Buffered**: the loop-carried part -- compares, prefix-XOR, the quote and
  CR carries -- for four chunks into a `SIMD[DType.uint64, 4]` each of
  delimiters, CRLF ends and row ends, then one capacity check and four emits.
  simdcsv's shape.

`no_escaping.csv`:

| base | prefetch only | buffered only | both |
| ---: | ---: | ---: | ---: |
| 2447 | 2577 | 2506 | 2456 |
| 2451 | 2577 | 2491 | 2468 |
| 2475 | 2595 | 2470 | 2471 |
| 2444 | 2605 | 2483 | 2455 |
| 2462 | 2595 | 2489 | 2457 |

`needs_escaping.csv`:

| base | prefetch only | buffered only | both |
| ---: | ---: | ---: | ---: |
| 2582 | 2718 | 2614 | 2592 |
| 2576 | 2712 | 2611 | 2590 |
| 2580 | 2719 | 2616 | 2583 |
| 2586 | 2715 | 2619 | 2589 |
| 2583 | 2722 | 2594 | 2587 |

Prefetching is 5% slower on both documents, every round. Buffering is 1-2%
slower. Both together land level with the base, 0.3% behind -- the same
ordering as on ARM, with smaller gaps.

**Prefetching loses at every distance.** 128 bytes ahead is inside what a
hardware prefetcher already covers on a sequential walk, so the distance was
swept too, prefetch only, `no_escaping.csv`:

| base | 128 | 1024 | 4096 | 16384 |
| ---: | ---: | ---: | ---: | ---: |
| 2454 | 2573 | 2593 | 2578 | 2661 |
| 2447 | 2573 | 2578 | 2581 | 2633 |
| 2468 | 2575 | 2567 | 2568 | 2646 |
| 2451 | 2587 | 2583 | 2589 | 2656 |
| 2465 | 2584 | 2581 | 2571 | 2709 |

5% at anything up to a page, 8% at 16 KiB. The instruction costs something and
there is nothing for it to do.

**Buffering has nothing to overlap.** What it is for is letting the integer
work of one chunk run while the next chunk's vector work, which depends on the
previous quote state, is still in flight. So the thing to measure is what that
dependency costs, and the ablation from the ARM budget answers it: set
`carried_quote = 0` -- wrong answers, timing only -- and the chain is gone.

| base | chain cut |
| ---: | ---: |
| 2455 | 2486 |
| 2433 | 2496 |
| 2457 | 2500 |
| 2463 | 2492 |
| 2450 | 2515 |

Cutting it makes the scan 1.8% *slower*, which is codegen moving around, not a
cost uncovered. On ARM it was worth 54 microseconds; on this core it is worth
nothing measurable. Out-of-order execution already runs past it, and
buffering pays for its restructuring with nothing to recover.

Neither is kept. The experiment was a separate loop ahead of the committed one
and is not in the tree.

### The emit on x86: no chain, one compress

On AVX-512 the unrolled walk did not compile to the loop it looks like. The
disassembly of one group of eight, abridged -- the chain and spill lines are
interleaved in the real listing:

```
blsr   rdx,r14                  ; the chain: bits &= bits - 1
lea    rcx,[rdx-0x2]
and    rcx,rdx
mov    QWORD PTR [rsp+0xa0],rcx ; each link spilled
...
vmovq  xmm3,QWORD PTR [rsp+0xa0] ; and reloaded
vpunpcklqdq xmm2,xmm4,xmm3      ; gathered into a zmm
vinserti128 ymm1,ymm2,xmm1,0x1
vpaddq ymm2,ymm1,ymm2            ; lowest set bit, eight at once
vpandn ymm1,ymm1,ymm2
vpopcntq ymm3,ymm1               ; = count-trailing-zeros
vpsrlvq zmm1,zmm0,zmm3           ; CRLF flag
vpmovqd ymm1,zmm1
vmovdqu YMMWORD PTR [r9+r13*4],ymm2 ; eight offsets, one store
```

LLVM's SLP vectoriser took everything after the chain -- count-trailing-zeros
as `vpopcntq((x - 1) & ~x)`, the flag shift, the narrowing, the store -- and
did it eight lanes at a time. The chain itself cannot be vectorised: each link
is the previous one with its lowest bit cleared. So it runs in scalar code, all
its links have to be alive at once to be gathered, there are more of them than
free registers, and they go to the stack. The spills were a symptom of the
gather, and the gather was about twenty instructions per eight offsets.

**It was not the call.** The capacity check sits between the masks and the
walk, and it calls `_reserve`, so anything live across it must be saved.
Moving the check to the top of the chunk, where nothing is live, took the stack
references in the scan from 171 to 157 and the parse from 2455 to 2807
microseconds -- 15% *slower*.

**The fix is not having a chain.** AVX-512 VBMI2 has `vpcompressb`, which
takes a byte vector and a mask and packs the selected bytes to the front, in
order, in one instruction. Compress `iota[DType.uint8, 64]()` by the delimiter
mask and the result is every delimiter's lane, already in order. The CRLF flag
rides along in bit 7 -- lanes stop at 63, so the bit is free -- by ORing
`0x80` into the lanes where `crlf` is set before compressing. Then sixteen at
a time: zero-extend to `UInt32`, `& 127` and add the chunk offset, shift bit 7
up to bit 31, store sixteen.

Getting a `SIMD[DType.bool, 64]` from the `UInt64` mask needed a function the
stdlib does not have. `bitcast` refuses, because it counts a `bool` as eight
bits; `pack_bits` is a raw `pop.bitcast` from bools to an integer, so
`_unpack_bits` is the same op the other way.

Best of 400 parses, five rounds:

| | `no_escaping.csv` microseconds | |
| --- | ---: | ---: |
| unrolled walk | 2443-2465 | |
| compress, all four stores every chunk | 1869-1881 | 1.31x |
| **compress, stores two to four guarded** | **1093-1125** | **2.21x** |

**Guarding the stores is worth 1.7x on its own.** Five or six delimiters a
chunk fit in the first sixteen, and `if found > 16` is a well-predicted
branch; storing all 256 bytes regardless costs far more than the branches
it saves. That is the opposite of the unrolled walk's lesson -- where writing
junk past the count was the win -- and the difference is size: eight 4-byte
junk writes against 192 bytes of them.

The field-width sweep, simd column, before and after:

| mean field bytes | 2 | 4 | 8 | 16 | 32 | 64 | 128 | 256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| unrolled walk, ms | 3.2 | 1.6 | 1.3 | 1.3 | 1.3 | 1.3 | 0.7 | 0.4 |
| compress, ms | **1.3** | **0.8** | **0.7** | **0.6** | **0.7** | **0.7** | **0.5** | **0.4** |

The biggest win is on two-byte fields, where the chain was longest: 2.5x.
The full benchmark puts parsing at 17 434 and 18 620 MiB/s on the two
documents, 17.0 and 18.2 GiB/s, from 8.3 and 8.6.

It is behind `_COMPRESS_EMIT`, which asks for `avx512vbmi2`. Checked:

- the 26 tests with the host's features, and with VBMI2, AVX-512, AVX2 and
  `pclmul` switched off in turn, with only the host build containing
  `vpcompressb`;
- every field of both real documents against the scalar scan, in each of those
  builds;
- 9 576 dense synthetic documents -- up to sixty-four delimiters a chunk, CR,
  CRLF and quoted separators, at every alignment -- field by field, start and
  end, which is what exercises the guarded stores and the flag;
- an `aarch64-apple-darwin` build for `apple-m4`, unchanged apart from the
  source location in one abort message.

**One side effect:** the *scalar* parse of `needs_escaping.csv` measures about
8% slower in the same binary, 25.0 ms against 23.2, in every run since. Its
source did not change. It is the reference implementation, not a path anyone
is meant to use, so this is recorded rather than chased.

### What is left on x86

**AVX-512 without VBMI2 still walks.** Skylake-X and Cascade Lake have
AVX-512F and BW but not VBMI2, and fall back to the unrolled walk at about
2.5 ms. `vpcompressd`, which is AVX-512F, could do the same job on four
sixteen-lane `UInt32` vectors. It can be built and checked here with
`--target-features=-avx512vbmi2`, but not measured on a chip that lacks it.

**AVX2 has no compress.** The usual substitute is a table of `pshufb` shuffle
masks indexed by eight mask bits at a time, as simdjson's minifier does. It is
untried here.

**simdcsv itself is unmeasured on x86**, so there is no gap to quote yet --
and simdcsv has no AVX-512 path, so a comparison would say as much about the
instruction set as about either implementation.

## Streaming

`CsvTable` takes the whole document and keeps it, because every field borrows
from it. That is what makes `field` free, and it means a document has to fit
in memory. `CsvFields` is the different type with the different bargain -- see
"Not materialising the index" above -- but it borrows the whole document too.
Reading a document that does not fit in memory, from a file or a socket, is
still not something either type does.
