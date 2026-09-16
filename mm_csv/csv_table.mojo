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
definition of what the parser does. `_scan_simd` loads sixty-four bytes at
once, compares them against quote, separator and newline in parallel, and only
visits the positions where something matched. Both produce the same index,
which is what `test/test_csv.mojo` checks on every corpus.

Escaping follows RFC 4180: a field may be wrapped in double quotes, and inside
such a field a literal double quote is written twice.
"""

from std.bit import count_trailing_zeros, pop_count
from std.math import iota
from std.memory import bitcast, pack_bits
from std.sys.intrinsics import llvm_intrinsic
from std.memory import unsafe_memcpy
from std.memory.alloc import Allocation, alloc, dealloc
from std.os import abort
from std.sys.info import CompilationTarget, simd_width_of

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


comptime _WIDE_COMPARE = CompilationTarget._has_feature["avx512bw"]()
"""Whether to compare all sixty-four bytes of a chunk in one vector.

With AVX-512BW a 64-lane comparison lands in a mask register and one `kmovq`
takes it out: four compares and four crossings a chunk. The portable
sixteen-lane path lowered to sixteen of each, reassembled with `vpinsrw`, and
this is 1.69x faster on the whole parse. See `docs/improvements.md`."""


comptime _COMPRESS_EMIT = CompilationTarget._has_feature["avx512vbmi2"]()
"""Whether to write a chunk's index entries with `vpcompressb` rather than
walking its delimiter bits.

