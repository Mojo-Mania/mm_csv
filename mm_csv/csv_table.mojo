"""Reading CSV: tokenise once, then index.

`CsvTable` takes the whole document as a `String` and makes one pass over it,
recording where every field ends. Nothing is copied and nothing is allocated
per field. Reading a value afterwards is index arithmetic, and for the common
case -- a field with no quotes in it -- handing back a `StringSlice` that
borrows the original text.

The index is **one** array of delimiter offsets, not two of starts and ends. A
field's start is the previous delimiter plus one, and the CRLF adjustment is a
byte compare when the field is read. Keeping both ends cost sixteen bytes per
field and, measured, as much time again as the scan that filled them.

The scan can be done two ways. `_scan_scalar` walks a byte at a time and is the
definition of what the parser does. `_scan_simd` loads `simd_width_of[uint8]()`
bytes at once, compares them against quote, separator and newline in parallel,
and only visits the positions where something matched. Both produce the same
index, which is what `test/test_csv.mojo` checks on every corpus.

Escaping follows RFC 4180: a field may be wrapped in double quotes, and inside
such a field a literal double quote is written twice.
"""

from std.math import iota
from std.memory import stack_allocation
from std.os import abort
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

    var _positions: List[UInt32]
    """The offset of the delimiter that closed each field, in document order.

    One entry per field, four bytes each, with the **top bit** set when that
    delimiter was an LF preceded by a CR. Carrying the flag here rather than
    re-reading two bytes at access time is what keeps reading as cheap as it
    was when starts and ends were separate arrays; it is also what caps a
    document at 2 GiB rather than 4."""

    comptime _CRLF_BIT = UInt32(1) << 31
    comptime _OFFSET_MASK = (UInt32(1) << 31) - 1

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
        self._positions = []
        self.column_count = 0

        var length = self._text.byte_length()
        if length == 0:
            return
        # Written out rather than as `Int(UInt32.MAX)`, which wraps to -1 and
        # would make this fire on every document.
        comptime MAX_LENGTH = (1 << 31) - 1
        if length > MAX_LENGTH:
            abort(
                "CsvTable indexes fields with 31 bits and cannot take a"
                " document of 2 GiB or more"
            )

        # One allocation for the index, sized from the document. Eight bytes a
        # field is a guess; being wrong costs a regrowth, not correctness.
        self._positions.reserve(length // 8 + 16)

        var columns: Int
        if simd:
            columns = self._scan_simd(length)
        else:
            columns = self._scan_scalar(length, 0, False, -1)

        # A document not ending in a line break leaves its last field open, and
        # the end of the text closes it.
        if self._text.unsafe_ptr()[unsafe_offset=length - 1] != LF:
            self._positions.append(UInt32(length))

        # A document with no line break at all is one row, and its column count
        # is however many fields it has. Leaving this at -1 is what made the
        # ported implementation's `row_count` divide by a negative number.
        self.column_count = columns if columns > 0 else len(self._positions)

    def _scan_scalar(
        mut self,
        length: Int,
        var offset: Int,
        var in_quotes: Bool,
        var columns: Int,
    ) -> Int:
        """Walks bytes from `offset`, recording delimiters.

        Returns:
            The column count, or -1 if no line break was met.
        """
        var ptr = self._text.unsafe_ptr()
        while offset < length:
            var byte = ptr[unsafe_offset=offset]
            if byte == QUOTE:
                in_quotes = not in_quotes
            elif in_quotes:
                pass
            elif byte == Self.separator:
                self._positions.append(UInt32(offset))
            elif byte == LF:
                var flag = Self._CRLF_BIT if (
                    offset > 0 and ptr[unsafe_offset=offset - 1] == CR
                ) else UInt32(0)
                self._positions.append(UInt32(offset) | flag)
                if columns == -1:
                    columns = len(self._positions)
            offset += 1
        return columns

    def _scan_simd(mut self, length: Int) -> Int:
        """Walks `WIDTH` bytes at a time, visiting only positions that matched.

        Returns:
            The column count, or -1 if no line break was met.
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
                    var flag = UInt32(0)
                    if line_feeds[lane]:
                        var after_cr = previous_chunk_ended_on_cr
                        if lane > 0:
                            after_cr = Bool(carriage_returns[lane - 1])
                        if after_cr:
                            flag = Self._CRLF_BIT
                        if columns == -1:
                            columns = len(self._positions) + 1
                    self._positions.append(UInt32(offset + lane) | flag)

            # Tracked for every chunk, matches or not: a CRLF straddling a
            # chunk boundary is only visible from here.
            previous_chunk_ended_on_cr = Bool(carriage_returns[WIDTH - 1])
            offset += WIDTH

        return self._scan_scalar(length, offset, in_quotes, columns)

    def __len__(self) -> Int:
        """Returns the number of fields the document holds.

        Returns:
            Every field in every row, including empty ones.
        """
        return len(self._positions)

    def row_count(self) -> Int:
        """Returns the number of rows.

        Returns:
            Fields divided by columns, or 0 for an empty document.
        """
        if self.column_count == 0:
            return 0
        return len(self._positions) // self.column_count

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
            return len(self._positions) != 0
        return len(self._positions) % self.column_count != 0

    @always_inline
    def _index(self, row: Int, column: Int) raises -> Int:
        """Returns the flat field index for `row`, `column`, bounds-checked."""
        if column < 0 or column >= self.column_count:
            raise Error(
                "column ", column, " is outside 0..<", self.column_count
            )
        var index = row * self.column_count + column
        if row < 0 or index >= len(self._positions):
            raise Error("row ", row, " is outside 0..<", self.row_count())
        return index

    @always_inline
    def _bounds(self, index: Int) -> Tuple[Int, Int]:
        """Returns the half-open byte range of the field at `index`.

        The start is the previous delimiter's offset plus one. The end is this
        field's own delimiter, less its top bit, which the scan set when that
        delimiter was an LF with a CR in front of it -- the CRLF that ends a
        row is not part of the field.
        """
        var start = (
            0 if index
            == 0 else Int(self._positions[index - 1] & Self._OFFSET_MASK) + 1
        )
        var raw = self._positions[index]
        var end = Int(raw & Self._OFFSET_MASK) - Int(raw >> 31)
        return (start, end)

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
        var start: Int
        var end: Int
        start, end = self._bounds(index)
        var bytes = self._text.as_bytes()
        return StringSlice(
            unsafe_from_utf8=Span[UInt8, origin](
                unsafe_ptr=bytes.unsafe_ptr()
                .unsafe_offset(start)
                .unsafe_origin_cast[origin](),
                length=end - start,
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
        var start: Int
        var end: Int
        start, end = self._bounds(index)
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
        var outer_start: Int
        var outer_end: Int
        outer_start, outer_end = self._bounds(index)
        var start = outer_start + 1
        var end = outer_end - 1
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
