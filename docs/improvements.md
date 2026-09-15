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
| this, one `UInt32` array, 64-byte bitmask scan | **2.80 GB/s** | **2.83 GB/s** |

Two rounds of that list have now been done, and the gap is four times rather
than eleven.

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

## The scan: done, and what it left behind

The scan is now the simdjson shape: sixty-four bytes a step, four `UInt64`
bitmasks, a prefix-XOR for the quote regions, and a count-trailing-zeros walk
over the delimiters that survive. Against the sixteen-byte
`compressed_store` version it replaced:

| | 16-byte scan | 64-byte bitmask |
| --- | ---: | ---: |
| `no_escaping.csv` | 965 MiB/s | **2672 MiB/s** |
| `needs_escaping.csv` | 908 MiB/s | **2700 MiB/s** |

2.8x and 3.0x, and it turned the SIMD path from something that lost to the
scalar walk on short fields into one that wins at every width measured.

Two of the three techniques carried over cleanly. The third did not, and one
of them needed help:

**Carry-less multiply: implemented, measured, and not kept.** `pclmulqdq` /
`pmull64` computes the prefix-XOR in one instruction. Mojo can reach it --

```mojo
var product = llvm_intrinsic[
    "llvm.aarch64.neon.pmull64", SIMD[DType.uint8, 16]
](bits, UInt64.MAX)
return bitcast[DType.uint64, 2](product)[0]
```

-- and it agrees with the shift version on every input tried, including the
all-ones and single-high-bit cases. It is genuinely faster per call:

| | per call | a GiB of input | share of a GiB parse |
| --- | ---: | ---: | ---: |
| six shift-and-XOR steps | 1.119 ns | — | — |
| `pmull64` | 1.029 ns | saves 1.5 ms | **0.4%** |

One call covers sixty-four bytes, so 0.09 ns of saving spread over 64 bytes is
1.5 ms per GiB against a parse that takes about 400 ms. End to end the two
versions measured 2693 against 2656 MiB/s, inside the run-to-run spread.

So the portable version stays, and now for a measured reason rather than an
assumed one. An earlier version of this note said carry-less multiply "did not
show up as a bottleneck" -- which was true, but nothing had been measured when
it was written. The intrinsic is worth revisiting only if the movemask cost
below comes down enough to make 0.4% matter.

**The empty-chunk skip had to be added back.** The first bitmask version paid
for sixteen movemasks on every chunk whether or not it held anything, which
made it 3x *slower* than the old scan on documents with long fields — 2.0 ms
against 0.6 at 256-byte fields. One comparison per class per vector, ORed and
reduced to a single bool, answers "is there anything here?" without any
packing; a chunk that is entirely inert skips the rest. That recovered the
long-field case and improved everything else too.

**The movemask is now the floor.** Mojo has no packed-lane movemask --
`SIMD[bool, N].to_bits()` returns a lane-wise vector -- so sixteen lanes are
packed into sixteen bits by shifting each lane by its own index and ORing,
about ten operations where NEON's `vpaddq` sequence does sixty-four lanes in
roughly eight. Four classes times four vectors is sixteen of those per chunk,
and it is most of what a non-empty chunk costs: a chunk with one delimiter in
it pays the same as a chunk with thirty. That is visible in the sweep, where
everything between 16 and 64 byte fields sits at the same 2.4 ms.

Worth trying, in order: the multiply-based bit gather
(`(x & 0x8040201008040201) * 0x0101010101010101 >> 56` over a 0xFF-per-lane
mask), which packs eight bytes in three integer operations and may beat the
shift-and-OR; and failing that, an `llvm_intrinsic` movemask per architecture.
Neither has been measured.

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
