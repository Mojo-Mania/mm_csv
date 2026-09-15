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

from std.bit import count_trailing_zeros, pop_count
from std.math import iota
from std.memory import pack_bits
from std.memory import unsafe_memcpy
from std.memory.alloc import Allocation, alloc, dealloc
from std.os import abort
from std.sys.info import simd_width_of

comptime QUOTE = UInt8(ord('"'))
comptime LF = UInt8(ord("\n"))
comptime CR = UInt8(ord("\r"))
comptime COMMA = UInt8(ord(","))

comptime _SLACK = 128
"""Spare entries the index keeps past its count, so the unrolled writes can
overrun a chunk's worth without a check per delimiter."""

comptime CHUNK = 64
"""Bytes the SIMD scan looks at per step.

Sixty-four is not an arbitrary number: it is the width of the integer that
carries one flag per byte, which is what lets the whole quote analysis happen
in ordinary register arithmetic. `pack_bits` turns a 64-lane comparison into
that integer directly."""


@always_inline
def _prefix_xor(var bits: UInt64) -> UInt64:
    """Returns, for each bit, the XOR of every bit at or below it.

    Applied to the positions of the quote characters, this answers "is this
    byte inside a quoted region?" for all sixty-four bytes at once: the parity
    of the quotes before a position is exactly whether it is inside one.

    A carry-less multiply by all-ones does this in a single instruction --
    `pclmulqdq` on x86, `pmull64` on ARM -- which is how simdjson and simdcsv
    do it. Mojo reaches it through `llvm_intrinsic`, it agrees with this
    function on every input tried, and on this machine it is **slower**. The
    disassembly says why: these six steps compile to six `eor` instructions
    with a free shifted operand, all in general-purpose registers, while
    `pmull64` needs an `fmov` into the vector file and another back out --
    `pack_bits` leaves the mask in a general-purpose register. Two
    register-file crossings cost more than six ALU ops.

    An isolated microbenchmark said the opposite, and was wrong: what an
    operation costs depends on where its operand already lives, which is a
    property of the surrounding code. See `docs/improvements.md`.
    """
    bits ^= bits << 1
    bits ^= bits << 2
    bits ^= bits << 4
    bits ^= bits << 8
    bits ^= bits << 16
    bits ^= bits << 32
    return bits


