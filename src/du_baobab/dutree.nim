## Parsing of `du` output into a tree of directories.
##
## `du` prints one line per entry in the form `<size>\t<path>`, children
## before their parents. By default only directories are listed (use `du -a`
## to include files) and sizes are in 1024-byte blocks (`du -b` gives bytes,
## `du -h` gives human-readable sizes such as `4.0K`).

import std/[os, strutils, tables, algorithm, math, unicode]

type
  DuNode* = ref object
    name*: string        ## Last path component (full path for the root)
    path*: string        ## Path as printed by du
    size*: int64         ## Size in bytes
    children*: seq[DuNode] ## Sorted by size, largest first
    parent* {.cursor.}: DuNode
    synthetic*: bool     ## Placeholder for space not accounted to any listed child
    itemCount: int       ## Cached result of `countItems`

  DuParseError* = object of ValueError

const
  FilesNodeName* = "(files)"
  DirEntrySize* = 4096 ## Space a directory takes up itself on most file systems

proc parseSize*(s: string, blockSize: int64 = 1024): int64 =
  ## Parses a du size column. Plain numbers are multiplied by `blockSize`,
  ## numbers with a K/M/G/T/P suffix (from `du -h`) are interpreted as
  ## binary multiples of bytes.
  let s = s.strip()
  if s.len == 0:
    raise newException(DuParseError, "empty size")
  let suffix = s[^1].toUpperAscii()
  const units = "KMGTPE"
  let unitIdx = units.find(suffix)
  if unitIdx >= 0:
    let value = parseFloat(s[0 ..< ^1])
    result = int64(value * pow(1024.0, float(unitIdx + 1)))
  else:
    result = parseBiggestInt(s) * blockSize

proc stripTrailingSlashes(p: string): string =
  result = p
  while result.len > 1 and result.endsWith('/'):
    result.setLen(result.len - 1)

proc sortBySize*(node: DuNode) =
  node.children.sort(proc (a, b: DuNode): int = cmp(b.size, a.size))
  for child in node.children:
    child.sortBySize()

proc addFilesNodes(node: DuNode) =
  ## Adds a synthetic child for space in `node` not covered by its children,
  ## i.e. the files directly inside a directory when du was run without `-a`.
  ## A remainder of up to `DirEntrySize` is the directory itself and ignored,
  ## otherwise `du -a` output would get a `(files)` entry in every directory.
  if node.children.len == 0:
    return
  var childSum: int64
  for child in node.children:
    child.addFilesNodes()
    childSum += child.size
  if node.size - childSum > DirEntrySize:
    node.children.add DuNode(
      name: FilesNodeName,
      path: node.path / FilesNodeName,
      size: node.size - childSum,
      parent: node,
      synthetic: true
    )

proc computeItemCounts(node: DuNode) =
  node.itemCount = 0
  for child in node.children:
    child.computeItemCounts()
    if not child.synthetic:
      node.itemCount += 1 + child.itemCount

proc parseDu*(input: string, blockSize: int64 = 1024,
              addFiles = true): DuNode =
  ## Builds a tree from du output. The root is the entry that is an ancestor
  ## of all others (normally the last line).
  var nodes = initOrderedTable[string, DuNode]()
  var lineNo = -1
  for line in input.splitLines():
    inc lineNo
    if line.isEmptyOrWhitespace:
      continue
    # Only the separator is removed: file names may start or end with spaces.
    let tab = line.find('\t')
    var sizeStr, rawPath: string
    if tab >= 0:
      sizeStr = line[0 ..< tab]
      rawPath = line[tab + 1 .. ^1]
    else:
      # Fallback for space separated input, e.g. copied from a terminal
      let fields = line.strip(trailing = false).split(' ', maxsplit = 1)
      if fields.len < 2:
        raise newException(DuParseError,
          "line " & $(lineNo + 1) & ": expected '<size>\\t<path>'")
      sizeStr = fields[0]
      rawPath = fields[1].strip(trailing = false)
    let path = stripTrailingSlashes(rawPath)
    let size =
      try: parseSize(sizeStr, blockSize)
      except ValueError as e:
        raise newException(DuParseError,
          "line " & $(lineNo + 1) & ": " & e.msg)
    nodes[path] = DuNode(name: extractFilename(path), path: path, size: size)

  if nodes.len == 0:
    raise newException(DuParseError, "no entries found")

  for path, node in nodes:
    let parentPath = parentDir(path)
    if parentPath != path and parentPath in nodes:
      node.parent = nodes[parentPath]
      node.parent.children.add node
    elif result.isNil or node.size > result.size:
      # Candidate root; with well-formed input there is exactly one.
      result = node

  if result.name.len == 0:
    result.name = result.path
  if addFiles:
    result.addFilesNodes()
  result.computeItemCounts()
  result.sortBySize()

proc parseDuFile*(filename: string, blockSize: int64 = 1024): DuNode =
  parseDu(readFile(filename), blockSize)

proc isDir*(node: DuNode): bool =
  ## Whether the node can be navigated into.
  node.children.len > 0

proc depth*(node: DuNode): int =
  var cur = node.parent
  while not cur.isNil:
    inc result
    cur = cur.parent

proc ancestors*(node: DuNode): seq[DuNode] =
  ## Path from the root down to `node`, inclusive.
  var cur = node
  while not cur.isNil:
    result.add cur
    cur = cur.parent
  result.reverse()

proc countItems*(node: DuNode): int =
  ## Number of entries (recursively) below `node`, excluding synthetic ones.
  node.itemCount

type SortColumn* = enum
  SortName, SortSize, SortContents

proc sortedChildren*(node: DuNode, column: SortColumn,
                     descending: bool): seq[DuNode] =
  ## Children of `node` ordered by `column`. Names are compared case
  ## insensitively; ties are broken by size (largest first), then name.
  var entries: seq[tuple[node: DuNode, name: string, items: int]]
  for child in node.children:
    entries.add (child, unicode.toLower(child.name),
                 (if column == SortContents: child.countItems else: 0))
  entries.sort(proc (a, b: typeof(entries[0])): int =
    result =
      case column
      of SortName: cmp(a.name, b.name)
      of SortSize: cmp(a.node.size, b.node.size)
      of SortContents: cmp(a.items, b.items)
    if descending:
      result = -result
    if result == 0:
      result = cmp(b.node.size, a.node.size)
    if result == 0:
      result = cmp(a.name, b.name))
  for entry in entries:
    result.add entry.node
