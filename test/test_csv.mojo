"""Tests for reading and writing CSV.

Three kinds of thing here. RFC 4180 conformance, rule by rule, because that is
what the library claims to implement. Agreement between the two scan paths,
because the SIMD one is only worth having if it cannot disagree with the
scalar one. And regressions for the three bugs the ported implementation had,
each written so it fails if the fix is taken out.
"""

from mm_csv import CsvBuilder, CsvTable
from std.testing import TestSuite, assert_equal, assert_false, assert_true


def _fields(var text: String, simd: Bool) raises -> List[String]:
    """Returns every field of `text` in document order."""
    var table = CsvTable(text^, simd=simd)
    var out = List[String]()
    for row in range(table.row_count()):
        for column in range(table.column_count):
            out.append(table.get(row, column))
    return out^


def _assert_parses(
    var text: String, expected: List[String], columns: Int, context: String
) raises:
    """Checks both scan paths produce `expected`, laid out in `columns`."""
    for simd in [True, False]:
        var table = CsvTable(text, simd=simd)
        assert_equal(
            table.column_count,
            columns,
            String(context, " (simd=", simd, "): column count"),
        )
        var got = _fields(text, simd)
        assert_equal(
            len(got),
            len(expected),
            String(context, " (simd=", simd, "): field count"),
        )
        for i in range(len(got)):
            assert_equal(
                got[i],
                expected[i],
                String(context, " (simd=", simd, "): field ", i),
            )


# ===-----------------------------------------------------------------------===#
# RFC 4180
# ===-----------------------------------------------------------------------===#


def test_records_separated_by_crlf() raises:
    _assert_parses(
        "aaa,bbb,ccc\r\nzzz,yyy,xxx\r\n",
        [String("aaa"), "bbb", "ccc", "zzz", "yyy", "xxx"],
        3,
        "rule 1, CRLF between records",
    )


def test_last_record_may_omit_the_line_break() raises:
    """Rule 2, and the case that made the ported `row_count` divide by -1."""
    _assert_parses(
        "aaa,bbb,ccc\r\nzzz,yyy,xxx",
        [String("aaa"), "bbb", "ccc", "zzz", "yyy", "xxx"],
        3,
        "rule 2, no trailing break",
    )
    _assert_parses(
        "aaa,bbb,ccc", [String("aaa"), "bbb", "ccc"], 3, "rule 2, one row only"
    )


def test_bare_line_feeds_are_accepted() raises:
    """Not RFC, but every tool in the world emits it."""
    _assert_parses("a,b\nc,d\n", [String("a"), "b", "c", "d"], 2, "bare LF")


def test_fields_may_be_quoted_or_not() raises:
    _assert_parses(
        '"aaa","bbb","ccc"\r\nzzz,yyy,xxx\r\n',
        [String("aaa"), "bbb", "ccc", "zzz", "yyy", "xxx"],
        3,
        "rule 5, mixed quoting",
    )


def test_quoted_fields_may_hold_separators_and_breaks() raises:
    """Rule 6: a comma, a CRLF or an LF inside quotes is data."""
    _assert_parses(
        '"aaa","b\r\nbb","ccc"\r\nzzz,yyy,xxx\r\n',
        [String("aaa"), "b\r\nbb", "ccc", "zzz", "yyy", "xxx"],
        3,
        "rule 6, CRLF inside quotes",
    )
    _assert_parses(
        'a,"b,c",d\r\n',
        [String("a"), "b,c", "d"],
        3,
        "rule 6, comma inside quotes",
    )
    _assert_parses(
        'a,"b\nc",d\r\n',
        [String("a"), "b\nc", "d"],
        3,
        "rule 6, LF inside quotes",
    )


def test_a_quote_inside_a_quoted_field_is_doubled() raises:
    _assert_parses(
        '"aaa","b""bb","ccc"\r\n',
        [String("aaa"), 'b"bb', "ccc"],
        3,
        "rule 7, doubled quote",
    )
    _assert_parses(
        '"""","""x""",""\r\n',
        [String('"'), '"x"', ""],
        3,
        "rule 7, quotes at the edges",
    )