struct CsvTable[separator: UInt8 = COMMA](Movable, Sized):
    """A parsed CSV document.

    Parameters:
        separator: The byte between fields. `,` by default; `\\t` for TSV.
    """

    var _text: String
    """The document, owned. Every field is a slice of this."""

    var _slots: Pointer[UInt32, MutUntrackedOrigin]
    var _count: Int
    var _capacity: Int
    """The offset of the delimiter that closed each field, in document order.

    One entry per field, four bytes each, with the **top bit** set when that
    delimiter was an LF preceded by a CR. Carrying the flag here rather than
    re-reading two bytes at access time is what keeps reading as cheap as it
    was when starts and ends were separate arrays; it is also what caps a
    document at 2 GiB rather than 4.

    Owned outright rather than held in a `List`, because the scan writes into
    it through a raw pointer in unrolled groups of eight -- deliberately past
    the count, into slack it has to guarantee itself."""

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
        self._capacity = _SLACK
        self._count = 0
        self._slots = alloc[UInt32]({count = _SLACK}).unsafe_leak()
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

        # One allocation for the index, sized from the document. Eight bytes
        # a field is only a guess -- two-byte fields need four times that --
        # so the scan checks before every chunk and grows if it has to.
        self._reserve(length // 8 + _SLACK)

        var columns: Int
        if simd:
            columns = self._scan_simd(length)
        else:
            columns = self._scan_scalar(length, 0, False, -1)

        # A document not ending in a line break leaves its last field open, and
        # the end of the text closes it.
        if self._text.unsafe_ptr()[unsafe_offset=length - 1] != LF:
            self._push(UInt32(length))

        # A document with no line break at all is one row, and its column count
        # is however many fields it has. Leaving this at -1 is what made the
        # ported implementation's `row_count` divide by a negative number.
        self.column_count = columns if columns > 0 else self._count

    def __deinit__(deinit self):
        """Frees the index."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self._slots, layout={count = self._capacity}
            )
        )

    def _reserve(mut self, needed: Int):
        """Makes room for at least `needed` entries, keeping what is there."""
        if needed <= self._capacity:
            return
        var capacity = self._capacity * 2
        if capacity < needed:
            capacity = needed
        var slots = alloc[UInt32]({count = capacity}).unsafe_leak()
        if self._count != 0:
            unsafe_memcpy(dest=slots, src=self._slots, count=self._count)
        dealloc(
            Allocation(
                unsafe_owned_ptr=self._slots, layout={count = self._capacity}
            )
        )
        self._slots = slots
        self._capacity = capacity

    @always_inline
    def _push(mut self, value: UInt32):
        """Appends one entry, growing if it has to."""
        if self._count == self._capacity:
            self._reserve(self._capacity * 2 + _SLACK)
        self._slots[unsafe_offset=self._count] = value
        self._count += 1

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
                self._push(UInt32(offset))
            elif byte == LF:
                var flag = Self._CRLF_BIT if (
                    offset > 0 and ptr[unsafe_offset=offset - 1] == CR
                ) else UInt32(0)
                self._push(UInt32(offset) | flag)
                if columns == -1:
                    columns = self._count
            offset += 1
        return columns

    def _scan_simd(mut self, length: Int) -> Int:
        """Walks `CHUNK` bytes at a time through bitmask arithmetic.

        Each step turns sixty-four bytes into four `UInt64`s -- one bit per
        byte, for quote, separator, line feed and carriage return. From those,
        three pieces of ordinary integer arithmetic do the whole job:

        - `_prefix_xor` of the quote bits gives a mask of every byte inside a
          quoted region, so `& ~quotes` deletes the delimiters that are data
          rather than structure. No branch per quote, no state machine.
        - `(cr << 1)` lines the carriage returns up with the line feeds that
          follow them, so `lf & cr_shifted` is exactly the set of CRLF row
          ends, which is the bit this index stores alongside each offset.
        - The delimiters left over are walked with count-trailing-zeros,
          clearing the lowest set bit each time, so the loop runs once per
          delimiter rather than once per byte.

        Returns:
            The column count, or -1 if no line break was met.
        """
        var ptr = self._text.unsafe_ptr()
        var quote_v = SIMD[DType.uint8, CHUNK](QUOTE)
        var sep_v = SIMD[DType.uint8, CHUNK](Self.separator)
        var lf_v = SIMD[DType.uint8, CHUNK](LF)
        var cr_v = SIMD[DType.uint8, CHUNK](CR)

        # All ones while the scan is inside a quoted region, all zeros outside.
        var carried_quote = UInt64(0)
        # Set when the previous chunk's last byte was a carriage return.
        var carried_cr = UInt64(0)
        var columns = -1
        var offset = 0
        var written = 0

        while offset + CHUNK <= length:
            var block = ptr.unsafe_offset(offset).unsafe_load[width=CHUNK]()

            var quotes = pack_bits[DType.uint64](block.eq(quote_v))
            var separators = pack_bits[DType.uint64](block.eq(sep_v))
            var line_feeds = pack_bits[DType.uint64](block.eq(lf_v))
            var carriage_returns = pack_bits[DType.uint64](block.eq(cr_v))

            if (
                quotes | separators | line_feeds | carriage_returns
            ) == 0 and carried_quote == 0:
                # Nothing structural in these sixty-four bytes and no quote
                # state to carry, so there is nothing to do with them.
                carried_cr = 0
                offset += CHUNK
                continue

            var inside = _prefix_xor(quotes) ^ carried_quote
            # Sign-extending bit 63 carries the state into the next chunk.
            carried_quote = UInt64(Int64(inside) >> 63)

            var cr_shifted = (carriage_returns << 1) | carried_cr
            carried_cr = carriage_returns >> 63

            var crlf = line_feeds & cr_shifted
            var delimiters = (separators | line_feeds) & ~inside

            if delimiters != 0:
                # The first unquoted line break closes the first row, and the
                # delimiters up to and including it are the columns.
                if columns == -1:
                    var row_end = line_feeds & ~inside
                    if row_end != 0:
                        var lane = Int(count_trailing_zeros(row_end))
                        var upto = (
                            UInt64.MAX if lane
                            == 63 else (UInt64(1) << UInt64(lane + 1)) - 1
                        )
                        columns = written + Int(pop_count(delimiters & upto))

                # Up to sixty-four delimiters can come out of one chunk,
                # and the writes below run past the count on purpose, so the
                # slack has to be there before any of them happen. One check
                # per chunk, not one per delimiter.
                if written + _SLACK > self._capacity:
                    self._count = written
                    self._reserve(self._capacity * 2 + _SLACK)

                # Unrolled. The profile said this loop was nearly half the
                # scan, most of it a branch per delimiter; groups of eight
                # replace up to sixty-four of those branches with three.
                # Written out rather than put in a nested closure: a closure
                # capturing `bits` forced it to memory and made the whole scan
                # three times slower.
                var found = Int(pop_count(delimiters))
                var bits = delimiters
                comptime for j in range(0, 8):
                    var lane0 = Int(count_trailing_zeros(bits))
                    var flag0 = Self._CRLF_BIT if (
                        crlf >> UInt64(lane0)
                    ) & 1 != 0 else UInt32(0)
                    self._slots[unsafe_offset=written + j] = (
                        UInt32(offset + lane0) | flag0
                    )
                    bits &= bits - 1
                if found > 8:
                    comptime for j in range(8, 16):
                        var lane8 = Int(count_trailing_zeros(bits))
                        var flag8 = Self._CRLF_BIT if (
                            crlf >> UInt64(lane8)
                        ) & 1 != 0 else UInt32(0)
                        self._slots[unsafe_offset=written + j] = (
                            UInt32(offset + lane8) | flag8
                        )
                        bits &= bits - 1
                if found > 16:
                    comptime for j in range(16, 32):
                        var lane16 = Int(count_trailing_zeros(bits))
                        var flag16 = Self._CRLF_BIT if (
                            crlf >> UInt64(lane16)
                        ) & 1 != 0 else UInt32(0)
                        self._slots[unsafe_offset=written + j] = (
                            UInt32(offset + lane16) | flag16
                        )
                        bits &= bits - 1
                if found > 32:
                    comptime for j in range(32, 64):
                        var lane32 = Int(count_trailing_zeros(bits))
                        var flag32 = Self._CRLF_BIT if (
                            crlf >> UInt64(lane32)
                        ) & 1 != 0 else UInt32(0)
                        self._slots[unsafe_offset=written + j] = (
                            UInt32(offset + lane32) | flag32
                        )
                        bits &= bits - 1
                written += found

            offset += CHUNK

        # The unrolled writes went through the pointer, so the count has to
        # be brought back into the struct before anything reads it.
        self._count = written
        return self._scan_scalar(length, offset, carried_quote != 0, columns)

    def __len__(self) -> Int:
        """Returns the number of fields the document holds.

        Returns:
            Every field in every row, including empty ones.
        """
        return self._count

    def row_count(self) -> Int:
        """Returns the number of rows.

        Returns:
            Fields divided by columns, or 0 for an empty document.
        """
        if self.column_count == 0:
            return 0
        return self._count // self.column_count

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
            return self._count != 0
        return self._count % self.column_count != 0

    @always_inline
    def _index(self, row: Int, column: Int) raises -> Int:
        """Returns the flat field index for `row`, `column`, bounds-checked."""
        if column < 0 or column >= self.column_count:
            raise Error(
                "column ", column, " is outside 0..<", self.column_count
            )
        var index = row * self.column_count + column
        if row < 0 or index >= self._count:
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
            == 0 else Int(
                self._slots[unsafe_offset=index - 1] & Self._OFFSET_MASK
            )
            + 1
        )
        var raw = self._slots[unsafe_offset=index]
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
