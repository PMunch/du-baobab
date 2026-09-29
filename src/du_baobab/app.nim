## Owlkettle UI: a directory list on the left and a rings chart on the right.

import owlkettle, owlkettle/cairo
import ./[dutree, format, rings, ringchart, sortablecolumnview]

const MaxRingDepth = 5

let columns = @[
  # Indexed by SortColumn
  initSortableColumn("Name", expand = true, resizable = true),
  initSortableColumn("Size", fixedWidth = 100),
  initSortableColumn("Contents", fixedWidth = 100)
]

viewable App:
  root: DuNode
  current: DuNode
  hovered: DuNode
  layout: RingLayout
  sortColumn: SortColumn = SortSize
  sortDescending: bool = true
  # Children of `current` in display order, cached as sorting by contents
  # is not free and the view is rebuilt on every hover change.
  children: seq[DuNode]
  childrenKey: tuple[node: DuNode, column: SortColumn, descending: bool]

proc navigate(app: AppState, node: DuNode) =
  if not node.isNil and node.isDir:
    app.current = node
    app.hovered = nil

proc goUp(app: AppState) =
  if not app.current.parent.isNil:
    app.navigate(app.current.parent)

proc sortBy(app: AppState, column: SortColumn, descending: bool) =
  ## Switching to another column starts with names ascending and sizes and
  ## item counts descending; clicking the active column flips the direction.
  if app.sortColumn == column:
    app.sortDescending = descending
  else:
    app.sortColumn = column
    app.sortDescending = column != SortName

proc sortedChildren(app: AppState): seq[DuNode] =
  let key = (app.current, app.sortColumn, app.sortDescending)
  if key != app.childrenKey:
    app.children = app.current.sortedChildren(app.sortColumn, app.sortDescending)
    app.childrenKey = key
  app.children

proc titleOf(node: DuNode): string =
  for i, n in node.ancestors:
    if i > 0: result.add " / "
    result.add n.name

method view(app: AppState): Widget =
  let
    current = app.current
    children = app.sortedChildren()
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

        ScrolledWindow {.resize: true, shrink: false.}:
          SortableColumnView:
            rows = children.len
            columns = columns
            sortColumn = ord(app.sortColumn)
            sortDescending = app.sortDescending
            selectionMode = SelectionSingle
            contentId = current.path & '|' & $app.sortColumn & '|' & $app.sortDescending

            proc sort(column: int, descending: bool) =
              if column >= 0:
                app.sortBy(SortColumn(column), descending)

            proc activate(index: int) =
              app.navigate(children[index])

            proc viewItem(row, column: int): Widget =
              let child = children[row]
              case SortColumn(column)
              of SortName:
                result = gui:
                  Box:
                    orient = OrientX
                    spacing = 8
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
              of SortSize:
                result = gui:
                  Label:
                    text = formatSize(child.size)
                    xAlign = 1.0
              of SortContents:
                result = gui:
                  Label:
                    text = if child.isDir: formatItems(child.countItems) else: ""
                    xAlign = 1.0

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
  brew(gui(App(root = root, current = root)))