def test_empty_fields_and_empty_rows() raises:
    _assert_parses(
        "a,,c\r\n,,\r\n", [String("a"), "", "c", "", "", ""], 3, "empty fields"
    )


def test_unicode_survives() raises:
    _assert_parses(
        "α,β\r\n日本,🎉\r\n",
        [String("α"), "β", "日本", "🎉"],
        2,
        "multi-byte fields",
    )


def test_empty_document() raises:
    var table = CsvTable(String(""))
    assert_equal(table.column_count, 0, "no columns")
    assert_equal(table.row_count(), 0, "no rows")
    assert_equal(len(table), 0, "no fields")


# ===-----------------------------------------------------------------------===#
# The two scan paths must not disagree
# ===-----------------------------------------------------------------------===#


def test_scan_paths_agree_across_chunk_boundaries() raises:
    """A CRLF straddling a SIMD chunk is only visible to the carry-over flag.

    The SIMD scan looks at 16 or 32 bytes at a time and has to remember whether
    the previous chunk ended on a CR. Padding the first field to every length
    in a wide range walks the CRLF across every lane of that boundary.
    """
    for pad in range(0, 200):
        var filler = String("")
        for _ in range(pad):
            filler += "x"
        var text = String(filler, ",b\r\nc,d\r\n")
        var simd_fields = _fields(text, True)
        var scalar_fields = _fields(text, False)
        assert_equal(
            len(simd_fields), len(scalar_fields), String("pad ", pad, ": count")
        )
        for i in range(len(simd_fields)):
            assert_equal(
                simd_fields[i],
                scalar_fields[i],
                String("pad ", pad, ": field ", i),
            )


def test_scan_paths_agree_with_quotes_across_boundaries() raises:
    """The in-quotes state has to survive a chunk boundary too."""
    for pad in range(0, 200):
        var filler = String("")
        for _ in range(pad):
            filler += "y"
        var text = String('a,"', filler, ',still one field",c\r\n')
        var simd_fields = _fields(text, True)
        var scalar_fields = _fields(text, False)
        assert_equal(len(simd_fields), 3, String("pad ", pad, ": count"))
        for i in range(len(simd_fields)):
            assert_equal(
                simd_fields[i],
                scalar_fields[i],
                String("pad ", pad, ": field ", i),
            )


# ===-----------------------------------------------------------------------===#
# Writing
# ===-----------------------------------------------------------------------===#


def test_builder_writes_a_header_and_rows() raises:
    var names: List[String] = ["a", "b", "c"]
    var builder = CsvBuilder(names^)
    for i in range(1, 7):
        builder.push_value(i)
    assert_equal(
        builder^.finish(),
        "a,b,c\r\n1,2,3\r\n4,5,6\r\n",
        "header and two rows",
    )


def test_builder_escapes_what_it_must() raises:
    var builder = CsvBuilder(4)
    builder.push("plain")
    builder.push("has,comma")
    builder.push('has"quote')
    builder.push("has\r\nbreak")
    assert_equal(
        builder^.finish(),
        'plain,"has,comma","has""quote","has\r\nbreak"\r\n',
        "escaping",
    )


def test_builder_fills_the_last_row() raises:
    var builder = CsvBuilder(3)
    builder.push_value(1)
    assert_equal(builder^.finish(), "1,,\r\n", "short row filled")


def test_builder_buffer_boundaries() raises:
    """Documents of many sizes must survive the buffer doubling intact.

    This does *not* catch the overflow the ported `finish` had -- that wrote
    two bytes past the end of an exactly-full buffer, and the bytes it wrote
    still read back correctly, so only a memory checker can see it. Neither
    libgmalloc nor `MallocScribble` intercepts Mojo's allocator here, so that
    fix rests on the reasoning in `docs/migration.md` and not on a test. What
    this does check is that growing the buffer never loses or corrupts a
    field, across every width that walks the total past a doubling.
    """
    for width in range(1, 120):
        var value = String("")
        for _ in range(width):
            value += "z"
        var builder = CsvBuilder(2)
        var rows = 0
        while rows * (width * 2 + 3) < 1200:
            builder.push(value, escape=False)
            builder.push(value, escape=False)
            rows += 1
        var text = builder^.finish()
        var table = CsvTable(text)
        assert_equal(
            table.row_count(), rows, String("width ", width, ": row count")
        )
        assert_equal(
            table.get(rows - 1, 1),
            value,
            String("width ", width, ": last field"),
        )


