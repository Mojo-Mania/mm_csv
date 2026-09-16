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
read a document once. Measured, it is **not faster**: 20% slower than building
the index and walking it on an Apple M4, level with it on x86, for reasons in
the performance section. What it buys is the
four bytes a field that the index costs -- 8 MB on a 23 MB document -- and
freedom from the 2 GiB ceiling, because its offsets are full-width integers.
Take it when the memory matters or the document is enormous; otherwise take
`CsvTable`.

**Reach for `field` before `get`.** They differ by 7-10x. `get` allocates a
`String` and undoes escaping; `field` gives you the raw bytes and copies
nothing. `is_quoted` tells you whether the difference matters for a given
field.

**Leave the SIMD scan on.** It is the default and it wins at every field width
measured, on both machines: from 1.6x on two-byte fields to 8.9x on 256-byte
ones on an Apple M4, and from 2.1x to 11-13x on x86. The scalar walk
is kept as the reference implementation the tests compare against, not as an
option you are meant to need.

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

AVX-512, Linux, Mojo 1.2.0.dev2026091505. Three runs agreeing to within 2%.

**`no_escaping.csv`**:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **2.6** | **8546** | **1.3** |
| parse, `simd=False` | 21.4 | 1027 | 10.5 |
| read all, `field` (slice) | **1.5** | **14975** | **0.7** |
| read all, `get` (String) | 24.3 | 907 | 11.9 |
| stream, no index | 4.1 | 5390 | 2.0 |
| build, `escape=False` | **20.3** | **1086** | **9.9** |
| build, `escape=True` | 37.3 | 589 | 18.3 |

**`needs_escaping.csv`**:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **2.7** | **8815** | **1.3** |
| parse, `simd=False` | 23.2 | 1023 | 11.5 |
| read all, `field` (slice) | **1.4** | **16535** | **0.7** |
| read all, `get` (String) | 26.1 | 910 | 13.0 |
| stream, no index | 4.2 | 5592 | 2.1 |
| build, `escape=False` | **21.6** | **1099** | **10.7** |
| build, `escape=True` | 40.0 | 613 | 19.9 |

Parsing is 11-16% behind the M4 and writing 4-17% behind; reading through
`field` is 7-8% ahead, and streaming 20% ahead. Before the scan had x86 paths
of its own it parsed at 4.4 GiB/s here -- half this -- because it was running
the portable fallback; see [`docs/improvements.md`](docs/improvements.md). An
AVX2 build without AVX-512 parses `no_escaping.csv` in 2.8 ms.

### Reading the tables

**Borrowing beats copying by 15-20x.** Walking every field costs 0.7-0.8 ns
each through `field` and 12-16 ns through `get`. That whole difference is
allocating a `String` per field and undoing escaping. On a document with no
quoted fields at all, `get` still costs 14x more, because it still allocates.

**Not building the index costs as much as building it, or more.** On the M4,
parsing and then walking every field is 2.3 + 1.6 = 3.9 ms; streaming the same
fields with no index at all is 4.9. On x86 the two are level, 4.0 against 4.1
ms. The reason is that the index is written by an unrolled loop that emits eight offsets per chunk whether or not eight delimiters are
there, because writing a few junk entries into slack is free -- no branch per
delimiter anywhere. A consumer cannot be handed junk fields, so `CsvFields`
has to test and branch once per field, and that branch costs more than the
store it avoids. Reading the index back afterwards is then a flat,
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
| 2 | 6.7 | **3.2** | 2.07x |
| 4 | 5.7 | **1.6** | 3.59x |
| 8 | 5.3 | **1.3** | 4.05x |
| 16 | 5.0 | **1.3** | 3.91x |
| 32 | 4.9 | **1.3** | 3.84x |
| 64 | 5.2 | **1.3** | 4.06x |
| 128 | 5.8 | **0.7** | 8.14x |
| 256 | 5.5 | **0.4** | 12.62x |

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
NEON nor AVX2 still gets the portable code. See
[`docs/improvements.md`](docs/improvements.md).

## How it compares

[simdcsv](https://github.com/geofflangdale/simdcsv) applies the simdjson
techniques to RFC 4180. Its structural scan finds exactly the same delimiters
on both documents — 2 042 888 and 2 011 820 — and it is **1.36x faster**.
Mean of 100 passes, GiB/s, both measured in one sitting on the Apple M4 Max.
simdcsv has not been measured on x86 here:

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
