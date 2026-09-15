#!/usr/bin/env bash
# Builds the two CSV files the benchmark reads. Nothing here is committed --
# they are ~50 MB together, and the shapes are what matter, not the bytes.
#
#   bash data/setup.sh                       # generate them
#   bash data/setup.sh plain.csv quoted.csv  # or use two of your own
#
# The originals were two New Zealand government statistics exports linked from
# the upstream README. Both URLs are now dead, so the default is a generator
# matching the row count, column count, quoted fraction and field-length
# distribution those files measured:
#
#                       generated   original
#   no_escaping.csv       23.1 MB   22.5 MB   255 360 rows   8 cols   0% quoted
#   needs_escaping.csv    24.9 MB   29.9 MB   201 181 rows  10 cols  10% quoted
#
# The second is smaller than its original, whose mean field ran to 13.5 bytes
# against this generator's 10. Pass your own two files to compare like for
# like with a published number.
#
# Both use CRLF, as RFC 4180 requires. Field lengths follow the originals'
# distribution: a median of 6-7 bytes and a long tail out to 80.
set -eu
cd "$(dirname "$0")"

if [ $# -ge 2 ]; then
  cp "$1" no_escaping.csv
  cp "$2" needs_escaping.csv
  echo "copied $1 and $2 into data/"
else
  echo "generating (a few seconds)"
  python3 generate.py
fi

for f in no_escaping.csv needs_escaping.csv; do
  python3 - "$f" <<'PY'
import csv, io, statistics, sys
raw = open(sys.argv[1], "rb").read()
rows = list(csv.reader(io.StringIO(raw.decode())))
body = [r for r in rows[1:] if r]
lens = [len(f) for r in body for f in r]
quoted = sum(1 for r in body for f in r if any(c in f for c in ',"\r\n'))
total = sum(len(r) for r in body)
print("  %-20s %9d bytes  %7d rows  %2d cols  CRLF=%d  quoted=%.1f%%  median field=%d" % (
    sys.argv[1], len(raw), len(body), len(rows[0]), raw.count(b"\r\n"),
    quoted * 100 / total, statistics.median(lens)))
PY
done
