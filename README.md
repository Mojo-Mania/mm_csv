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
borrowing the original text at **1.7 ns per field**, and `get` is the one that
undoes RFC 4180 escaping and allocates.

## When to use it

**The reader owns the document.** `CsvTable` takes the whole text as a
`String` and keeps it, because every field is a slice of it. That is what
makes reading free; it also means the document has to fit in memory. There is
no streaming reader here.

**Reach for `field` before `get`.** They differ by 7-10x. `get` allocates a
`String` and undoes escaping; `field` gives you the raw bytes and copies
nothing. `is_quoted` tells you whether the difference matters for a given
field.

**Leave the SIMD scan on.** It is the default and it wins at every field width
measured, by 1.6x on two-byte fields and 6.6x on 256-byte ones. The scalar walk
is kept as the reference implementation the tests compare against, not as an
option you are meant to need.

**Documents must be under 2 GiB.** Field positions are indexed with 31 bits
and a flag; a larger document aborts with a message saying so.

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

Apple M4 Max, `-D ASSERT=none`, best of three runs, two runs agreeing to
within 6%. Reproduce with `bash data/setup.sh && pixi run bench`.

The two documents are generated, not committed — the originals were New
Zealand government statistics exports whose URLs are now dead, so
`data/setup.sh` builds files matching their row count, column count, quoted
fraction and field-length distribution. It prints the shape it produced.

**`no_escaping.csv`** — 23.1 MB, 255 361 rows, 8 columns, nothing quoted:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **2.4** | **9289** | **1.2** |
| parse, `simd=False` | 21.7 | 1012 | 10.6 |
| read all, `field` (slice) | **3.4** | **6397** | **1.7** |
| read all, `get` (String) | 25.7 | 855 | 12.6 |
| build, `escape=False` | **18.9** | **1166** | **9.2** |
| build, `escape=True` | 31.8 | 692 | 15.6 |

**`needs_escaping.csv`** — 24.9 MB, 201 182 rows, 10 columns, 10% quoted:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **2.4** | **9977** | **1.2** |
| parse, `simd=False` | 23.3 | 1017 | 11.6 |
| read all, `field` (slice) | **3.4** | **7070** | **1.7** |
| read all, `get` (String) | 34.6 | 687 | 17.2 |
| build, `escape=False` | **19.8** | **1197** | **9.9** |
| build, `escape=True` | 35.2 | 696 | 17.5 |

Two things to read off these.

**Borrowing beats copying by 7-10x.** Walking every field costs 1.7 ns each
through `field` and 12-17 ns through `get`. That whole difference is
allocating a `String` per field and undoing escaping. On a document with no
quoted fields at all, `get` still costs 7x more, because it still allocates.

**Escaping costs about 70% on writing**, not the 10x the upstream README
warned of. That is the price of looking at every byte of every value, and the
`_needs_escaping` check here is vectorised, which the original's was not for
the tail.

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

It wins at every field width measured:

| mean field bytes | scalar ms | simd ms | simd wins by |
| ---: | ---: | ---: | ---: |
| 2 | 6.9 | **3.6** | 1.92x |
| 4 | 5.9 | **1.8** | 3.28x |
| 8 | 6.2 | **1.1** | 5.64x |
| 16 | 6.0 | **1.1** | 5.45x |
| 32 | 6.0 | **1.1** | 5.45x |
| 64 | 6.1 | **1.1** | 5.55x |
| 128 | 6.6 | **0.8** | 8.25x |
| 256 | 5.8 | **0.7** | 8.29x |

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
can take it. On anything without NEON all three fall back to portable code.
See [`docs/improvements.md`](docs/improvements.md).

## How it compares

[simdcsv](https://github.com/geofflangdale/simdcsv) applies the simdjson
techniques to RFC 4180, and on the same documents its structural scan finds
exactly the same delimiters **1.16x faster** — 11.1 GB/s against our 9.6.
Everything it does differently has been adopted, and then profiling found
three more things it does not: one `UInt32` per field for the index, bitmask
arithmetic over sixty-four bytes, an unrolled delimiter walk, a bulk movemask
that crosses the register file once instead of sixteen times per chunk, and a
carry-less multiply for the quote mask. Together those took parsing from 0.85
to 9.6 GB/s, **11x** the ported implementation. What is left is in
[`docs/improvements.md`](docs/improvements.md).

## Development

```bash
pixi run test      # the test suite (21 tests)
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
