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
| parse, `simd=True` | **8.2** | **2672** | **4.0** |
| parse, `simd=False` | 21.6 | 1016 | 10.6 |
| read all, `field` (slice) | **3.4** | **6421** | **1.7** |
| read all, `get` (String) | 25.9 | 848 | 12.7 |
| build, `escape=False` | **18.2** | **1206** | **8.9** |
| build, `escape=True` | 32.3 | 681 | 15.8 |

**`needs_escaping.csv`** — 24.9 MB, 201 182 rows, 10 columns, 10% quoted:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | **8.8** | **2700** | **4.4** |
| parse, `simd=False` | 23.2 | 1022 | 11.5 |
| read all, `field` (slice) | **3.3** | **7152** | **1.6** |
| read all, `get` (String) | 35.1 | 676 | 17.5 |
| build, `escape=False` | **19.5** | **1219** | **9.7** |
| build, `escape=True` | 35.8 | 684 | 17.8 |

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
| 2 | 7.0 | **4.5** | 1.56x |
| 4 | 6.5 | **3.0** | 2.17x |
| 8 | 5.2 | **2.4** | 2.17x |
| 16 | 6.0 | **2.4** | 2.50x |
| 32 | 6.1 | **2.4** | 2.54x |
| 64 | 6.3 | **2.3** | 2.74x |
| 128 | 6.7 | **1.4** | 4.79x |
| 256 | 5.9 | **0.9** | 6.56x |

That was not true of the first version of this scan, which looked at sixteen
bytes and visited each match through a scratch buffer. It lost to the scalar
walk on short fields — which is what both documents above have — and the
upstream README's claim that SIMD tokenising was "about 20% faster" held only
for long ones. Rewriting it as bitmask arithmetic made the parse **2.8x**
faster on those documents and turned a coin flip into a default worth having.

One cost is worth knowing about. Packing sixteen lanes into sixteen bits is
most of the work in a chunk, and Mojo has no movemask — `SIMD[bool, N].to_bits()`
returns a lane-wise vector, not a packed integer — so it is done by shifting
each lane by its own index and ORing. A chunk containing nothing at all skips
that entirely, which is what keeps long-field documents fast, but a chunk with
one delimiter in it pays the same as a chunk with thirty. See
[`docs/improvements.md`](docs/improvements.md).

## How it compares

[simdcsv](https://github.com/geofflangdale/simdcsv) applies the simdjson
techniques to RFC 4180, and on the same documents its structural scan finds
exactly the same delimiters about **four times faster** — 11.1 GB/s against
our 2.7. Two of the three things it does differently have been adopted since
that comparison: the index is one `UInt32` per field, and the scan is bitmask
arithmetic over sixty-four bytes with a prefix-XOR for quotes. Together they
took parsing from 0.85 to 2.7 GB/s. What is left is mostly that Mojo has no
movemask instruction and no carry-less multiply, so both are emulated. Written
up in [`docs/improvements.md`](docs/improvements.md).

## Development

```bash
pixi run test      # the test suite (20 tests)
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
