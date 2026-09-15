"""Reading CSV: tokenise once, then index.

`CsvTable` takes the whole document as a `String` and makes one pass over it,
recording where every field starts and ends. Nothing is copied and nothing is
allocated per field. Reading a value afterwards is index arithmetic, and for
the common case -- a field with no quotes in it -- handing back a `StringSlice`
that borrows the original text.

The scan can be done two ways. `_scan_scalar` walks a byte at a time and is the
definition of what the parser does. `_scan_simd` loads `simd_width_of[uint8]()`
bytes at once, compares them against quote, separator and newline in parallel,
and only visits the positions where something matched. Both produce the same
index lists, which is what `test/test_csv.mojo` checks on every corpus.

Escaping follows RFC 4180: a field may be wrapped in double quotes, and inside
such a field a literal double quote is written twice.
"""

from std.math import iota
from std.memory import stack_allocation
from std.sys.info import simd_width_of
from std.sys.intrinsics import compressed_store

comptime QUOTE = UInt8(ord('"'))
comptime LF = UInt8(ord("\n"))
comptime CR = UInt8(ord("\r"))
comptime COMMA = UInt8(ord(","))

comptime WIDTH = simd_width_of[DType.uint8]()
"""Bytes the SIMD scan looks at per step: 16 with NEON, 32 with AVX2."""