The unrolled walk is a serial chain -- each `bits &= bits - 1` waits on the
last -- and on AVX-512 LLVM vectorises everything after it, which means
computing the links, spilling them to the stack, and gathering them back into
a `zmm`. A compress has no chain: every delimiter's lane comes out of one
instruction. 2.2x on the whole parse. See `docs/improvements.md`."""


comptime _LANES = iota[DType.uint8, 64]()
"""Every lane index of a chunk, for the compress to pick from."""


@always_inline
def _unpack_bits(bits: UInt64) -> SIMD[DType.bool, 64]:
    """The inverse of `pack_bits`: one lane per bit.

    `bitcast` counts a `bool` as eight bits and refuses; `pack_bits` is a raw
    `pop.bitcast`, and so is this, the other way round.
    """
    return SIMD[DType.bool, 64](
        mlir_value=__mlir_op.`pop.bitcast`[
            _type=SIMD[DType.bool, 64]._mlir_type
        ](bits._mlir_value)
    )


comptime _HALF_COMPARE = CompilationTarget.has_avx2()
"""Whether to compare a chunk thirty-two bytes at a time, where there is AVX2
but no AVX-512BW: two `vpmovmskb`s a mask instead of four. Checked after
`_WIDE_COMPARE`, which takes precedence."""


@always_inline
def _join(lo: SIMD[DType.bool, 32], hi: SIMD[DType.bool, 32]) -> UInt64:
    """Packs two thirty-two lane comparisons into one `UInt64`."""
    return UInt64(pack_bits[DType.uint32](lo)) | (
        UInt64(pack_bits[DType.uint32](hi)) << 32
    )


comptime _WEIGHTS = SIMD[DType.uint8, 16](
    1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128
)


@always_inline
def _movemask(
    m0: SIMD[DType.bool, 16],
    m1: SIMD[DType.bool, 16],
    m2: SIMD[DType.bool, 16],
    m3: SIMD[DType.bool, 16],
) -> UInt64:
    """Packs sixty-four lane flags into a `UInt64`, one bit each.

    Only the ARM and portable paths come through here; x86 compares wider
    vectors directly, see `_WIDE_COMPARE` and `_HALF_COMPARE`.

    `pack_bits` does this portably, and is what the fallback uses. On ARM it
    lowers to four independent sixteen-lane movemasks, each ending in a
    `umov` -- four crossings out of the vector register file, per mask, per
    chunk. Folding the four vectors together with `addp` first leaves **one**
    crossing instead, which is what simdjson's `neonmovemask_bulk` is for, and
    is worth 1.40x on the whole parse.

    It also leaves the result in a vector register, which is what makes the
    carry-less multiply in `_prefix_xor` worth having.
    """
    comptime if CompilationTarget.has_neon():
        comptime weights = SIMD[DType.uint8, 16](
            1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128
        )

        @always_inline
        def addp(
            a: SIMD[DType.uint8, 16], b: SIMD[DType.uint8, 16]
        ) -> SIMD[DType.uint8, 16]:
            return llvm_intrinsic[
                "llvm.aarch64.neon.addp", SIMD[DType.uint8, 16]
            ](a, b)

        var t0 = m0.cast[DType.uint8]() * weights
        var t1 = m1.cast[DType.uint8]() * weights
        var t2 = m2.cast[DType.uint8]() * weights
        var t3 = m3.cast[DType.uint8]() * weights
        var folded = addp(addp(t0, t1), addp(t2, t3))
        folded = addp(folded, folded)
        return bitcast[DType.uint64, 2](folded)[0]
    else:
        return (
            UInt64(pack_bits[DType.uint16](m0))
            | (UInt64(pack_bits[DType.uint16](m1)) << 16)
            | (UInt64(pack_bits[DType.uint16](m2)) << 32)
            | (UInt64(pack_bits[DType.uint16](m3)) << 48)
        )


@always_inline
def _prefix_xor(var bits: UInt64) -> UInt64:
    """Returns, for each bit, the XOR of every bit at or below it.

    Applied to the positions of the quote characters, this answers "is this
    byte inside a quoted region?" for all sixty-four bytes at once: the parity
    of the quotes before a position is exactly whether it is inside one.

    A carry-less multiply by all-ones does this in a single instruction --
    `pclmulqdq` on x86, `pmull64` on ARM -- which is how simdjson and simdcsv
    do it. Whether it is worth using turns out to depend entirely on what
    packed the mask. With `pack_bits` the mask lands in a general-purpose
    register, the intrinsic needs an `fmov` in and another out, and it loses
    to six `eor`s. With the `addp` fold in `_movemask` the mask is already in
    a vector register, there is no `fmov` in, and it wins by 13%. On x86
    `pclmulqdq` is worth 7% even though its operand comes from a `kmovq` and
    has to cross in. The shifts are the fallback where neither is available.
    See `docs/improvements.md`.

    `PMULL` sits behind AArch64's `aes` feature, and NEON being available does
    not imply it. `CompilationTarget.has_neon()` answers True for any Apple
    silicon target whether or not the feature is enabled, so asking it alone
    emitted an intrinsic the backend could not select: `LLVM ERROR: Cannot
    select: v16i8 = AArch64ISD::PMULL`, which aborts the compiler rather than
    failing the build cleanly. CI hit it on a macOS runner while this machine,
    where the feature is on, was fine. `--target-features=-aes` reproduces it.
    """
    comptime if (
        CompilationTarget.has_neon() and CompilationTarget._has_feature["aes"]()
    ):
        # `_movemask` leaves the mask in a vector register, so this takes it
        # straight from there: one crossing on the way out, no `fmov` in.
        var product = llvm_intrinsic[
            "llvm.aarch64.neon.pmull64", SIMD[DType.uint8, 16]
        ](bits, UInt64.MAX)
        return bitcast[DType.uint64, 2](product)[0]
    elif CompilationTarget._has_feature["pclmul"]():
        # `pclmulqdq` does it in one instruction on x86. It works on vector
        # registers too, so the mask pays one crossing in and one out.
        var product = llvm_intrinsic[
            "llvm.x86.pclmulqdq", SIMD[DType.uint64, 2]
        ](
            SIMD[DType.uint64, 2](bits, 0),
            SIMD[DType.uint64, 2](UInt64.MAX, 0),
            Int8(0),
        )
        return product[0]
    else:
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
        var quote_v = SIMD[DType.uint8, 16](QUOTE)
        var sep_v = SIMD[DType.uint8, 16](Self.separator)
        var lf_v = SIMD[DType.uint8, 16](LF)
        var cr_v = SIMD[DType.uint8, 16](CR)

        # All ones while the scan is inside a quoted region, all zeros outside.
        var carried_quote = UInt64(0)
        # Set when the previous chunk's last byte was a carriage return.
        var carried_cr = UInt64(0)
        var columns = -1
        var offset = 0
        var written = 0

        # Hoisted out of the loop. Every write below goes through this; left
        # as `self._slots`, each store could as far as the compiler knows
        # alias the field holding the pointer, so it would reload it every
        # time. Refreshed after a grow, which is the only thing that moves it.
        var slots = self._slots

        while offset + CHUNK <= length:
            var quotes: UInt64
            var separators: UInt64
            var line_feeds: UInt64
            var carriage_returns: UInt64
            comptime if _WIDE_COMPARE:
                var b = ptr.unsafe_offset(offset).unsafe_load[width=64]()
                quotes = pack_bits[DType.uint64](b.eq(QUOTE))
                separators = pack_bits[DType.uint64](b.eq(Self.separator))
                line_feeds = pack_bits[DType.uint64](b.eq(LF))
                carriage_returns = pack_bits[DType.uint64](b.eq(CR))
            elif _HALF_COMPARE:
                var lo = ptr.unsafe_offset(offset).unsafe_load[width=32]()
                var hi = ptr.unsafe_offset(offset + 32).unsafe_load[width=32]()
                quotes = _join(lo.eq(QUOTE), hi.eq(QUOTE))
                separators = _join(lo.eq(Self.separator), hi.eq(Self.separator))
                line_feeds = _join(lo.eq(LF), hi.eq(LF))
                carriage_returns = _join(lo.eq(CR), hi.eq(CR))
            else:
                var b0 = ptr.unsafe_offset(offset).unsafe_load[width=16]()
                var b1 = ptr.unsafe_offset(offset + 16).unsafe_load[width=16]()
                var b2 = ptr.unsafe_offset(offset + 32).unsafe_load[width=16]()
                var b3 = ptr.unsafe_offset(offset + 48).unsafe_load[width=16]()

                quotes = _movemask(
                    b0.eq(quote_v),
                    b1.eq(quote_v),
                    b2.eq(quote_v),
                    b3.eq(quote_v),
                )
                separators = _movemask(
                    b0.eq(sep_v), b1.eq(sep_v), b2.eq(sep_v), b3.eq(sep_v)
                )
                line_feeds = _movemask(
                    b0.eq(lf_v), b1.eq(lf_v), b2.eq(lf_v), b3.eq(lf_v)
                )
                carriage_returns = _movemask(
                    b0.eq(cr_v), b1.eq(cr_v), b2.eq(cr_v), b3.eq(cr_v)
                )

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
                    slots = self._slots

                var found = Int(pop_count(delimiters))
                comptime if _COMPRESS_EMIT:
                    # One `vpcompressb` packs the lane of every delimiter to
                    # the front, in order, with that delimiter's CRLF flag
                    # riding in bit 7 -- lanes stop at 63, so it is free.
                    # Then sixteen at a time: widen, add the chunk offset,
                    # move the flag to bit 31, store. Only the first store is
                    # unconditional; eleven-byte fields put five or six
                    # delimiters in a chunk, and storing all four groups
                    # regardless measured 1.7x slower than guarding them.
                    var marked = _LANES | _unpack_bits(crlf).select(
                        SIMD[DType.uint8, 64](128), SIMD[DType.uint8, 64](0)
                    )
                    var packed = llvm_intrinsic[
                        "llvm.x86.avx512.mask.compress", SIMD[DType.uint8, 64]
                    ](
                        marked,
                        SIMD[DType.uint8, 64](0),
                        _unpack_bits(delimiters),
                    )
                    var base = SIMD[DType.uint32, 16](UInt32(offset))
                    var w0 = packed.slice[16]().cast[DType.uint32]()
                    slots.unsafe_store[width=16](
                        written, ((w0 & 127) + base) | ((w0 >> 7) << 31)
                    )
                    comptime for g in range(1, 4):
                        if found > g * 16:
                            var w = packed.slice[16, offset=g * 16]().cast[
                                DType.uint32
                            ]()
                            slots.unsafe_store[width=16](
                                written + g * 16,
                                ((w & 127) + base) | ((w >> 7) << 31),
                            )
                else:
                    # Unrolled. The profile said this loop was nearly half the
                    # scan, most of it a branch per delimiter; groups of eight
                    # replace up to sixty-four of those branches with three.
                    # Written out rather than put in a nested closure: a closure
                    # capturing `bits` forced it to memory and made the whole scan
                    # three times slower.
                    #
                    # The flag is arithmetic, not a conditional. Truncating to
                    # thirty-two bits and shifting left by thirty-one keeps bit
                    # zero and discards everything else, so no `& 1` is needed,
                    # and ARM folds the shift into the `orr` below. Written as
                    # `_CRLF_BIT if ... != 0 else 0` it was a test and a select
                    # instead, and cost 86 microseconds over this document.
                    var bits = delimiters
                    comptime for j in range(0, 8):
                        var lane0 = Int(count_trailing_zeros(bits))
                        var flag0 = (crlf >> UInt64(lane0)).cast[
                            DType.uint32
                        ]() << 31
                        slots[unsafe_offset=written + j] = (
                            UInt32(offset + lane0) | flag0
                        )
                        bits &= bits - 1
                    if found > 8:
                        comptime for j in range(8, 16):
                            var lane8 = Int(count_trailing_zeros(bits))
                            var flag8 = (crlf >> UInt64(lane8)).cast[
                                DType.uint32
                            ]() << 31
                            slots[unsafe_offset=written + j] = (
                                UInt32(offset + lane8) | flag8
                            )
                            bits &= bits - 1
                    if found > 16:
                        comptime for j in range(16, 32):
                            var lane16 = Int(count_trailing_zeros(bits))
                            var flag16 = (crlf >> UInt64(lane16)).cast[
                                DType.uint32
                            ]() << 31
                            slots[unsafe_offset=written + j] = (
                                UInt32(offset + lane16) | flag16
                            )
                            bits &= bits - 1
                    if found > 32:
                        comptime for j in range(32, 64):
                            var lane32 = Int(count_trailing_zeros(bits))
                            var flag32 = (crlf >> UInt64(lane32)).cast[
                                DType.uint32
                            ]() << 31
                            slots[unsafe_offset=written + j] = (
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

    @always_inline
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
