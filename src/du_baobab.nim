## du-baobab: interactive Baobab-style visualization of `du` output.
##
## Usage:
##   du ~/Documents > docs.du.txt && du_baobab docs.du.txt
##   du -b ~/Documents | du_baobab --block-size=1

import std/[parseopt, strutils]
import du_baobab/[dutree, app]

const Usage = """
Usage: du_baobab [options] [FILE]

Visualize the output of `du`. Reads from FILE, or from stdin if FILE is
omitted or `-`.

Options:
  -B, --block-size=N  Size unit of du's numbers in bytes (default: 1024;
                      use 1 for `du -b`). Sizes with a K/M/G suffix from
                      `du -h` are always understood.
  -h, --help          Show this help
"""

proc main() =
  var
    filename = ""
    blockSize = 1024'i64
  for kind, key, val in getopt(shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdArgument:
      filename = key
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        echo Usage
        quit 0
      of "B", "block-size":
        blockSize = parseBiggestInt(val)
      else:
        quit "Unknown option: " & key & "\n\n" & Usage, 1
    of cmdEnd: discard

  let input =
    if filename in ["", "-"]: stdin.readAll()
    else: readFile(filename)
  let root =
    try: parseDu(input, blockSize)
    except DuParseError as e:
      quit "Failed to parse du output: " & e.msg, 1
  runApp(root)

when isMainModule:
  main()
