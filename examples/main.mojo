"""Reading and writing CSV."""

from mm_csv import CsvBuilder, CsvFields, CsvTable, to_csv


def writing() raises:
    print("--- writing ---")
    var names: List[String] = ["name", "note", "score"]
    var builder = CsvBuilder(names^)

    builder.push("Ada")
    builder.push("first, and foremost")  # holds a comma: gets quoted
    builder.push_value(100)

    builder.push("Grace")
    builder.push('said "hello"')  # holds a quote: gets doubled
    builder.push_value(99)

    builder.push("Alan")
    # A value known to be plain can skip the check. It is the caller's
    # promise: a separator slipping through here makes a broken document.
    builder.push("plain", escape=False)
    builder.push_value(98)

    var document = builder^.finish()
    print(repr(document))


@fieldwise_init
struct Reading(Copyable):
    var station: String
    var hour: Int
    var celsius: Float64


def writing_structs():
    print("\n--- writing structs ---")
    # The header is the field names; each struct is a row. Strings are
    # checked for quoting, numbers are not.
    var readings: List[Reading] = [
        Reading("north, upper", 7, 12.5),
        Reading("south", 8, -3.0),
    ]
    print(repr(to_csv(readings)))


def reading() raises:
    print("\n--- reading ---")
    var document = String(
        "name,note,score\r\n"
        'Ada,"first, and foremost",100\r\n'
        'Grace,"said ""hello""",99\r\n'
    )
    var table = CsvTable(document^)
    print("rows:", table.row_count(), " columns:", table.column_count)

    for row in range(1, table.row_count()):
        # `field` borrows and copies nothing, but hands back the raw bytes;
        # `get` undoes the quoting and allocates.
        print(
            "  ",
            table.field(row, 0),
            "|",
            table.get(row, 1),
            "|",
            table.field(row, 2),
        )

    print("  note column quoted?", table.is_quoted(1, 1))
    print("  ragged?", table.is_ragged())

    try:
        _ = table.get(0, 99)
    except error:
        print("  out of range raises:", error)


def streaming() raises:
    print("\n--- streaming ---")
    # No index is built. The fields arrive once, in order, each saying
    # whether it closed a row. Slower than indexing -- see the README -- but
    # it costs no memory beyond the document itself.
    var document = String("a,b,c\r\nd,e,f\r\n")
    var row = String()
    for field in CsvFields(document):
        row += String(field.value, " ")
        if field.ends_row:
            print("  row:", row)
            row = String()


def tab_separated() raises:
    print("\n--- a different separator ---")
    var table = CsvTable[UInt8(ord("\t"))](String("a\tb\r\nc\td\r\n"))
    print("  columns:", table.column_count, " [1,0] =", table.get(1, 0))


def main() raises:
    writing()
    writing_structs()
    reading()
    streaming()
    tab_separated()