struct CsvTable[separator: UInt8 = COMMA](Movable, Sized):
    """A parsed CSV document.

    Parameters:
        separator: The byte between fields. `,` by default; `\\t` for TSV.
    """

    var _text: String
    """The document, owned. Every field is a slice of this."""

    var _starts: List[Int]
    var _ends: List[Int]
    """Field boundaries, one entry per field, in document order."""

    var column_count: Int
    """Fields in the first row, which RFC 4180 says every row must match."""

    def __init__(out self, var text: String, *, simd: Bool = True):
        """Parses `text`.

        Args:
            text: The whole document. Taken by value and kept; fields borrow
                from it.
            simd: Whether to use the vectorised scan. The scalar one is the
                reference implementation and exists to be compared against.
        """
        self._text = text^
        self._starts = []
        self._ends = []
        self.column_count = 0

        var length = self._text.byte_length()
        if length == 0:
            return

        self._starts.append(0)
        var columns: Int
        if simd:
            columns = self._scan_simd(length)
        else:
            columns = self._scan_scalar(length, 0, False, -1)

        # The scan leaves a dangling start after a final newline; otherwise the
        # last field is still open and needs closing.
        if self._text.unsafe_ptr()[unsafe_offset=length - 1] == LF:
            _ = self._starts.pop()
        else:
            self._ends.append(length)

        # A document with no line break at all is one row, and its column count
        # is however many fields it has. Leaving this at -1 is what made the
        # ported implementation's `row_count` divide by a negative number.
        self.column_count = columns if columns > 0 else len(self._ends)

    def _scan_scalar(
        mut self,
        length: Int,
        var offset: Int,
        var in_quotes: Bool,
        var columns: Int,
    ) -> Int:
        """Walks bytes from `offset`, recording boundaries. Returns the column count.
        """
        var ptr = self._text.unsafe_ptr()
        while offset < length:
            var byte = ptr[unsafe_offset=offset]
            if byte == QUOTE:
                in_quotes = not in_quotes
            elif in_quotes:
                pass
            elif byte == Self.separator:
                self._ends.append(offset)
                self._starts.append(offset + 1)
            elif byte == LF:
                # A CRLF ends the field one byte earlier than the LF does.
                var back = 1 if (
                    offset > 0 and ptr[unsafe_offset=offset - 1] == CR
                ) else 0
                self._ends.append(offset - back)
                self._starts.append(offset + 1)
                if columns == -1:
                    columns = len(self._ends)
            offset += 1
        return columns

    def _scan_simd(mut self, length: Int) -> Int:
        """Walks `WIDTH` bytes at a time, visiting only positions that matched.
        """
        var ptr = self._text.unsafe_ptr()
        var quote_vec = SIMD[DType.uint8, WIDTH](QUOTE)
        var sep_vec = SIMD[DType.uint8, WIDTH](Self.separator)
        var lf_vec = SIMD[DType.uint8, WIDTH](LF)
        var cr_vec = SIMD[DType.uint8, WIDTH](CR)

        # One scratch buffer for the whole scan. The implementation this was
        # ported from allocated this inside the loop and never freed it, which
        # leaked `WIDTH` bytes per chunk -- about a gigabyte, in sixty-seven
        # million allocations, for a gigabyte of input.
        var hits = stack_allocation[WIDTH, UInt8]()
        var lane_ids = iota[DType.uint8, WIDTH]()

        var in_quotes = False
        var previous_chunk_ended_on_cr = False
        var columns = -1
        var offset = 0

        while offset + WIDTH <= length:
            var chunk = ptr.unsafe_offset(offset).unsafe_load[width=WIDTH]()
            var quotes = chunk.eq(quote_vec)
            var separators = chunk.eq(sep_vec)
            var line_feeds = chunk.eq(lf_vec)
            var carriage_returns = chunk.eq(cr_vec)
            var interesting = quotes | separators | line_feeds

            var count = Int(interesting.reduce_bit_count())
            if count != 0:
                compressed_store(lane_ids, hits, interesting)
                for k in range(count):
                    var lane = Int(hits[unsafe_offset=k])
                    if quotes[lane]:
                        in_quotes = not in_quotes
                        continue
                    if in_quotes:
                        continue
                    var position = offset + lane
                    var back = 0
                    if line_feeds[lane]:
                        if lane > 0:
                            back = Int(carriage_returns[lane - 1])
                        else:
                            back = Int(previous_chunk_ended_on_cr)
                    self._ends.append(position - back)
                    self._starts.append(position + 1)
                    if columns == -1 and line_feeds[lane]:
                        columns = len(self._ends)

            # Tracked for every chunk, matches or not: a CRLF straddling a
            # chunk boundary is only visible from here.
            previous_chunk_ended_on_cr = carriage_returns[WIDTH - 1]
            offset += WIDTH

        return self._scan_scalar(length, offset, in_quotes, columns)

    def __len__(self) -> Int:
        """Returns the number of fields the document holds.

        Returns:
            Every field in every row, including empty ones.
        """
        return len(self._ends)

    def row_count(self) -> Int:
        """Returns the number of rows.

        Returns:
            Fields divided by columns, or 0 for an empty document.
        """
        if self.column_count == 0:
            return 0
        return len(self._ends) // self.column_count

    def is_ragged(self) -> Bool:
        """Returns whether some row has a different field count from the first.

        RFC 4180 requires every row to hold the same number of fields, and the
        row-and-column arithmetic here assumes it. A document that fails this
        can still be read field by field through `__len__` and `field`, but
        `get(row, column)` will not line up.

        Returns:
            True if the field count is not a whole number of rows.
        """
        if self.column_count == 0:
            return len(self._ends) != 0
        return len(self._ends) % self.column_count != 0

    @always_inline
    def _index(self, row: Int, column: Int) raises -> Int:
        """Returns the flat field index for `row`, `column`, bounds-checked."""
        if column < 0 or column >= self.column_count:
            raise Error(
                "column ", column, " is outside 0..<", self.column_count
            )
        var index = row * self.column_count + column
        if row < 0 or index >= len(self._ends):
            raise Error("row ", row, " is outside 0..<", self.row_count())
        return index

    def field[
        origin: ImmOrigin, //
    ](ref[origin] self, row: Int, column: Int) raises -> StringSlice[origin]:
        """Returns a field exactly as it appears in the document.

        This borrows the document and copies nothing, so it is the cheap way to
        read. It is also the *raw* field: if the value was quoted, the quotes
        are still on it and any doubled quote inside is still doubled. Use
        `is_quoted` to find out, or `get` to have that undone.

        Parameters:
            origin: The origin of the borrow.

        Args:
            row: Zero-based row index.
            column: Zero-based column index.

        Raises:
            Error: If `row` or `column` is out of range.

        Returns:
            The bytes between the delimiters, borrowed.
        """
        var index = self._index(row, column)
        var start = self._starts[index]
        var bytes = self._text.as_bytes()
        return StringSlice(
            unsafe_from_utf8=Span[UInt8, origin](
                unsafe_ptr=bytes.unsafe_ptr()
                .unsafe_offset(start)
                .unsafe_origin_cast[origin](),
                length=self._ends[index] - start,
            )
        )

    def is_quoted(self, row: Int, column: Int) raises -> Bool:
        """Returns whether a field is wrapped in double quotes.

        Args:
            row: Zero-based row index.
            column: Zero-based column index.

        Raises:
            Error: If `row` or `column` is out of range.

        Returns:
            True if the raw field begins and ends with `"`.
        """
        var index = self._index(row, column)
        var start = self._starts[index]
        var end = self._ends[index]
        if end - start < 2:
            return False
        var ptr = self._text.unsafe_ptr()
        return (
            ptr[unsafe_offset=start] == QUOTE
            and ptr[unsafe_offset=end - 1] == QUOTE
        )

    def get(self, row: Int, column: Int) raises -> String:
        """Returns a field with its escaping undone.

        An unquoted field is returned as-is. A quoted one has its wrapping
        quotes removed and every doubled quote inside collapsed to one, which
        is what RFC 4180 says those mean.

        This allocates. Where the field is known to be unquoted, `field` gives
        the same answer without copying.

        Args:
            row: Zero-based row index.
            column: Zero-based column index.

        Raises:
            Error: If `row` or `column` is out of range.

        Returns:
            The field's value.
        """
        if not self.is_quoted(row, column):
            return String(self.field(row, column))

        var index = self._index(row, column)
        var start = self._starts[index] + 1
        var end = self._ends[index] - 1
        var ptr = self._text.unsafe_ptr()

        var out = String()
        var run_start = start
        var position = start
        while position < end:
            if ptr[unsafe_offset=position] == QUOTE:
                # A doubled quote: keep the run up to and including the first,
                # and resume after the second.
                out += StringSlice(
                    unsafe_from_utf8=self._text.as_bytes()[
                        run_start : position + 1
                    ]
                )
                position += 2
                run_start = position
            else:
                position += 1
        out += StringSlice(
            unsafe_from_utf8=self._text.as_bytes()[run_start:end]
        )
        return out^
