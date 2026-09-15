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

**The SIMD scan is not always faster** — see [below](#which-scan). It wins by
up to 4x on documents with long fields and loses by 10-20% on documents with
short ones. It is the default because the downside is small and the upside is
not, but if you are parsing one shape of document repeatedly, measure.

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
| parse, `simd=True` | 22.8 | 965 | 11.2 |
| parse, `simd=False` | **21.8** | **1009** | **10.7** |
| read all, `field` (slice) | **3.4** | **6468** | **1.7** |
| read all, `get` (String) | 25.7 | 854 | 12.6 |
| build, `escape=False` | **19.1** | **1151** | **9.3** |
| build, `escape=True` | 32.1 | 686 | 15.7 |

**`needs_escaping.csv`** — 24.9 MB, 201 182 rows, 10 columns, 10% quoted:

| | ms | MiB/s | ns/field |
| --- | ---: | ---: | ---: |
| parse, `simd=True` | 26.1 | 908 | 13.0 |
| parse, `simd=False` | **23.6** | **1008** | **11.7** |
| read all, `field` (slice) | **3.3** | **7106** | **1.7** |
| read all, `get` (String) | 34.7 | 684 | 17.2 |
| build, `escape=False` | **20.0** | **1186** | **9.9** |
| build, `escape=True` | 35.5 | 690 | 17.7 |

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

The vectorised scan reads `simd_width_of[uint8]()` bytes at a time — 16 with
NEON — and compares them against quote, separator and newline in parallel. But
it then has to visit every delimiter it found. When fields are short there is
a delimiter every few bytes, that visiting dominates, and the vector work buys
nothing.

Twelve megabytes of four-column rows, all fields one width:

| mean field bytes | scalar ms | simd ms | simd wins by |
| ---: | ---: | ---: | ---: |
| 2 | 6.9 | **6.7** | 1.03x |
| 4 | 5.8 | **4.9** | 1.18x |
| 8 | 6.1 | **3.4** | 1.79x |
| 16 | 6.2 | **2.6** | 2.38x |
| 32 | 6.1 | **1.5** | 4.07x |
| 64 | 6.1 | **1.0** | 6.10x |
| 128 | 6.4 | **0.7** | 9.14x |
| 256 | 5.9 | **0.6** | 9.83x |

The upstream README said SIMD tokenising was "about 20% faster". It is, for
long fields, and by far more than 20%. For short ones it is a wash, and both
benchmark documents above are in that region — where the scalar scan wins by
about 4%.

**Mean field length does not predict which wins**, which is why the choice is
not made automatically. The sweep says SIMD is well ahead at 8-byte fields,
but both benchmark documents sit at 11-12 bytes per field and scalar wins
there by 4%. Uniform fields are not the same shape as a real distribution
with a median of 6 and a tail to 46, and until something predicts the real
case, guessing on the caller's behalf would be worse than letting them
measure. See [`docs/improvements.md`](docs/improvements.md).

## How it compares

[simdcsv](https://github.com/geofflangdale/simdcsv) applies the simdjson
techniques to RFC 4180, and on the same documents its structural scan finds
exactly the same delimiters about **ten times faster** — 11.1 GB/s against our
1.06. The index here has already been cut to one `UInt32` per field partly on
the strength of that comparison, which bought 3-13% and a 4x reduction in
index memory, rather than the 2x a first reading of the numbers suggested.
What remains is the scan itself. Both are written up in
[`docs/improvements.md`](docs/improvements.md).

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
