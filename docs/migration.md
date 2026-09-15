# What changed from `mzaks/mojo-csv`

A port of [mzaks/mojo-csv](https://github.com/mzaks/mojo-csv), which was
written against a 2023-era Mojo. It no longer compiles — every import needs a
`std.` prefix, `alias` is `comptime`, `fn` is `def` — and the reader's way of
returning values, slicing a `String` with `s[a:b]`, no longer exists at all.

## Three bugs

**The SIMD scan leaked a buffer per chunk.** `_simd_parse`'s inner closure ran

```mojo
var sp: UnsafePointer[UInt8] = UnsafePointer[UInt8].alloc(simd_width)
compressed_store[DType.uint8, simd_width](offsets, sp, all_bits)
```

on every chunk of the input and never freed it. That is one allocation per 16
bytes — about a gigabyte leaked, in sixty-seven million allocations, for a
gigabyte of input. The fix was already imported and unused in that same file:
`stack_allocation`. `leaks --atExit` now reports zero for a parse of the
benchmark document.

**`row_count()` divided by a negative number.** `column_count` started at `-1`
and was only set when the scan met a line break, so a document with no
trailing newline — which RFC 4180 explicitly permits — left it at `-1` and
`row_count` returned a negative. `test_last_record_may_omit_the_line_break`
fails if the fix is removed.

**`finish()` could write past the end of its buffer.** `_extend_buffer_if_needed`
guaranteed `num_bytes + size < capacity` per push, so after a push that emitted
a two-byte CRLF separator the headroom could be as low as one byte. `finish`
then wrote three: a CR, an LF, and the NUL that `string_from_pointer` stored.
This one has **no regression test**: the bytes it wrote still read back
correctly, so only a memory checker can see it, and neither `libgmalloc` nor
`MallocScribble` intercepts Mojo's allocator on this machine. The fix is a
`_reserve(2)` in `finish` and rests on that reasoning, not on a test.

## The reader's API changed

| was | is | why |
| --- | --- | --- |
| `get(row, col) -> String`, `""` when out of range | `get` raises; `field` borrows | `""` was indistinguishable from a genuinely empty field |
| — | `field(row, col) -> StringSlice` | the common case needs no allocation, and this is 7-10x faster |
| — | `is_quoted(row, col)` | so a caller can tell whether `get` would do anything |
| — | `is_ragged()` | the row/column arithmetic assumes rectangular rows; now it can be checked |
| `CsvTable(s, with_simd=True)` | `CsvTable(s, simd=True)` | keyword-only |
| `row_count()` on `_starts` | on `_ends` | the two lists are the same length after the fix, but ends is what a field count means |

`CsvBuilder` gained a `separator` parameter, which only `CsvTable` had before —
the writer always emitted commas however the reader was configured. `push`'s
`escape` argument is keyword-only, and the two overloads no longer disagree
about its default: strings default to escaping on, `push_value` to off, and
the README says why.

## The benchmark data is no longer committed

The upstream repository carries two New Zealand government statistics exports,
52 MB in the working tree. Both source URLs are dead, so `data/setup.sh`
generates files matching what the originals measured — row count, column
count, quoted fraction, field-length distribution — and prints the shape it
produced. It also accepts two paths, for comparing against a published number
on the exact bytes.

## One claim that did not survive

The upstream README says SIMD tokenising is "about 20% faster" than the scalar
scan. Measured here it is between **0.88x and 4.19x** depending on how long
the fields are, and both benchmark documents fall in the region where it
loses. The README has the sweep.
