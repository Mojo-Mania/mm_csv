# Identified improvements

## What simdcsv does that this does not

[geofflangdale/simdcsv](https://github.com/geofflangdale/simdcsv) is a
structural scanner for RFC 4180 built on the simdjson techniques. Measured on
this machine against the same two documents, it finds exactly the same
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
it does not do. The gap is 1.16x rather than eleven.

A caveat on that build: simdcsv's ARM path references `neonmovemask_bulk` and
never defines it -- the README's promised ARM variant was never written -- so
these numbers come from the algorithm with that one function supplied (the
standard simdjson movemask) and `vmull_p64`'s return cast. The C++ measured is
theirs; the ARM completion is not.

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
`pack_bits` and six shift-and-XOR steps as the fallback. On x86, where
`pclmulqdq` and the `pack_bits` lowering may well share the vector file
already, the balance could be different again; nothing here has been measured
on x86.

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

Neither is kept. Both are worth re-trying if this is ever built for x86, which
is what simdcsv was tuned on: it reports buffering as its biggest win after
the bitmask work, and that claim was measured on a different machine, a
different compiler and a different instruction set.

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

Anything further has to come from writing less, not from scanning faster. Two
shapes that would:

- **Do not materialise the index at all** for callers that stream. An iterator
  that yields fields as the scan finds them would skip the writes entirely,
  and for a one-pass consumer -- sum a column, filter rows -- that is the
  whole 23%. It is a different type with a different bargain, not a change to
  this one.
- **Narrow the index.** Four bytes a field is already the minimum for a 2 GiB
  document, but a document under 16 MiB needs only three, and one under 64 KiB
  only two. A width chosen from the document length would cut the store
  traffic by a quarter or a half. Whether the unaligned loads that come with a
  three-byte index pay for themselves has not been measured.

## Choosing the scan automatically

`CsvTable` defaults to the vectorised scan, and the README's sweep shows that
is the wrong choice for documents with short fields — by 12% at two bytes a
field, against a 4x win at 128. Picking per document rather than per caller
looks like free money.

It is not, yet, because **the obvious predictor does not work**. Mean bytes per
field is cheap to sample and is what the sweep varies, so it ought to say which
scan to use. It does not:

| | bytes/field | scalar | simd | winner |
| --- | ---: | ---: | ---: | --- |
| uniform sweep | 9 | 6.9 ms | 5.3 ms | simd, 1.30x |
| `no_escaping.csv` | 11.3 | 22.5 ms | 25.8 ms | scalar, 1.15x |
| `needs_escaping.csv` | 12.4 | 24.1 ms | 28.7 ms | scalar, 1.19x |

At a *larger* mean field length the real documents prefer the *other* scan. A
uniform width is not the same shape as a real distribution — median 6, mean 10,
a tail out to 46 — and something about that distribution, not its mean, decides
the winner. Until there is a statistic that separates these three rows
correctly, an automatic choice would be a guess wearing a measurement's
clothes.

What would settle it: sweep the field-length *distribution* rather than a
single width — same mean, different variance — and see whether the crossover
tracks variance, the median, or the fraction of chunks containing no delimiter
at all. That last one is the mechanism the scan actually cares about, and it is
as cheap to sample as the mean.

## A bitmask instead of `compressed_store`

The SIMD scan stores matching lane indices to a scratch buffer and then reads
them back, and for each one indexes into the comparison masks — `quotes[lane]`,
`line_feeds[lane]` — with a runtime index. Dynamic lane extraction usually goes
through memory, and there are three of them per match.

Turning each mask into an integer bitmask once per chunk and walking the set
bits with a count-trailing-zeros loop would answer all three questions with bit
tests instead. Whether Mojo exposes a SIMD-to-bitmask conversion has not been
checked.

## Streaming

`CsvTable` takes the whole document and keeps it, because every field borrows
from it. That is what makes `field` free, and it means a document has to fit
in memory. A streaming reader would be a different type with a different
bargain, not a change to this one.
