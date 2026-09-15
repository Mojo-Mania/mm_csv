# Identified improvements

## Choosing the scan automatically

`CsvTable` defaults to the vectorised scan, and the README's sweep shows that
is the wrong choice for documents with short fields — by 12% at two bytes a
field, against a 4x win at 128. Picking per document rather than per caller
looks like free money.

It is not, yet, because **the obvious predictor does not work**. Mean bytes per
field is cheap to sample and is what the sweep varies, so it ought to say which
scan to use. It does not:

| | bytes/field | scalar | simd | winner |
| --- | ---: | ---: | ---: | --- |
| uniform sweep | 9 | 6.9 ms | 5.3 ms | simd, 1.30x |
| `no_escaping.csv` | 11.3 | 22.5 ms | 25.8 ms | scalar, 1.15x |
| `needs_escaping.csv` | 12.4 | 24.1 ms | 28.7 ms | scalar, 1.19x |

At a *larger* mean field length the real documents prefer the *other* scan. A
uniform width is not the same shape as a real distribution — median 6, mean 10,
a tail out to 46 — and something about that distribution, not its mean, decides
the winner. Until there is a statistic that separates these three rows
correctly, an automatic choice would be a guess wearing a measurement's
clothes.

What would settle it: sweep the field-length *distribution* rather than a
single width — same mean, different variance — and see whether the crossover
tracks variance, the median, or the fraction of chunks containing no delimiter
at all. That last one is the mechanism the scan actually cares about, and it is
as cheap to sample as the mean.

## A bitmask instead of `compressed_store`

The SIMD scan stores matching lane indices to a scratch buffer and then reads
them back, and for each one indexes into the comparison masks — `quotes[lane]`,
`line_feeds[lane]` — with a runtime index. Dynamic lane extraction usually goes
through memory, and there are three of them per match.

Turning each mask into an integer bitmask once per chunk and walking the set
bits with a count-trailing-zeros loop would answer all three questions with bit
tests instead. Whether Mojo exposes a SIMD-to-bitmask conversion has not been
checked.

## Streaming

`CsvTable` takes the whole document and keeps it, because every field borrows
from it. That is what makes `field` free, and it means a document has to fit
in memory. A streaming reader would be a different type with a different
bargain, not a change to this one.
