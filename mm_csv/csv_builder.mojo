"""Writing CSV: push values, get a document.

`CsvBuilder` appends into one growing byte buffer and inserts the separators
and line breaks itself, from the column count it was given. Values are escaped
per RFC 4180 when they need it -- wrapped in double quotes, with any quote
inside doubled.

Deciding whether a value needs escaping means looking at every byte of it, so
`push` takes an `escape` argument. Leaving it on is the safe default and is
what keeps the output valid; turning it off for values known to be plain is
worth roughly an order of magnitude, and `benchmarks/bench_csv.mojo` measures
exactly how much.
"""

from std.memory import unsafe_memcpy, unsafe_memmove
from std.os import abort
from std.memory.alloc import Allocation, alloc, dealloc
from std.sys.info import simd_width_of

comptime QUOTE = UInt8(ord('"'))
comptime LF = UInt8(ord("\n"))
comptime CR = UInt8(ord("\r"))
comptime COMMA = UInt8(ord(","))

comptime _WIDTH = simd_width_of[DType.uint8]()
comptime _MIN_CAPACITY = 1024


struct CsvBuilder[separator: UInt8 = COMMA](Movable, Sized):
    """Builds a CSV document one value at a time.

    Parameters:
        separator: The byte to put between fields. `,` by default.
    """

    var _buffer: Pointer[UInt8, MutUntrackedOrigin]
    var _capacity: Int
    var _length: Int
    var _column_count: Int
    var _field_count: Int

    def __init__(out self, column_count: Int):
        """Starts a document with `column_count` unnamed columns.

        Args:
            column_count: How many fields make a row. Must be positive.
        """
        if column_count <= 0:
            abort("CsvBuilder needs a positive column count")
        self._capacity = _MIN_CAPACITY
        self._buffer = alloc[UInt8]({count = _MIN_CAPACITY}).unsafe_leak()
        self._length = 0
        self._column_count = column_count
        self._field_count = 0

    def __init__(out self, var names: List[String]):
        """Starts a document whose first row is `names`.

        Args:
            names: The column headers. Their count sets the column count.
        """
        self = Self(len(names))
        for i in range(len(names)):
            self.push(names[i])

    def __deinit__(deinit self):
        """Frees the buffer."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self._buffer, layout={count = self._capacity}
            )
        )

    def __len__(self) -> Int:
        """Returns the bytes written so far.

        Returns:
            The document's current length, excluding the terminator `finish`
            will add.
        """
        return self._length

    @always_inline
    def _reserve(mut self, extra: Int):
        """Makes room for `extra` more bytes."""
        if self._length + extra <= self._capacity:
            return
        var capacity = self._capacity
        while capacity < self._length + extra:
            capacity *= 2
        var buffer = alloc[UInt8]({count = capacity}).unsafe_leak()
        unsafe_memcpy(dest=buffer, src=self._buffer, count=self._length)
        dealloc(
            Allocation(
                unsafe_owned_ptr=self._buffer, layout={count = self._capacity}
            )
        )
        self._buffer = buffer
        self._capacity = capacity

    @always_inline
    def _needs_escaping(self, value: StringSlice) -> Bool:
        """Returns whether `value` holds a byte that has to be quoted."""
        var ptr = value.unsafe_ptr()
        var length = value.byte_length()
        var offset = 0
        var quote_vec = SIMD[DType.uint8, _WIDTH](QUOTE)
        var sep_vec = SIMD[DType.uint8, _WIDTH](Self.separator)
        var lf_vec = SIMD[DType.uint8, _WIDTH](LF)
        var cr_vec = SIMD[DType.uint8, _WIDTH](CR)
        while offset + _WIDTH <= length:
            var chunk = ptr.unsafe_offset(offset).unsafe_load[width=_WIDTH]()
            var hit = (
                chunk.eq(quote_vec)
                | chunk.eq(sep_vec)
                | chunk.eq(lf_vec)
                | chunk.eq(cr_vec)
            )
            if hit.reduce_or():
                return True
            offset += _WIDTH
        while offset < length:
            var byte = ptr[unsafe_offset=offset]
            if (
                byte == QUOTE
                or byte == Self.separator
                or byte == LF
                or byte == CR
            ):
                return True
            offset += 1
        return False

    @always_inline
    def _write_delimiter(mut self):
        """Writes the separator or line break this field must follow."""
        if self._field_count == 0:
            return
        self._reserve(2)
        if self._field_count % self._column_count == 0:
            self._buffer[unsafe_offset=self._length] = CR
            self._buffer[unsafe_offset=self._length + 1] = LF
            self._length += 2
        else:
            self._buffer[unsafe_offset=self._length] = Self.separator
            self._length += 1

    def push(mut self, value: StringSlice, *, escape: Bool = True):
        """Appends a string field.

        Args:
            value: The field's value.
            escape: Whether to check the value for bytes that need quoting.
                Leave it on unless the value is known to hold none: turning it
                off writes the value through unchecked, and an unchecked value
                holding a separator or a quote produces a broken document.
        """
        if escape and self._needs_escaping(value):
            return self._push_quoted(value)
        self._write_delimiter()
        var length = value.byte_length()
        self._reserve(length)
        unsafe_memcpy(
            dest=self._buffer.unsafe_offset(self._length),
            src=value.unsafe_ptr(),
            count=length,
        )
        self._length += length
        self._field_count += 1

    def _push_quoted(mut self, value: StringSlice):
        """Appends `value` wrapped in quotes, with inner quotes doubled."""
        self._write_delimiter()
        var length = value.byte_length()
        var ptr = value.unsafe_ptr()

        var quotes = 0
        for i in range(length):
            if ptr[unsafe_offset=i] == QUOTE:
                quotes += 1

        self._reserve(length + quotes + 2)
        self._buffer[unsafe_offset=self._length] = QUOTE
        self._length += 1

        if quotes == 0:
            unsafe_memcpy(
                dest=self._buffer.unsafe_offset(self._length),
                src=ptr,
                count=length,
            )
            self._length += length
        else:
            # Copy the runs between quotes, doubling each quote as it is
            # reached, rather than a byte at a time.
            var run_start = 0
            for i in range(length):
                if ptr[unsafe_offset=i] != QUOTE:
                    continue
                var run = i + 1 - run_start
                unsafe_memcpy(
                    dest=self._buffer.unsafe_offset(self._length),
                    src=ptr.unsafe_offset(run_start),
                    count=run,
                )
                self._length += run
                self._buffer[unsafe_offset=self._length] = QUOTE
                self._length += 1
                run_start = i + 1
            var tail = length - run_start
            unsafe_memcpy(
                dest=self._buffer.unsafe_offset(self._length),
                src=ptr.unsafe_offset(run_start),
                count=tail,
            )
            self._length += tail

        self._buffer[unsafe_offset=self._length] = QUOTE
        self._length += 1
        self._field_count += 1

    @always_inline
    def push_value[T: Writable](mut self, value: T, *, escape: Bool = False):
        """Appends anything `Writable` -- a number, or a type of your own.

        Numbers never need escaping, so `escape` is off by default here, the
        other way round from the string `push`.

        The value renders straight into the document, with no `String` in
        between. When `escape` is on and the rendered text turns out to need
        quoting, it is quoted where it lies.

        Parameters:
            T: The value's type.

        Args:
            value: The value to write.
            escape: Whether to check the rendered text for bytes needing
                quotes.
        """
        self._write_delimiter()
        var start = self._length
        var writer = _FieldWriter[Self.separator](
            Pointer(to=self).unsafe_origin_cast[MutUntrackedOrigin]()
        )
        value.write_to(writer)
        if escape and self._needs_escaping(
            StringSlice(
                unsafe_from_utf8=Span[UInt8, MutUntrackedOrigin](
                    unsafe_ptr=self._buffer.unsafe_offset(start),
                    length=self._length - start,
                )
            )
        ):
            self._quote_in_place(start)
        self._field_count += 1

    @always_inline
    def _append(mut self, bytes: StringSpan):
        """Copies `bytes` onto the end of the buffer, unchecked."""
        var length = bytes.byte_length()
        self._reserve(length)
        unsafe_memcpy(
            dest=self._buffer.unsafe_offset(self._length),
            src=bytes.unsafe_ptr(),
            count=length,
        )
        self._length += length

    def _quote_in_place(mut self, start: Int):
        """Quotes the bytes from `start` to the end, doubling inner quotes.

        Walks backwards, so every byte moves right before anything is written
        over it.
        """
        var length = self._length - start
        var quotes = 0
        for i in range(start, self._length):
            if self._buffer[unsafe_offset=i] == QUOTE:
                quotes += 1
        self._reserve(quotes + 2)
        var ptr = self._buffer
        if quotes == 0:
            unsafe_memmove(
                dest=ptr.unsafe_offset(start + 1),
                src=ptr.unsafe_offset(start),
                count=length,
            )
        else:
            var dest = start + length + quotes
            var i = start + length
            while i > start:
                i -= 1
                var byte = ptr[unsafe_offset=i]
                ptr[unsafe_offset=dest] = byte
                dest -= 1
                if byte == QUOTE:
                    ptr[unsafe_offset=dest] = QUOTE
                    dest -= 1
        ptr[unsafe_offset=start] = QUOTE
        ptr[unsafe_offset=start + length + quotes + 1] = QUOTE
        self._length += quotes + 2

    def push_empty(mut self):
        """Appends an empty field."""
        self.push("", escape=False)

    def fill_up_row(mut self):
        """Appends empty fields until the current row is complete."""
        var missing = self._column_count - (
            self._field_count % self._column_count
        )
        if missing == self._column_count:
            return
        for _ in range(missing):
            self.push_empty()

    def finish(deinit self) -> String:
        """Completes the last row and returns the document.

        Consumes the builder.

        Returns:
            The whole document, ending in a CRLF as RFC 4180 requires.
        """
        self.fill_up_row()
        # The ported implementation reserved two bytes per push but wrote three
        # here, so a document whose last value exactly filled the buffer at a
        # row boundary overran it.
        self._reserve(2)
        self._buffer[unsafe_offset=self._length] = CR
        self._buffer[unsafe_offset=self._length + 1] = LF
        self._length += 2
        var text = String(
            StringSlice(
                unsafe_from_utf8=Span[UInt8, MutUntrackedOrigin](
                    unsafe_ptr=self._buffer, length=self._length
                )
            )
        )
        return text^


struct _FieldWriter[separator: UInt8](Writer):
    """Renders a `Writable` value straight into a builder's buffer.

    A separate type so that `CsvBuilder` itself is not a `Writer`: writing to
    it directly would add bytes without counting a field.
    """

    var _builder: Pointer[CsvBuilder[Self.separator], MutUntrackedOrigin]

    def __init__(
        out self,
        builder: Pointer[CsvBuilder[Self.separator], MutUntrackedOrigin],
    ):
        """Writes into `builder`, which must outlive this writer."""
        self._builder = builder

    @always_inline
    def write_string(mut self, string: StringSpan):
        """Appends `string` to the builder's buffer."""
        self._builder[]._append(string)
