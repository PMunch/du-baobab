## Owlkettle UI: a directory list on the left and a rings chart on the right.

import std/strutils except formatSize
import owlkettle, owlkettle/cairo
import ./[dutree, format, rings, ringchart]

const
  MaxRingDepth = 5
  ColumnHeader = "column-header".StyleClass
  Css = """
    .column-header {
      padding: 2px 0;
      min-height: 0;
      font-weight: bold;
      color: alpha(currentColor, 0.6);
    }
  """

viewable App:
  root: DuNode
  current: DuNode
  hovered: DuNode
  layout: RingLayout
  sortColumn: SortColumn = SortSize
  sortDescending: bool = true

proc navigate(app: AppState, node: DuNode) =
  if not node.isNil and node.isDir:
    app.current = node
    app.hovered = nil

proc goUp(app: AppState) =
  if not app.current.parent.isNil:
    app.navigate(app.current.parent)

proc sortBy(app: AppState, column: SortColumn) =
  ## Clicking the active column flips the direction; names start ascending,
  ## sizes and item counts descending.
  if app.sortColumn == column:
    app.sortDescending = not app.sortDescending
  else:
    app.sortColumn = column
    app.sortDescending = column != SortName

proc columnHeader(app: AppState, title: string, column: SortColumn,
                  align: float): Widget =
  let active = app.sortColumn == column
  result = gui:
    Button:
      style = [ButtonFlat, ColumnHeader]
      tooltip = "Sort by " & title.toLowerAscii
      proc clicked() =
        app.sortBy(column)
      Box:
        orient = OrientX
        spacing = 2
        Label:
          text = title
          xAlign = align
        if active:
          Icon {.expand: false.}:
            name = if app.sortDescending: "pan-down-symbolic" else: "pan-up-symbolic"

proc titleOf(node: DuNode): string =
  for i, n in node.ancestors:
    if i > 0: result.add " / "
    result.add n.name

method view(app: AppState): Widget =
  let current = app.current
  result = gui:
    Window:
      title = "du-baobab"
      defaultSize = (1400, 850)

      HeaderBar {.addTitlebar.}:
        Label {.addTitle.}:
          text = current.titleOf
          ellipsize = EllipsizeStart

        Button {.addLeft.}:
          icon = "go-previous-symbolic"
          tooltip = "Parent folder"
          sensitive = not current.parent.isNil
          proc clicked() =
            app.goUp()

      Paned:
        initialPosition = 560

        Box {.resize: true, shrink: false.}:
          orient = OrientY

          Box {.expand: false.}:
            orient = OrientX
            spacing = 8
            margin = 4
            insert(app.columnHeader("Name", SortName, 0.0))
            insert(app.columnHeader("Size", SortSize, 1.0)) {.expand: false.}
            insert(app.columnHeader("Contents", SortContents, 1.0)) {.expand: false.}

          Separator {.expand: false.}

          ScrolledWindow:
            ListBox:
              selectionMode = SelectionSingle
              for child in current.sortedChildren(app.sortColumn, app.sortDescending):
                ListBoxRow {.addRow.}:
                  proc activate() =
                    app.navigate(child)
                  Box:
                    orient = OrientX
                    spacing = 8
                    margin = 4
                    Label {.expand: false.}:
                      text = if child.isDir: "›" else: " "
                      sizeRequest = (12, -1)
                    DrawingArea {.expand: false.}:
                      sizeRequest = (40, -1)
                      proc draw(ctx: CairoContext, size: (int, int)): bool =
                        ctx.drawShareBar(size[0].float, size[1].float,
                                         child.size.float / max(1, current.size).float)
                    Label {.expand: false.}:
                      text = formatPercent(child.size, current.size)
                      xAlign = 1.0
                      sizeRequest = (64, -1)
                    Label:
                      text = child.name
                      xAlign = 0.0
                      ellipsize = EllipsizeEnd
                    Label {.expand: false.}:
                      text = formatSize(child.size)
                      xAlign = 1.0
                      sizeRequest = (90, -1)
                    Label {.expand: false.}:
                      text = if child.isDir: formatItems(child.countItems) else: ""
                      xAlign = 1.0
                      sizeRequest = (90, -1)

        DrawingArea {.resize: true, shrink: false.}:
          proc draw(ctx: CairoContext, size: (int, int)): bool =
            app.layout = layoutRings(current, size[0].float, size[1].float,
                                     maxDepth = MaxRingDepth)
            ctx.drawRings(app.layout, app.hovered)

          proc mouseMoved(event: MotionEvent): bool =
            let hit = app.layout.hitTest(event.x, event.y)
            let node =
              case hit.kind
              of HitSegment: app.layout.segments[hit.index].node
              of HitCenter: current
              of HitNone: nil
            if node != app.hovered:
              app.hovered = node
              result = true

          proc mouseReleased(event: ButtonEvent): bool =
            if event.button != 0:
              return false
            let hit = app.layout.hitTest(event.x, event.y)
            case hit.kind
            of HitSegment: app.navigate(app.layout.segments[hit.index].node)
            of HitCenter: app.goUp()
            of HitNone: discard
            result = true

proc runApp*(root: DuNode) =
  brew(gui(App(root = root, current = root)),
       stylesheets = [newStylesheet(Css)])
