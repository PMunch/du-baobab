## Owlkettle UI: a directory list on the left and a rings chart on the right.

import std/sets
import owlkettle, owlkettle/[cairo, widgetdef, bindings/gtk]
import ./[dutree, format, rings, ringchart, sortablecolumnview]

const
  MaxRingDepth = 5
  IndentWidth = 16 ## Per level of the tree
  ExpanderWidth = 22 ## Width of the expander buttons, used to align files

let columns = @[
  # Indexed by SortColumn
  initSortableColumn("Name", expand = true, resizable = true),
  initSortableColumn("Size", fixedWidth = 100),
  initSortableColumn("Contents", fixedWidth = 100)
]

proc gtk_widget_set_visible(widget: GtkWidget, visible: cbool) {.importc, cdecl.}

renderable HiddenTitlebar of BaseWidget:
  ## Stops GTK from adding a title bar, like libadwaita's `AdwWindow`.
  hooks:
    beforeBuild:
      state.internalWidget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
      gtk_widget_set_visible(state.internalWidget, cbool(0))

viewable App:
  root: DuNode
  current: DuNode
  hovered: DuNode
  layout: RingLayout
  sortColumn: SortColumn = SortSize
  sortDescending: bool = true
  expanded: HashSet[DuNode] ## Folders opened in the list's tree
  expandedVersion: int     ## Changes whenever `expanded` does
  # Rows of the list, cached as sorting by contents is not free and the
  # view is rebuilt on every hover change.
  rows: seq[TreeRow]
  rowsKey: tuple[node: DuNode, column: SortColumn, descending: bool, version: int]

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

proc toggleExpanded(app: AppState, node: DuNode) =
  if node in app.expanded:
    app.expanded.excl node
  else:
    app.expanded.incl node
  inc app.expandedVersion

proc visibleRows(app: AppState): seq[TreeRow] =
  let key = (app.current, app.sortColumn, app.sortDescending, app.expandedVersion)
  if key != app.rowsKey:
    app.rows = app.current.visibleRows(app.sortColumn, app.sortDescending,
                                       app.expanded)
    app.rowsKey = key
  app.rows

proc titleOf(node: DuNode): string =
  for i, n in node.ancestors:
    if i > 0: result.add " / "
    result.add n.name

method view(app: AppState): Widget =
  let
    current = app.current
    rows = app.visibleRows()
  result = gui:
    Window:
      title = "du-baobab"
      defaultSize = (1400, 850)

      # GTK hides the title bar in fullscreen, so the header bar is part of
      # the content instead, like in libadwaita apps.
      HiddenTitlebar {.addTitlebar.}

      Box:
        orient = OrientY

        HeaderBar {.expand: false.}:
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
              rows = rows.len
              columns = columns
              sortColumn = ord(app.sortColumn)
              sortDescending = app.sortDescending
              selectionMode = SelectionSingle
              # Rows are added and removed at the end, so the selection would
              # move to another entry when a folder is expanded or collapsed.
              contentId = current.path & '|' & $app.sortColumn & '|' &
                          $app.sortDescending & '|' & $app.expandedVersion

              proc sort(column: int, descending: bool) =
                if column >= 0:
                  app.sortBy(SortColumn(column), descending)

              proc activate(index: int) =
                app.navigate(rows[index].node)

              proc viewItem(row, column: int): Widget =
                let
                  (child, depth) = rows[row]
                  parentSize = child.parent.size
                case SortColumn(column)
                of SortName:
                  result = gui:
                    Box:
                      orient = OrientX
                      spacing = 8
                      margin = Margin(left: IndentWidth * depth)
                      if child.isDir:
                        Button {.expand: false.}:
                          icon = if child in app.expanded: "pan-down-symbolic"
                                 else: "pan-end-symbolic"
                          style = [ButtonFlat, StyleClass("expander")]
                          tooltip = if child in app.expanded: "Collapse" else: "Expand"
                          proc clicked() =
                            app.toggleExpanded(child)
                      else:
                        Box {.expand: false.}:
                          sizeRequest = (ExpanderWidth, -1)
                      DrawingArea {.expand: false.}:
                        sizeRequest = (40, -1)
                        proc draw(ctx: CairoContext, size: (int, int)): bool =
                          ctx.drawShareBar(size[0].float, size[1].float,
                                           child.size.float / max(1, parentSize).float)
                      Label {.expand: false.}:
                        text = formatPercent(child.size, parentSize)
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
  brew(gui(App(root = root, current = root)), stylesheets = [
    # Keep the expander buttons as small as the text, like GtkTreeExpander
    newStylesheet("""
      button.expander {
        min-width: 16px;
        min-height: 16px;
        padding: 0 2px;
      }
    """)
  ])
