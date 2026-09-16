# mm_csv

[![CI](https://github.com/Mojo-Mania/mm_csv/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_csv/actions/workflows/ci.yml)

Reading and writing CSV in [Mojo](https://mojolang.org), to
[RFC 4180](https://www.rfc-editor.org/rfc/rfc4180).

```mojo
from mm_csv import CsvBuilder, CsvTable

var names: List[String] = ["name", "note"]
var builder = CsvBuilder(names^)
builder.push("Ada")
builder.push("first, and foremost")     # holds a comma, so it gets quoted
var document = builder^.finish()

var table = CsvTable(document^)
print(table.row_count(), table.column_count)   # 2 2
print(table.get(1, 1))                          # first, and foremost
```

The reader makes **one pass** over the document, recording where every field
begins and ends, and then reading a value is index arithmetic. Nothing is
copied per field unless you ask for it: `field` hands back a `StringSlice`
borrowing the original text at **0.8 ns per field**, and `get` is the one that
undoes RFC 4180 escaping and allocates.

There is a second reader, `CsvFields`, which builds no index at all and hands
the fields back one at a time. It is **slower**, and the section below says by
how much and when to want it anyway.

## When to use it

**The reader owns the document.** `CsvTable` takes the whole text as a
`String` and keeps it, because every field is a slice of it. That is what
makes reading free; it also means the document has to fit in memory.

**Index first, stream only for a reason.** `CsvFields` walks the same chunks
without writing an index, which sounds like it should be the faster way to
read a document once. Measured, it is **slower**: 20% slower than building
the index and walking it on an Apple M4 and 50-60% slower on x86, for reasons
in the performance section. What it buys is the four bytes a field that the
index costs -- 8 MB on a 23 MB document -- and freedom from the 2 GiB ceiling,
because its offsets are full-width integers.
Take it when the memory matters or the document is enormous; otherwise take
`CsvTable`.

**Reach for `field` before `get`.** They differ by 7-10x. `get` allocates a
`String` and undoes escaping; `field` gives you the raw bytes and copies
nothing. `is_quoted` tells you whether the difference matters for a given
field.

**Leave the SIMD scan on.** It is the default and it wins at every field width
measured, on both machines: from 1.6x on two-byte fields to 8.9x on 256-byte
ones on an Apple M4, and from 4.7x to 15x on x86. The scalar walk is kept as
the reference implementation the tests compare against, not as an option you
are meant to need.

**Documents must be under 2 GiB.** Field positions are indexed with 31 bits
and a flag; a larger document aborts with a message saying so. `CsvFields` has
no such limit.

**Rows must be rectangular.** RFC 4180 says every row holds the same number of
fields, and `get(row, column)` assumes it. `is_ragged()` reports a document
that breaks the rule, and its fields can still be read in order through
`__len__`.

## Install

```toml
[dependencies]
mm_csv = { git = "https://github.com/Mojo-Mania/mm_csv.git" }
```

## API

### Reading

| | |
| --- | --- |
| `CsvTable[separator](text, simd=True)` | Parses `text`, which it takes ownership of. |
| `.column_count` | Fields in the first row. |
| `.row_count()` | Rows. |
| `len(table)` | Fields, in total. |
| `.field(row, column)` | The raw field, borrowed. Raises if out of range. |
| `.get(row, column)` | The field, unescaped. Allocates. Raises if out of range. |
| `.is_quoted(row, column)` | Whether the raw field is wrapped in quotes. |
| `.is_ragged()` | Whether some row has a different field count. |

Streaming, for a consumer that looks at each field once:

| | |
| --- | --- |
| `CsvFields[separator](text)` | An iterator over the fields of `text`, which it borrows. Builds no index. |
| `field.value` | The raw field, borrowed. |
| `field.ends_row` | Whether a line break, or the end of the document, closed it. |
| `field.unescaped()` | The field with RFC 4180 escaping undone. Allocates. |

```mojo
from mm_csv import CsvFields

var total = 0
for field in CsvFields(document):
    if field.ends_row:
        total += 1
```

### Writing

| | |
| --- | --- |
| `CsvBuilder[separator](column_count)` | Starts a document with unnamed columns. |
| `CsvBuilder[separator](names)` | Starts one whose first row is `names`. |
| `.push(value, escape=True)` | Appends a string field. |
| `.push_value(value, escape=False)` | Appends anything `Writable` — a number, or your own type. |
| `.push_empty()` | Appends an empty field. |
| `.fill_up_row()` | Pads the current row out with empty fields. |
| `len(builder)` | Bytes written so far. |
| `.finish()` | Completes the last row and returns the document. Consumes the builder. |

`separator` is a compile-time `UInt8` and defaults to `,`. For TSV:
`CsvTable[UInt8(ord("\t"))]`.

`escape` defaults **on** for `push` and **off** for `push_value`, because a
rendered number can never need quoting and a string very well might. Turning
it off means the value is written through unchecked: a separator or a quote
slipping past makes a broken document.

## Performance

Measured on two machines, `-D ASSERT=none`, best of three runs. Reproduce with
`bash data/setup.sh && pixi run bench`.

The two documents are generated, not committed — the originals were New
Zealand government statistics exports whose URLs are now dead, so
`data/setup.sh` builds files matching their row count, column count, quoted
fraction and field-length distribution. It prints the shape it produced.

### Apple M4 Max

Two runs agreeing to within 6%.

**`no_escaping.csv`** — 23.1 MB, 255 361 rows, 8 columns, nothing quoted:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **2.3** | **9626** | **1.1** |
| parse, `simd=False` | 22.3 | 988 | 10.9 |
| read all, `field` (slice) | **1.6** | **14031** | **0.8** |
| read all, `get` (String) | 23.7 | 929 | 11.6 |
| stream, no index | 4.9 | 4469 | 2.4 |
| build, `escape=False` | **17.7** | **1239** | **8.7** |
| build, `escape=True` | 31.0 | 709 | 15.2 |

**`needs_escaping.csv`** — 24.9 MB, 201 182 rows, 10 columns, 10% quoted:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **2.3** | **10531** | **1.1** |
| parse, `simd=False` | 23.8 | 999 | 11.8 |
| read all, `field` (slice) | **1.6** | **15284** | **0.8** |
| read all, `get` (String) | 32.5 | 731 | 16.1 |
| stream, no index | 5.1 | 4615 | 2.6 |
| build, `escape=False` | **17.6** | **1347** | **8.8** |
| build, `escape=True` | 38.3 | 640 | 19.0 |

### AMD Ryzen AI 9 HX 370

AVX-512 with VBMI2, Linux, Mojo 1.2.0.dev2026091505. Three runs; all agree to
within 2% except the `needs_escaping.csv` parse, where one run measured 18 620
MiB/s and the other two about 17 300.

**`no_escaping.csv`**:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **1.3** | **17434** | **0.6** |
| parse, `simd=False` | 21.1 | 1042 | 10.3 |
| read all, `field` (slice) | **1.5** | **14873** | **0.7** |
| read all, `get` (String) | 24.1 | 911 | 11.8 |
| stream, no index | 4.1 | 5361 | 2.0 |
| build, `escape=False` | **20.2** | **1089** | **9.9** |
| build, `escape=True` | 37.6 | 585 | 18.4 |

**`needs_escaping.csv`**:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **1.3** | **18620** | **0.6** |
| parse, `simd=False` | 25.0 | 951 | 12.4 |
| read all, `field` (slice) | **1.4** | **16501** | **0.7** |
| read all, `get` (String) | 26.2 | 906 | 13.0 |
| stream, no index | 4.3 | 5547 | 2.1 |
| build, `escape=False` | **21.7** | **1096** | **10.8** |
| build, `escape=True` | 40.0 | 613 | 19.9 |

Parsing is **1.8x ahead of the M4**, 17.0 and 18.2 GiB/s, because x86 with
AVX-512 VBMI2 writes the index with `vpcompressb` and ARM has no equivalent
instruction. Reading through `field` is 6-8% ahead and streaming 20% ahead;
writing is 4-19% behind. The history on this machine: the scan parsed at 4.4
GiB/s while it was running the portable fallback, 8.3-8.6 once it had x86
compares and `pclmulqdq`, and this with the compress; see
[`docs/improvements.md`](docs/improvements.md). A build without VBMI2 keeps the
unrolled walk and parses `no_escaping.csv` in about 2.5 ms; one with AVX2 only,
in 2.8.

### Reading the tables

**Borrowing beats copying by 15-20x.** Walking every field costs 0.7-0.8 ns
each through `field` and 12-16 ns through `get`. That whole difference is
allocating a `String` per field and undoing escaping. On a document with no
quoted fields at all, `get` still costs 14x more, because it still allocates.

**Not building the index costs as much as building it, or more.** On the M4,
parsing and then walking every field is 2.3 + 1.6 = 3.9 ms; streaming the same
fields with no index at all is 4.9. On x86 it is 1.3 + 1.5 = 2.8 against 4.1.
The reason is that the index is written in groups -- eight offsets per chunk
from the unrolled walk, sixteen from the compress -- whether or not that many
delimiters are there, because writing a few junk entries into slack is free,
and there is no branch per delimiter anywhere. A consumer cannot be handed
junk fields, so `CsvFields` has to test and branch once per field, and that
branch costs more than the store it avoids. Reading the index back afterwards is then a flat,
predictable pass. Streaming is the right choice for the memory it saves, not
for speed.

**Escaping costs 75-120% on writing**, not the 10x the upstream README warned
of: 75% and 118% on the M4, 84% and 86% on x86. That is the price of looking at
every byte of every value, and the `_needs_escaping` check here is vectorised,
which the original's was not for the tail.

### Which scan

The vectorised scan turns sixty-four bytes at a time into four `UInt64`s --
one bit per byte, for quote, separator, line feed and carriage return -- and
then does the whole job in integer arithmetic. A prefix-XOR of the quote bits
gives a mask of every byte inside a quoted region, so `& ~quotes` deletes the
delimiters that are data rather than structure, with no branch per quote and
no state machine. Shifting the carriage returns left by one lines them up with
the line feeds that follow, so one AND finds the CRLF row ends. What is left
is walked with count-trailing-zeros, once per delimiter rather than once per
byte.

It wins at every field width measured. On the M4 -- measured one change
earlier than the tables above, before the CRLF flag became arithmetic, so the
simd column may now be slightly low:

| mean field bytes | scalar ms | simd ms | simd wins by |
| ---: | ---: | ---: | ---: |
| 2 | 6.9 | **4.3** | 1.62x |
| 4 | 6.4 | **1.8** | 3.54x |
| 8 | 5.5 | **1.1** | 4.81x |
| 16 | 6.2 | **1.1** | 5.58x |
| 32 | 6.1 | **1.1** | 5.39x |
| 64 | 6.5 | **1.1** | 5.77x |
| 128 | 6.7 | **0.8** | 8.50x |
| 256 | 6.4 | **0.7** | 8.85x |

On the Ryzen AI 9 HX 370:

| mean field bytes | scalar ms | simd ms | simd wins by |
| ---: | ---: | ---: | ---: |
| 2 | 6.3 | **1.3** | 4.68x |
| 4 | 5.6 | **0.8** | 6.66x |
| 8 | 4.9 | **0.7** | 7.53x |
| 16 | 4.9 | **0.6** | 7.63x |
| 32 | 4.8 | **0.7** | 7.39x |
| 64 | 5.4 | **0.7** | 8.28x |
| 128 | 5.5 | **0.5** | 11.99x |
| 256 | 5.5 | **0.4** | 14.61x |

The scalar column is the noisy one -- it moves about 10% between runs, and the
two-byte row has been seen anywhere from 1.25x to 1.62x on the M4. The shape
does not move: the win grows with field length and never disappears.

That was not true of the first version of this scan, which looked at sixteen
bytes and visited each match through a scratch buffer. It lost to the scalar
walk on short fields — which is what both documents above have — and the
upstream README's claim that SIMD tokenising was "about 20% faster" held only
for long ones. Rewriting it as bitmask arithmetic made the parse **3.9x**
faster on those documents and turned a coin flip into a default worth having.

Three parts of it came from profiling rather than from the design. The walk
over the delimiter bits is unrolled into groups of eight, worth **1.5x** — it
was nearly half the scan, most of that a branch per delimiter. The packing of
sixty-four lanes into a `UInt64` folds the four vectors together with `addp`
before crossing to a general-purpose register, worth another **1.4x** — the
portable `pack_bits` crosses four times per mask where this crosses once. And
the quote analysis uses a carry-less multiply, worth a further **13%**, but
only because that fold leaves the mask in a vector register where `pmull64`
can take it.

x86 gets the same two ideas in its own instructions. With AVX-512BW the whole
chunk is one 64-lane comparison and each mask comes out with one `kmovq`; with
only AVX2 it is two 32-lane halves and a `vpmovmskb` each. The prefix-XOR is one
`pclmulqdq`. Together those made parsing 1.81x faster on AVX-512 and 1.38x on
AVX2, against the portable path both were using before. Anything with neither
NEON nor AVX2 still gets the portable code.

And with AVX-512 VBMI2 the delimiter walk goes away. The unrolled walk is a
serial chain -- each `bits &= bits - 1` waits on the one before -- and on
AVX-512 LLVM vectorises everything after it, so the links were computed in
scalar code, spilled to the stack, and gathered back into a `zmm`. Instead, one
`vpcompressb` packs every delimiter's lane index to the front of a vector, with
its CRLF flag in bit 7, and those are widened and stored sixteen at a time.
That is **2.2x** on the whole parse. See
[`docs/improvements.md`](docs/improvements.md).

## How it compares

[simdcsv](https://github.com/geofflangdale/simdcsv) applies the simdjson
techniques to RFC 4180. Its structural scan finds exactly the same delimiters
on both documents — 2 042 888 and 2 011 820 — and it is **1.36x faster**.
Mean of 100 passes, GiB/s, both measured in one sitting on the Apple M4 Max.
simdcsv has not been measured on x86 here, so the `vpcompressb` path has no
comparison yet -- its numbers on the Ryzen are higher than any in this table,
but that is two machines, which is exactly the mistake described below:

| | `no_escaping.csv` | `needs_escaping.csv` |
| --- | ---: | ---: |
| simdcsv, built with `-DCRLF` | **12.83** | **13.87** |
| simdcsv, default build | 11.66 | 12.66 |
| this | 9.42 | 10.15 |

An earlier version of this section claimed 1.16x. That was wrong, and not
because anything regressed: the two sides had been measured at different
moments and quietly compared. Measured together it is 1.24x against simdcsv's
default build and 1.36x against its fastest.

**Most of the gap is a feature, and it is measured.** simdcsv's default build
does not handle CRLF at all: it reports the LF position and leaves the CR
sitting at the end of your field. This one finds the same delimiters *and*
records, in the top bit of every entry, whether the delimiter was an LF with a
CR in front of it, so reading a field needs no byte compare. That costs a
fourth sixty-four lane comparison per chunk and three instructions per
delimiter — **326 and 269 microseconds, 27% of a 2199 microsecond parse**.
Two cheaper ways of getting it were tried and both were much worse; see
[`docs/improvements.md`](docs/improvements.md).

Everything simdcsv does differently has been adopted, and profiling then found
three more things it does not do: one `UInt32` per field for the index,
bitmask arithmetic over sixty-four bytes, an unrolled delimiter walk, a bulk
movemask that crosses the register file once instead of sixteen times per
chunk, and a carry-less multiply for the quote mask. Together those took
parsing from 0.89 to 8.94 GiB/s, **10x** the ported implementation. What is
left is in [`docs/improvements.md`](docs/improvements.md).

## Development

```bash
pixi run test      # the test suite (26 tests)
pixi run main      # the example
pixi run bench     # the tables above -- needs `bash data/setup.sh` first
pixi run format    # mojo format
pixi run docs      # docstring check
pixi build         # the conda package (needs pixi >= 0.80)
```

## Provenance

A port of [mzaks/mojo-csv](https://github.com/mzaks/mojo-csv), which was
written against a 2023-era Mojo and no longer compiles. Three bugs did not
survive the move and the reader's API changed shape; see
[`docs/migration.md`](docs/migration.md).

## License

MIT. See [LICENSE](LICENSE).
