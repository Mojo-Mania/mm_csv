"""Reading CSV without building an index.

`CsvTable` writes one four-byte entry per field and hands back rows and
columns afterwards. For a consumer that looks at each field once -- sum a
column, count matching rows, feed a parser -- those writes are the largest
single cost in the parse, and the index they build is thrown away.

`CsvFields` is the same scan with the writes taken out. It walks the same
sixty-four-byte chunks and does the same bitmask arithmetic, but instead of
emitting the delimiter offsets to memory it keeps the chunk's delimiter mask
in the iterator and clears one bit per `__next__`. Nothing is allocated and
nothing is stored.

What you give up is random access. There is no `row_count`, no `get(row,
column)`, and no second pass: the fields arrive once, in document order, each
tagged with whether it closed a row.

The chunk arithmetic is written out again here rather than shared with
`CsvTable._scan_simd`. Factoring the two into one inlined helper was tried and
cost 11% of the parse -- see `docs/improvements.md`. What keeps the two honest
instead is `test_fields_match_the_table`, which walks every corpus both ways
and asserts the same fields in the same order.
"""

from std.bit import count_trailing_zeros
from .csv_table import CHUNK, COMMA, CR, LF, QUOTE, _movemask, _prefix_xor


@fieldwise_init
struct CsvField[origin: ImmOrigin](Copyable, Movable):
    """One field, exactly as it appears in the document.

    Parameters:
        origin: The origin of the document the value borrows from.
    """

    var value: StringSlice[Self.origin]
    """The bytes between the delimiters, borrowed.

    This is the *raw* field: a quoted value still has its quotes on it and any
    doubled quote inside is still doubled. `CsvTable.get` is what undoes that,
    and `unescaped` does the same thing here."""

    var ends_row: Bool
    """Whether this field was closed by a line break rather than a separator.

    The last field of a document that does not end in a line break also
    reports True: end of document closes the row."""

    def unescaped(self) -> String:
        """Returns the value with RFC 4180 escaping undone.

        An unquoted field comes back as-is. A quoted one loses its wrapping
        quotes and has every doubled quote inside collapsed to one. This
        allocates; `value` does not.

        Returns:
            The field's value.
        """
        var bytes = self.value.as_bytes()
        var length = len(bytes)
        if length < 2 or bytes[0] != QUOTE or bytes[length - 1] != QUOTE:
            return String(self.value)

        var out = String()
        var run_start = 1
        var position = 1
        while position < length - 1:
            if bytes[position] == QUOTE:
                # A doubled quote: keep the run up to and including the first,
                # and resume after the second.
                out += StringSlice(
                    unsafe_from_utf8=bytes[run_start : position + 1]
                )
                position += 2
                run_start = position
            else:
                position += 1
        out += StringSlice(unsafe_from_utf8=bytes[run_start : length - 1])
        return out^


