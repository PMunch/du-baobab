## Human readable formatting, matching Baobab's (SI units) style.

import std/strutils

proc formatSize*(bytes: int64): string =
  ## Formats a size using decimal units, e.g. `476.8 MB`, `827.4 kB`.
  const units = ["kB", "MB", "GB", "TB", "PB", "EB"]
  if bytes < 1000:
    return $bytes & (if bytes == 1: " byte" else: " bytes")
  var value = bytes.float / 1000.0
  var unit = 0
  while value >= 999.95 and unit < units.high:
    value /= 1000.0
    inc unit
  formatFloat(value, ffDecimal, 1) & " " & units[unit]

proc formatPercent*(part, total: int64): string =
  if total <= 0:
    return "0.00%"
  formatFloat(part.float / total.float * 100.0, ffDecimal, 2) & "%"

proc formatItems*(count: int): string =
  $count & (if count == 1: " item" else: " items")
