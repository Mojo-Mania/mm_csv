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
| this, plus an unrolled delimiter walk | **6.07 GB/s** | **6.55 GB/s** |

Everything on that list has now been done, and the gap is about 1.8x rather
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

### `pack_bits` is the movemask, and an earlier version of this note was wrong

The middle column above exists because this file previously claimed **Mojo has
no movemask**, on the grounds that `SIMD[bool, N].to_bits()` returns a
lane-wise vector rather than a packed integer. That is true of `to_bits`, and
it is the wrong function. `std.memory.pack_bits` is the right one: it bitcasts
a `SIMD[bool, 64]` straight to a `UInt64`, one lane per bit, which is exactly
the movemask.

Replacing the hand-rolled packing -- shift each lane by its own index, OR the
result -- with `pack_bits` is worth **1.42x and 1.46x** of the whole parse. It
also collapses four 16-byte loads and sixteen packing sequences per chunk into
one 64-byte load and four `pack_bits` calls.

The lesson is about how the absence was concluded: one function was tried, it
was not the one, and "Mojo cannot do this" went into three files. Searching the
standard library would have cost a minute.

### Carry-less multiply: measured three times, and it is slower

`pclmulqdq` / `pmull64` computes the prefix-XOR in one instruction, and Mojo
reaches it:

```mojo
var product = llvm_intrinsic[
    "llvm.aarch64.neon.pmull64", SIMD[DType.uint8, 16]
](bits, UInt64.MAX)
return bitcast[DType.uint64, 2](product)[0]
```

It agrees with the six shift-and-XOR steps on every input tried. It is also
**slower in this scan**, consistently: two binaries, alternated, each taking
the best of 400 parses of the same document.

| | best of 400 parses, microseconds |
| --- | --- |
| six shift-and-XOR steps | 3611, 3615, 3616, 3618, 3621, 3621, 3626, 3630 |
| `pmull64` | 3637, 3643, 3644, 3645, 3650, 3650, 3667, 3692 |

Eight pairs, shift ahead in all eight, by about 0.8%.

The disassembly says why. The portable version is six instructions and no
moves, because ARM gives the shifted operand away for free:

```
eor x9, x9, x9, lsl #1
eor x9, x9, x9, lsl #2
eor x9, x9, x9, lsl #4
eor x9, x9, x9, lsl #8
eor x9, x9, x9, lsl #16
eor x8, x8, x9, lsl #32
```

The intrinsic is one instruction bracketed by two register-file crossings,
because `pack_bits` leaves the mask in a general-purpose register and
`pmull64` wants a vector one:

```
fmov  d4, x9          ; general-purpose -> vector
pmull.1q v4, v4, v9
fmov  x9, d4          ; vector -> general-purpose
```

**An isolated microbenchmark got this backwards.** Timed on its own with a
random feed, `pmull64` measured 1.029 ns a call against the shift version's
1.119, and this note reported it as "faster per call, but under 1% of a
parse". The per-call number was real and the conclusion drawn from it was
wrong: what an operation costs depends on which register file its operand
already lives in, and that is a property of the code around it, not of the
operation. Only the in-place A/B answered it.

So the portable version stays, now on the grounds that it is both portable and
faster. On x86, where `pclmulqdq` takes its operands from the vector file that
`pack_bits` would already be using, the answer could easily differ; nothing
here has been measured on x86.

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

### What is left

simdcsv is still about 1.8x ahead, 11.1 GB/s against 6.1. Three things it does
that this does not:

- **Buffering.** It processes four chunks into a small array of masks before
  flattening any of them, for pipelining, and reports that as its single
  biggest win after the bitmask work itself.
- **Prefetching.** `__builtin_prefetch(buf + idx + 128)` on every chunk.
- **No capacity check at all.** Its index buffer is padded once at the start
  and the scan never checks, where this one checks per chunk.

The profile also says the mask arithmetic -- prefix-XOR, the CRLF shift, the
`& ~inside` -- is now the largest single phase at 1.90 ms of 5.60. That is
where a fourth round would start. Carry-less multiply is not the answer there:
re-measured once the walk stopped dominating, it is slower, for the reason
above.

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