def test_far_more_delimiters_than_the_index_was_sized_for() raises:
    """Regression: the index is sized from the document, and can be wrong.

    The scan reserves one entry per eight bytes and then writes through a raw
    pointer in unrolled groups, past the count, into slack. A document of
    two-byte fields has a delimiter every three bytes -- four times the guess
    -- so without a per-chunk capacity check the writes run off the end of the
    allocation. That crashed, and only on documents denser than the estimate,
    which none of the other tests are.
    """
    var text = String()
    for _ in range(20000):
        text += "ab,ab,ab,ab\r\n"
    var table = CsvTable(text^)
    assert_equal(table.column_count, 4, "columns")
    assert_equal(table.row_count(), 20000, "rows")
    assert_equal(len(table), 80000, "fields")
    assert_equal(table.get(19999, 3), "ab", "last field")

    # And the other way: one enormous field, far fewer delimiters than the
    # estimate, so the index is mostly slack.
    var wide = String()
    for _ in range(50000):
        wide += "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    var sparse = CsvTable(String(wide, ",b\r\n"))
    assert_equal(sparse.column_count, 2, "sparse columns")
    assert_equal(sparse.get(0, 1), "b", "sparse second field")


def test_round_trip() raises:
    """Anything written must read back as what went in."""
    var awkward: List[String] = [
        String("plain"),
        "",
        "with,comma",
        'with"quote',
        'both,"together',
        "with\r\nbreak",
        "with\nbare",
        "  padded  ",
        "α日本🎉",
        '"',
        '""',
    ]
    var builder = CsvBuilder(len(awkward))
    for i in range(len(awkward)):
        builder.push(awkward[i])
    var text = builder^.finish()
    for simd in [True, False]:
        var table = CsvTable(text, simd=simd)
        assert_equal(
            table.column_count, len(awkward), String("simd=", simd, ": columns")
        )
        for i in range(len(awkward)):
            assert_equal(
                table.get(0, i),
                awkward[i],
                String("simd=", simd, ": field ", i),
            )


# ===-----------------------------------------------------------------------===#
# The borrowed accessor
# ===-----------------------------------------------------------------------===#


def test_field_borrows_and_get_unescapes() raises:
    var table = CsvTable(String('a,"b,c",d\r\n'))
    assert_equal(String(table.field(0, 0)), "a", "unquoted field is raw")
    assert_equal(String(table.field(0, 1)), '"b,c"', "quoted field is raw")
    assert_equal(table.get(0, 1), "b,c", "get unescapes")
    assert_false(table.is_quoted(0, 0), "a is not quoted")
    assert_true(table.is_quoted(0, 1), "b,c is quoted")


def test_out_of_range_raises() raises:
    """The ported implementation returned "" here, indistinguishable from a
    genuinely empty field."""
    var table = CsvTable(String("a,b\r\nc,d\r\n"))
    var raised = 0
    try:
        _ = table.get(0, 2)
    except:
        raised += 1
    try:
        _ = table.get(2, 0)
    except:
        raised += 1
    try:
        _ = table.get(-1, 0)
    except:
        raised += 1
    assert_equal(raised, 3, "all three out-of-range reads raise")
    assert_equal(table.get(1, 1), "d", "in-range still works")


def test_ragged_is_reported() raises:
    var table = CsvTable(String("a,b,c\r\nd,e\r\n"))
    assert_true(table.is_ragged(), "second row is short")
    var even = CsvTable(String("a,b\r\nc,d\r\n"))
    assert_false(even.is_ragged(), "rows match")


def test_custom_separator() raises:
    var table = CsvTable[UInt8(ord("\t"))](String("a\tb\r\nc\td\r\n"))
    assert_equal(table.column_count, 2, "tab separated columns")
    assert_equal(table.get(1, 0), "c", "tab separated value")

    var builder = CsvBuilder[UInt8(ord("\t"))](2)
    builder.push("x")
    builder.push("has\ttab")
    assert_equal(
        builder^.finish(),
        'x\t"has\ttab"\r\n',
        "tab writer quotes its own separator",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
