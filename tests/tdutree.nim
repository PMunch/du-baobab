import std/[unittest, os, tables]
import std/strutils except formatSize
import du_baobab/[dutree, format]

# Synthetic data, the same made-up tree printed by `du -a` and by plain `du`
const
  dataDir = currentSourcePath.parentDir / "data"
  sampleAll = dataDir / "sample.du.txt"
  sampleDirs = dataDir / "sample-dirs.du.txt"

proc child(node: DuNode, name: string): DuNode =
  for c in node.children:
    if c.name == name:
      return c
  raise newException(KeyError, "no child " & escape(name) & " in " & node.path)

proc walk(node: DuNode, fn: proc (n: DuNode)) =
  fn(node)
  for c in node.children:
    c.walk(fn)

suite "parseSize":
  test "blocks":
    check parseSize("4") == 4096
    check parseSize("4", blockSize = 1) == 4
  test "human readable":
    check parseSize("4.0K") == 4096
    check parseSize("1.5M") == 1572864

suite "parseDu":
  test "small tree":
    let root = parseDu("4\ta/b/c\n12\ta/b\n8\ta/d\n24\ta\n")
    check root.name == "a"
    check root.size == 24 * 1024
    # The remaining 4K in a is the directory itself, so no (files) entry
    check root.children.len == 2
    let b = root.children[0]                   # sorted by size
    check b.name == "b"
    check b.parent == root
    # b is 12K but c only 4K, so 8K of files directly inside b
    check b.children[0].synthetic
    check b.children[0].size == 8 * 1024
    check b.children[1].name == "c"
    check root.countItems == 3

  test "trailing slashes and spaces in names":
    let root = parseDu("4\t./my dir/\n8\t./\n")
    check root.path == "."
    check root.children[0].name == "my dir"

  test "leading and trailing spaces in names":
    let root = parseDu("4\ta/ lead\n4\ta/trail \n12\ta\n")
    check root.child(" lead").size == 4096
    check root.child("trail ").size == 4096

  test "space separated fallback":
    let root = parseDu("  4 a/my file\n 8 a\n")
    check root.child("my file").size == 4096

  test "invalid input":
    expect DuParseError:
      discard parseDu("")
    expect DuParseError:
      discard parseDu("abc\tfoo\n")

suite "sample data":
  let
    root = parseDuFile(sampleAll)
    dirsRoot = parseDuFile(sampleDirs)

  test "root":
    check root.name == "sample"
    check root.size == 14_660_612 * 1024
    check formatSize(root.size) == "15.0 GB"
    check root.children[0].name == "disk image.iso"   # largest first

  test "sizes of children add up":
    # With -a everything is listed, so only the directory itself is left over
    root.walk(proc (n: DuNode) =
      if n.isDir:
        var sum: int64
        for c in n.children: sum += c.size
        check n.size - sum == DirEntrySize)

  test "no (files) entries with -a":
    root.walk(proc (n: DuNode) =
      check not n.synthetic)

  test "whitespace in names":
    let docs = root.child("My Documents")
    check docs.child("two  spaces").isDir
    check docs.child(" leading space").isDir
    check docs.child("trailing space ").isDir
    check docs.child("CV - final (2).pdf").size == 188 * 1024
    check root.child("weird").child("tab\there.txt").size == 4096

  test "unicode and special characters":
    check root.child("Music").child("Björk").child("Homogenic")
      .child("02 - Jóga.flac").size == 29876 * 1024
    check root.child("Music").child("Sigur Rós").child("( )").isDir
    check root.child("Music").child("AC_DC & Friends")
      .child("Rock 'n' Roll \"Live\".mp3").size == 9216 * 1024
    check root.child("日本語のフォルダ").child("写真.png").size == 1536 * 1024
    let weird = root.child("weird")
    for name in ["back\\slash.txt", "semi;colon", "percent%20encoded",
                 "..double-dot", "-starts-with-dash", "#hash", "$dollar",
                 "emoji 🎉.txt", "123"]:
      check weird.child(name).size == 4096
    check weird.child("file.with.many.dots.tar.gz").size == 820 * 1024

  test "hidden entries":
    check root.child(".hidden").child(".config").child("settings.json").size == 4096
    check root.child("src").child(".git").child("objects").child("pack").isDir

  test "empty entries":
    check root.child("empty file.txt").size == 0
    check root.child("empty dir").size == 4096
    check not root.child("empty dir").isDir
    check root.child("Holiday Photos 2019").child("Thumbs").size == 4096

  test "paths":
    let raw = root.child("Holiday Photos 2019").child("Raw")
    check raw.path == "sample/Holiday Photos 2019/Raw"
    check raw.depth == 2
    check raw.ancestors[0] == root

  test "directories only output":
    check dirsRoot.size == root.size
    # Without -a the files show up as a single synthetic entry
    let photos = dirsRoot.child("Holiday Photos 2019")
    check photos.child(FilesNodeName).synthetic
    check photos.child(FilesNodeName).size == (3120 + 2988 + 3410 + 4) * 1024
    check not photos.child("Raw").isDir
    check dirsRoot.child(FilesNodeName).size ==
      (12582912 + 1843200 + 0 + 4) * 1024

  test "both outputs agree on directory sizes":
    var dirSizes = initTable[string, int64]()
    dirsRoot.walk(proc (n: DuNode) =
      if not n.synthetic: dirSizes[n.path] = n.size)
    var matched = 0
    root.walk(proc (n: DuNode) =
      if n.path in dirSizes:
        check n.size == dirSizes[n.path]
        inc matched)
    check matched == dirSizes.len

suite "format":
  test "sizes":
    check formatSize(0) == "0 bytes"
    check formatSize(827_400) == "827.4 kB"
    check formatSize(999_999) == "1.0 MB"
  test "percent":
    check formatPercent(1694, 10000) == "16.94%"

suite "sortedChildren":
  # a has 3 items and 16K, b has 1 item and 20K, C has none and 8K
  let root = parseDu("4\tr/a/x\n4\tr/a/y\n4\tr/a/z\n16\tr/a\n" &
                     "16\tr/b/big\n20\tr/b\n8\tr/C\n48\tr\n")

  proc names(nodes: seq[DuNode]): seq[string] =
    for n in nodes: result.add n.name

  test "by name, case insensitive":
    check root.sortedChildren(SortName, false).names == @["a", "b", "C"]
    check root.sortedChildren(SortName, true).names == @["C", "b", "a"]

  test "by size":
    check root.sortedChildren(SortSize, true).names == @["b", "a", "C"]
    check root.sortedChildren(SortSize, false).names == @["C", "a", "b"]

  test "by contents":
    check root.sortedChildren(SortContents, true).names == @["a", "b", "C"]
    check root.sortedChildren(SortContents, false).names == @["C", "b", "a"]

  test "ties are broken by size":
    let tied = parseDu("4\tr/small\n8\tr/big\n16\tr\n")
    check tied.sortedChildren(SortContents, false).names == @["big", "small"]