struct CsvFields[origin: ImmOrigin, //, separator: UInt8 = COMMA](
    IterableOwned, Iterator, Movable
):
    """Fields of a CSV document, one at a time, with no index built.

    Parameters:
        origin: The origin of the document being read.
        separator: The byte between fields. `,` by default; `\\t` for TSV.
    """

    comptime Element = CsvField[Self.origin]
    comptime IteratorOwnedType: Iterator = Self

    var _bytes: Span[UInt8, Self.origin]

    var _bits: UInt64
    """Delimiters of the current chunk that have not been yielded yet."""

    var _crlf: UInt64
    """Which of them are a line feed with a carriage return in front."""

    var _row_ends: UInt64
    """Which of them are a line feed rather than a separator."""

    var _base: Int
    """Document offset the bits above are relative to."""

    var _next_chunk: Int
    """Where the next sixty-four bytes start."""

    var _start: Int
    """Document offset the next field begins at."""

    var _carried_quote: UInt64
    var _carried_cr: UInt64

    var _tail: Int
    """Scalar position in the last, short chunk; -1 until the chunks run out.
    """

    var _in_quotes: Bool
    var _done: Bool

    def __init__(out self, text: StringSlice[Self.origin]):
        """Starts a scan of `text`.

        Args:
            text: The document. Borrowed, not copied; every field yielded
                points into it.
        """
        self._bytes = text.as_bytes()
        self._bits = 0
        self._crlf = 0
        self._row_ends = 0
        self._base = 0
        self._next_chunk = 0
        self._start = 0
        self._carried_quote = 0
        self._carried_cr = 0
        self._tail = -1
        self._in_quotes = False
        self._done = False

    def __iter__(var self) -> Self.IteratorOwnedType:
        """Returns this iterator, so a `for` loop can take it by value.

        Returns:
            Self.
        """
        return self^

    @always_inline
    def _field(self, start: Int, end: Int, ends_row: Bool) -> Self.Element:
        """Builds the field spanning `start` to `end`, borrowed."""
        return CsvField(
            StringSlice(
                unsafe_from_utf8=Span[UInt8, Self.origin](
                    unsafe_ptr=self._bytes.unsafe_ptr().unsafe_offset(start),
                    length=end - start,
                )
            ),
            ends_row,
        )

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        """Returns the next field.

        Raises:
            StopIteration: When the document is used up.

        Returns:
            The field and whether it closed a row.
        """
        var length = len(self._bytes)
        var ptr = self._bytes.unsafe_ptr()

        while True:
            if self._bits != 0:
                # One delimiter per call, taken straight out of the mask. This
                # is the whole point of the type: no offset is ever stored.
                var lane = Int(count_trailing_zeros(self._bits))
                self._bits &= self._bits - 1
                var end = self._base + lane
                var start = self._start
                self._start = end + 1
                # The CR of a CRLF is not part of the field before it.
                var trim = Int((self._crlf >> UInt64(lane)) & 1)
                var ends_row = (self._row_ends >> UInt64(lane)) & 1 != 0
                return self._field(start, end - trim, ends_row)

            var offset = self._next_chunk
            if offset + CHUNK > length:
                break
            self._next_chunk = offset + CHUNK

            var b0 = ptr.unsafe_offset(offset).unsafe_load[width=16]()
            var b1 = ptr.unsafe_offset(offset + 16).unsafe_load[width=16]()
            var b2 = ptr.unsafe_offset(offset + 32).unsafe_load[width=16]()
            var b3 = ptr.unsafe_offset(offset + 48).unsafe_load[width=16]()

            var quote_v = SIMD[DType.uint8, 16](QUOTE)
            var sep_v = SIMD[DType.uint8, 16](Self.separator)
            var lf_v = SIMD[DType.uint8, 16](LF)
            var cr_v = SIMD[DType.uint8, 16](CR)

            var quotes = _movemask(
                b0.eq(quote_v), b1.eq(quote_v), b2.eq(quote_v), b3.eq(quote_v)
            )
            var separators = _movemask(
                b0.eq(sep_v), b1.eq(sep_v), b2.eq(sep_v), b3.eq(sep_v)
            )
            var line_feeds = _movemask(
                b0.eq(lf_v), b1.eq(lf_v), b2.eq(lf_v), b3.eq(lf_v)
            )
            var carriage_returns = _movemask(
                b0.eq(cr_v), b1.eq(cr_v), b2.eq(cr_v), b3.eq(cr_v)
            )

            if (
                quotes | separators | line_feeds | carriage_returns
            ) == 0 and self._carried_quote == 0:
                self._carried_cr = 0
                continue

            var inside = _prefix_xor(quotes) ^ self._carried_quote
            self._carried_quote = UInt64(Int64(inside) >> 63)
            var cr_shifted = (carriage_returns << 1) | self._carried_cr
            self._carried_cr = carriage_returns >> 63

            self._crlf = line_feeds & cr_shifted
            self._row_ends = line_feeds & ~inside
            self._bits = (separators | line_feeds) & ~inside
            self._base = offset

        # Fewer than sixty-four bytes left, so the rest is walked a byte at a
        # time, picking up the quote state the chunks left behind.
        if self._tail < 0:
            self._tail = self._next_chunk
            self._in_quotes = self._carried_quote != 0

        while self._tail < length:
            var position = self._tail
            self._tail = position + 1
            var byte = ptr[unsafe_offset=position]
            if byte == QUOTE:
                self._in_quotes = not self._in_quotes
            elif self._in_quotes:
                pass
            elif byte == Self.separator:
                var start = self._start
                self._start = position + 1
                return self._field(start, position, False)
            elif byte == LF:
                var end = position
                if position > 0 and ptr[unsafe_offset=position - 1] == CR:
                    end -= 1
                var start = self._start
                self._start = position + 1
                return self._field(start, end, True)

        # A document not ending in a line break leaves its last field open,
        # and the end of the text closes it. One that does end in a line break
        # has no trailing field, which is what `CsvTable` records too.
        if not self._done:
            self._done = True
            if length > 0 and ptr[unsafe_offset=length - 1] != LF:
                var start = self._start
                self._start = length + 1
                return self._field(start, length, True)
        raise StopIteration()
