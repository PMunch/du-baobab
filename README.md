# du-baobab

An interactive, [Baobab](https://apps.gnome.org/Baobab/)-style visualization
of `du` output, written in Nim with [owlkettle](https://github.com/can-lehmann/owlkettle) (GTK 4).

```sh
du -a ~/Synced > synced.du.txt   # -a includes files, not just directories
du_baobab synced.du.txt
du -ab /some/dir | du_baobab --block-size=1
```

Without `-a`, du only reports directories; the space taken by files directly
inside a directory is shown as a grey `(files)` entry.

## Building

Requires GTK 4 development files.

```sh
nimble build
nimble test
```

## Layout

| File | Purpose |
| --- | --- |
| `src/du_baobab.nim` | CLI entry point |
| `src/du_baobab/dutree.nim` | Parses du output into a `DuNode` tree |
| `src/du_baobab/format.nim` | Size / percentage formatting (SI units, like Baobab) |
| `src/du_baobab/rings.nim` | Rings chart geometry and hit testing (no GTK) |
| `src/du_baobab/ringchart.nim` | Cairo rendering of the rings chart |
| `src/du_baobab/app.nim` | Owlkettle UI |

## Interaction

- Hover a segment to see its name and size in the centre.
- Click a segment or a list row to open that directory.
- Click the centre, or the back button, to go to the parent directory.
