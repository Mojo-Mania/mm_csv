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
| this, scan only, no storage | 2.09 GB/s | 2.11 GB/s |
| this, full parse | 1.03 GB/s | 1.04 GB/s |

A caveat on that build: simdcsv's ARM path references `neonmovemask_bulk` and
never defines it -- the README's promised ARM variant was never written -- so
these numbers come from the algorithm with that one function supplied (the
standard simdjson movemask) and `vmull_p64`'s return cast. The C++ measured is
theirs; the ARM completion is not.

The gap splits in two, and the middle row above is what separates them.

**Half of our parse is bookkeeping, not scanning.** Recording boundaries into
two `List[Int]`s costs as much again as the byte walk that finds them: 16 bytes
written per delimiter, with a capacity check each time, against simdcsv's four
bytes into a preallocated array with no per-write check.

*The fix:* keep **one** `UInt32` array of delimiter positions rather than two
`Int` lists of starts and ends. A field's start is the previous delimiter's
position plus one, and its end is its own delimiter's position, minus one when
that delimiter is an LF preceded by a CR -- a single byte compare, payable at
access time instead of at parse time. That is a 4x cut in index memory and it
removes one append per field.

**The scan itself is 5.3x slower than their whole pass.** Three techniques
account for it:

1. **64 bytes per step, as a bitmask.** They compare four 16-byte vectors and
   pack the results into one `UInt64` with a movemask, then walk the set bits
   with count-trailing-zeros. We look at 16 bytes and then visit each match
   through `compressed_store` and a runtime lane index.
2. **Carry-less multiply for the quote mask.** `vmull_p64(-1, quote_bits)` is a
   prefix-XOR: it turns "here are the quote positions" into "here is every
   position inside a quoted region", for all 64 bytes, branchlessly. Delimiters
   inside quotes then vanish with one `& ~quote_mask`. We toggle a boolean per
   quote in a loop, which is a branch per quote and a dependency chain.
3. **Unrolled bits-to-indexes.** `flatten_bits` writes eight indexes per
   iteration with no per-bit branch, deliberately overrunning the count into a
   padded buffer.

*What Mojo gives us today:* `count_trailing_zeros` and `pop_count` are there.
A SIMD-to-bitmask movemask is **not** -- `SIMD[bool, N].to_bits()` returns a
lane-wise 0/1 vector, not a packed integer -- so it would have to be built from
a weight-multiply and pairwise adds. Carry-less multiply would need an
`llvm_intrinsic` call per architecture, `pmull64` on ARM and `pclmulqdq` on
x86, with a scalar fallback. Neither is out of reach; both are real work.

*Order to do it in:* the storage change first. It is contained, needs no new
primitives, and the measurement says it is worth about 2x on its own. The
bitmask scan is the larger prize and the larger project.

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
