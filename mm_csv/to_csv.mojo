"""Writing a list of structs as CSV, one row per struct.

The columns come from the struct's fields, found by compile-time reflection:
the header is the field names, in declaration order, and each row is the
field values. Everything is decided per field type when `to_csv` is
instantiated, so what runs is the same sequence of `push_value` calls you
would write by hand, with escaping turned off only for the types that can
never need it.
"""

from std.os import abort
from std.reflection import reflect

from .csv_builder import COMMA, CsvBuilder


def _never_needs_quoting[T: AnyType]() -> Bool:
    """Returns whether a rendered `T` can never hold a separator or a quote.

    True only for single numbers and `Bool`. A `SIMD` vector of width more than
    one renders as `[1, 2]`, and anything else is unknown, so both are checked.
    """
    return (
        T == Int
        or T == Int8
        or T == Int16
        or T == Int32
        or T == Int64
        or T == UInt
        or T == UInt8
        or T == UInt16
        or T == UInt32
        or T == UInt64
        or T == Float16
        or T == Float32
        or T == Float64
        or T == Bool
    )


def _check_fields[T: AnyType]():
    """Fails compilation unless `T` is a struct whose fields can be written."""
    comptime r = reflect[T]
    comptime assert r.is_struct(), "to_csv: the element type must be a struct"
    comptime assert (
        r.field_count() > 0
    ), "to_csv: the element type must have at least one field"
    comptime types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime assert conforms_to(
            types[i], Writable
        ), "to_csv: every field of the element type must be Writable"


def _field_names[T: AnyType]() -> List[String]:
    """Returns the field names of struct `T`, in declaration order."""
    comptime r = reflect[T]
    var names = materialize[r.field_names()]()
    var out = List[String](capacity=r.field_count())
    for i in range(r.field_count()):
        out.append(String(names[i]))
    return out^


def _write_rows[
    T: AnyType, separator: UInt8
](mut builder: CsvBuilder[separator], items: Span[T, _]):
    """Pushes every field of every item, escaping only what might need it."""
    comptime r = reflect[T]
    comptime types = r.field_types()
    for ref item in items:
        comptime for i in range(r.field_count()):
            # Always true, `_check_fields` saw to that; the check is what lets
            # the field be passed on as `Writable`.
            comptime if conforms_to(types[i], Writable):
                comptime if _never_needs_quoting[types[i]]():
                    builder.push_value(r.field_ref[i](item))
                else:
                    builder.push_value(r.field_ref[i](item), escape=True)


def to_csv[T: AnyType, separator: UInt8 = COMMA](items: Span[T, _]) -> String:
    """Writes `items` as a CSV document, with the field names as its header.

    Each item becomes one row and each field one column. Numbers and `Bool`
    are written unchecked; every other field, `String` included, is rendered
    and then checked for bytes that need quoting. A struct with a field
    that is not `Writable` does not compile.

    Parameters:
        T: The element type. Must be a struct with at least one field.
        separator: The byte to put between fields. `,` by default.

    Args:
        items: The rows. A `List[T]` converts.

    Returns:
        The whole document, header first, ending in a CRLF.
    """
    _check_fields[T]()
    var builder = CsvBuilder[separator](_field_names[T]())
    _write_rows(builder, items)
    return builder^.finish()


def to_csv[
    T: AnyType, separator: UInt8 = COMMA
](items: Span[T, _], var header: List[String]) -> String:
    """Writes `items` as a CSV document under a header of your choosing.

    As the other `to_csv`, but the first row is `header` rather than the field
    names, which is how to name a column something a field cannot be called.

    Parameters:
        T: The element type. Must be a struct with at least one field.
        separator: The byte to put between fields. `,` by default.

    Args:
        items: The rows. A `List[T]` converts.
        header: The column names, one per field, in declaration order.

    Returns:
        The whole document, header first, ending in a CRLF.
    """
    _check_fields[T]()
    if len(header) != reflect[T].field_count():
        abort("to_csv needs exactly one header name per field")
    var builder = CsvBuilder[separator](header^)
    _write_rows(builder, items)
    return builder^.finish()
