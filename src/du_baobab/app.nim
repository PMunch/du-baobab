## Owlkettle UI: a directory list on the left and a rings chart on the right.

import std/[sets, atomics]
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

type
  AppMode* = enum
    ModeSelect    ## No input given — let the user pick a file
    ModeLoading   ## Reading input in background — show spinner
    ModeReady     ## Tree loaded — show main view
    ModeError     ## Parse/read error

  InputKind* = enum
    ikFile, ikStdin, ikNone

# --- Reader thread infrastructure ---
# A background thread reads stdin or a file and stores the raw content in
# shared memory.  The main thread polls for completion and parses the result.

type
  ReadResult = object
    data: pointer        ## File content (allocShared), nil when len == 0
    len: int
    errMsg: pointer      ## Error message (allocShared), nil when errLen == 0
    errLen: int
    error: bool
    ready: Atomic[bool]

var
  gRead: ptr ReadResult
  gReadThread: Thread[tuple[filename: string, fromStdin: bool]]

proc readerProc(args: tuple[filename: string, fromStdin: bool]) {.thread.} =
  var content: string
  try:
    content = if args.fromStdin: stdin.readAll() else: readFile(args.filename)
  except IOError as e:
    gRead[].error = true
    var msg = e.msg
    if msg.len > 0:
      gRead[].errMsg = allocShared(msg.len)
      copyMem(gRead[].errMsg, addr msg[0], msg.len)
      gRead[].errLen = msg.len
    gRead[].ready.store(true, moRelease)
    return
  if content.len > 0:
    gRead[].data = allocShared(content.len)
    copyMem(gRead[].data, addr content[0], content.len)
  gRead[].len = content.len
  gRead[].ready.store(true, moRelease)

proc startReading(filename: string, fromStdin: bool) =
  gRead = cast[ptr ReadResult](allocShared0(sizeof(ReadResult)))
  createThread(gReadThread, readerProc, (filename, fromStdin))

# --- GTK widget setup ---

proc gtk_widget_set_visible(widget: GtkWidget, visible: cbool) {.importc, cdecl.}

renderable HiddenTitlebar of BaseWidget:
  ## Stops GTK from adding a title bar, like libadwaita's `AdwWindow`.
  hooks:
    beforeBuild:
      state.internalWidget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
      gtk_widget_set_visible(state.internalWidget, cbool(0))

viewable App:
  mode: AppMode = ModeReady
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
  blockSize: int64 = 1024
  errorMsg: string
  readingStarted: bool ## Guards against starting multiple poll timers

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

proc openFileDialog(app: AppState): string =
  ## Opens a file chooser and returns the selected path, or "" if cancelled.
  let (res, state) = app.open: gui:
    FileChooserDialog:
      title = "Open du Output"
      action = FileChooserOpen
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Open"
        res = DialogAccept
        style = [ButtonSuggested]
  if res.kind == DialogAccept:
    let filenames = FileChooserDialogState(state).filenames
    if filenames.len > 0:
      return filenames[0]
  return ""

proc startLoadingFile(app: AppState, filename: string) =
  ## Kick off a background read for `filename` and switch to loading mode.
  startReading(filename, false)
  app.mode = ModeLoading
  app.readingStarted = false

method view(app: AppState): Widget =
  # Start polling for reader thread completion on the first render in
  # loading mode.  The poll timer removes itself once the result arrives.
  if app.mode == ModeLoading and not app.readingStarted:
    app.readingStarted = true
    discard addGlobalTimeout(50, proc(): bool =
      if not gRead[].ready.load(moAcquire):
        return true # still reading, keep polling
      joinThread(gReadThread)
      if gRead[].error:
        if gRead[].errLen > 0:
          app.errorMsg = newString(gRead[].errLen)
          copyMem(addr app.errorMsg[0], gRead[].errMsg, gRead[].errLen)
          deallocShared(gRead[].errMsg)
        else:
          app.errorMsg = "Error reading input"
        app.mode = ModeError
      else:
        var content = newString(gRead[].len)
        if gRead[].len > 0:
          copyMem(addr content[0], gRead[].data, gRead[].len)
          deallocShared(gRead[].data)
        try:
          let root = parseDu(content, app.blockSize)
          app.root = root
          app.current = root
          app.mode = ModeReady
        except DuParseError as e:
          app.errorMsg = "Failed to parse du output: " & e.msg
          app.mode = ModeError
      deallocShared(gRead)
      gRead = nil
      discard app.redraw()
      return false
    )

  let
    current = app.current
    rows = if app.mode == ModeReady: app.visibleRows() else: @[]
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
          if app.mode == ModeReady:
            Label {.addTitle.}:
              text = current.titleOf
              ellipsize = EllipsizeStart

            Button {.addLeft.}:
              icon = "go-previous-symbolic"
              tooltip = "Parent folder"
              sensitive = not current.parent.isNil
              proc clicked() =
                app.goUp()
          else:
            Label {.addTitle.}:
              text = if app.mode == ModeLoading: "Loading\xE2\x80\xA6"
                     elif app.mode == ModeError: "Error"
                     else: "du-baobab"

        if app.mode == ModeSelect:
          Box {.vAlign: AlignCenter, hAlign: AlignCenter.}:
            orient = OrientY
            spacing = 16
            Label:
              text = "Open a du output file to visualize disk usage"
              style = [StyleClass("dim-label")]
            Button:
              text = "Open File\xE2\x80\xA6"
              style = [ButtonSuggested]
              proc clicked() =
                let filename = app.openFileDialog()
                if filename.len > 0:
                  app.startLoadingFile(filename)

        if app.mode == ModeLoading:
          Box {.vAlign: AlignCenter, hAlign: AlignCenter.}:
            orient = OrientY
            spacing = 16
            Spinner:
              spinning = true
              sizeRequest = (32, 32)
            Label:
              text = "Reading du output\xE2\x80\xA6"
              style = [StyleClass("dim-label")]

        if app.mode == ModeError:
          Box {.vAlign: AlignCenter, hAlign: AlignCenter.}:
            orient = OrientY
            spacing = 16
            Label:
              text = app.errorMsg
            Button:
              text = "Open File\xE2\x80\xA6"
              style = [ButtonSuggested]
              proc clicked() =
                let filename = app.openFileDialog()
                if filename.len > 0:
                  app.startLoadingFile(filename)

        if app.mode == ModeReady:
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

proc runApp*(inputKind: InputKind, filename: string = "",
             blockSize: int64 = 1024) =
  var mode: AppMode

  case inputKind
  of ikFile:
    startReading(filename, false)
    mode = ModeLoading
  of ikStdin:
    startReading("", true)
    mode = ModeLoading
  of ikNone:
    mode = ModeSelect

  brew(gui(App(mode = mode, blockSize = blockSize)), stylesheets = [
    # Keep the expander buttons as small as the text, like GtkTreeExpander
    newStylesheet("""
      button.expander {
        min-width: 16px;
        min-height: 16px;
        padding: 0 2px;
      }
    """)
  ])
