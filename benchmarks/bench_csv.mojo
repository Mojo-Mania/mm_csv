"""What reading and writing a CSV document costs.

Run `bash data/setup.sh` first; it builds the two files this reads and prints
their shape. Neither is committed.

Four things get measured.

*Parsing* is the tokenising pass -- finding every field boundary -- and is
reported both ways, SIMD and scalar, because the SIMD path only earns its
complexity if it is meaningfully faster.

*Reading* is what you do afterwards. `field` hands back a slice of the
document and copies nothing; `get` undoes RFC 4180 escaping and therefore
allocates. On a file with no quoted fields they do the same work and the gap
between them is the cost of allocating a `String` per field, which is worth
knowing before you reach for one.

*Writing* is measured with escaping on and off. Leaving it on means looking at
every byte of every value, and the difference is the price of a document that
is valid no matter what goes into it.

Throughput is MiB/s over the document. Higher is better.
"""

from mm_csv import CsvBuilder, CsvTable
from std.benchmark import keep
from std.pathlib import cwd
from std.time import perf_counter_ns

comptime _REPEATS = 3


def fixed(value: Float64, decimals: Int = 1) -> String:
    """Formats `value` with exactly `decimals` digits after the point."""
    var scale = 1
    for _ in range(decimals):
        scale *= 10
    var scaled = Int(value * Float64(scale) + 0.5)
    var digits = String(scaled % scale)
    while digits.byte_length() < decimals:
        digits = String("0", digits)
    return String(scaled // scale, ".", digits)


def rjust(text: String, width: Int) -> String:
    """Right-aligns `text` in a field `width` wide."""
    var out = text.copy()
    while out.byte_length() < width:
        out = String(" ", out)
    return out


def ljust(text: String, width: Int) -> String:
    """Left-aligns `text` in a field `width` wide."""
    var out = text.copy()
    while out.byte_length() < width:
        out += " "
    return out


def report(label: String, nanos: Float64, bytes: Int, fields: Int):
    """Prints one measurement as throughput and per-field cost."""
    var mib = Float64(bytes) / (1024.0 * 1024.0)
    var seconds = nanos / 1e9
    print(
        ljust(label, 26),
        rjust(fixed(nanos / 1e6), 9),
        rjust(fixed(mib / seconds), 10),
        rjust(fixed(nanos / Float64(fields), 1), 10),
    )


def load(name: String) raises -> String:
    """Reads one of the generated files."""
    var path = cwd() / "data" / name
    if not path.exists():
        raise Error(
            "data/",
            name,
            " is missing. Run `bash data/setup.sh` to build the benchmark",
            " files; they are not committed.",
        )
    return path.read_text()


def bench_file(name: String) raises:
    var text = load(name)
    var bytes = text.byte_length()
    var probe = CsvTable(text)
    var rows = probe.row_count()
    var columns = probe.column_count
    var fields = rows * columns
    print()
    print(
        name,
        ": ",
        bytes,
        " bytes, ",
        rows,
        " rows, ",
        columns,
        " columns",
        sep="",
    )
    print(
        ljust("", 26),
        rjust("ms", 9),
        rjust("MiB/s", 10),
        rjust("ns/field", 10),
    )

    for use_simd in [True, False]:
        var best = Float64(1e30)
        for _ in range(_REPEATS):
            var start = perf_counter_ns()
            var table = CsvTable(text, simd=use_simd)
            var elapsed = Float64(perf_counter_ns() - start)
            keep(table.column_count)
            if elapsed < best:
                best = elapsed
        report(String("parse, simd=", use_simd), best, bytes, fields)

    var table = CsvTable(text)

    var best_slice = Float64(1e30)
    for _ in range(_REPEATS):
        var start = perf_counter_ns()
        var total = 0
        for row in range(rows):
            for column in range(columns):
                total += table.field(row, column).byte_length()
        var elapsed = Float64(perf_counter_ns() - start)
        keep(total)
        if elapsed < best_slice:
            best_slice = elapsed
    report("read all, field (slice)", best_slice, bytes, fields)

    var best_get = Float64(1e30)
    for _ in range(_REPEATS):
        var start = perf_counter_ns()
        var total = 0
        for row in range(rows):
            for column in range(columns):
                total += table.get(row, column).byte_length()
        var elapsed = Float64(perf_counter_ns() - start)
        keep(total)
        if elapsed < best_get:
            best_get = elapsed
    report("read all, get (String)", best_get, bytes, fields)

    # Writing: feed every value straight back out.
    for escape in [False, True]:
        var best_build = Float64(1e30)
        var written = 0
        for _ in range(_REPEATS):
            var start = perf_counter_ns()
            var builder = CsvBuilder(columns)
            for row in range(rows):
                for column in range(columns):
                    builder.push(table.field(row, column), escape=escape)
            var out = builder^.finish()
            var elapsed = Float64(perf_counter_ns() - start)
            written = out.byte_length()
            keep(written)
            if elapsed < best_build:
                best_build = elapsed
        report(String("build, escape=", escape), best_build, written, fields)


def bench_field_widths() raises:
    """Where the SIMD scan starts to pay, as a function of field length.

    The vectorised scan looks at `simd_width_of[uint8]()` bytes at once, but
    then has to visit every delimiter it found. When fields are short there is
    a delimiter every few bytes, the visiting dominates, and the vector work
    buys nothing. When fields are long the scan skips whole chunks at a time.

    Twelve megabytes of four-column rows, all fields the same width.
    """
    print()
    print("Field width against scan choice, 12 MB of four-column rows:")
    print(
        ljust("  mean field bytes", 20),
        rjust("scalar ms", 11),
        rjust("simd ms", 9),
        rjust("simd wins by", 14),
    )
    comptime widths = [2, 4, 8, 16, 32, 64, 128, 256]
    comptime for w in range(len(widths)):
        comptime width = widths[w]
        var cell = String()
        for i in range(width):
            cell += String(chr(97 + (i % 26)))
        var row = String()
        for column in range(4):
            if column != 0:
                row += ","
            row += cell
        row += "\r\n"
        var text = String()
        for _ in range(12_000_000 // row.byte_length()):
            text += row

        var best = List[Float64](length=2, fill=1e30)
        for which in range(2):
            for _ in range(_REPEATS):
                var start = perf_counter_ns()
                var table = CsvTable(text, simd=(which == 1))
                var elapsed = Float64(perf_counter_ns() - start)
                keep(table.column_count)
                if elapsed < best[which]:
                    best[which] = elapsed
        print(
            ljust(String("  ", width), 20),
            rjust(fixed(best[0] / 1e6), 11),
            rjust(fixed(best[1] / 1e6), 9),
            rjust(String(fixed(best[0] / best[1], 2), "x"), 14),
        )


def main() raises:
    print("Reading and writing CSV. Best of", _REPEATS, "runs.")
    bench_file("no_escaping.csv")
    bench_file("needs_escaping.csv")
    bench_field_widths()
