## A `ColumnView` with clickable, sortable column headers.
##
## Based on owlkettle's `ColumnView` (MIT License, Copyright (c) 2022 Can
## Joshua Lehmann), which does not support sorting yet. GTK only handles the
## header UI here: clicking a header emits `sort`, and the application is
## expected to reorder its rows itself. The rows are not wrapped in a
## `GtkSortListModel`, so `viewItem` always receives indices in display order.
##
## Unlike owlkettle's version, every row is a distinct object (a
## `GtkStringList` of empty strings) and cells are tracked by list item rather
## than by position, so the row count can shrink without stale cells.

import std/[tables, hashes]
import owlkettle, owlkettle/[widgetdef, widgetutils, bindings/gtk]

type
  GtkSorter = distinct pointer
  GtkSortType = enum
    GtkSortAscending, GtkSortDescending

{.push importc, cdecl.}
proc gtk_custom_sorter_new(sortFunc, userData, userDestroy: pointer): GtkSorter
proc gtk_column_view_column_set_sorter(column: GtkColumnViewColumn, sorter: GtkSorter)
proc gtk_column_view_get_sorter(view: GtkWidget): GtkSorter
proc gtk_column_view_sort_by_column(view: GtkWidget, column: GtkColumnViewColumn,
                                    direction: GtkSortType)
proc gtk_column_view_sorter_get_primary_sort_column(sorter: GtkSorter): GtkColumnViewColumn
proc gtk_column_view_sorter_get_primary_sort_order(sorter: GtkSorter): GtkSortType
proc g_object_unref(obj: pointer)
proc gtk_string_list_new(strings: cstringArray): GListModel
proc gtk_string_list_splice(list: GListModel, position, nRemovals: cuint,
                            additions: cstringArray)
{.pop.}

const GtkInvalidListPosition = high(cuint)

proc hash(widget: GtkWidget): Hash = hash(pointer(widget))
proc `==`(a, b: GtkWidget): bool = pointer(a) == pointer(b)

proc setRowCount(model: GListModel, oldCount, newCount: int) =
  ## Adds or removes rows at the end in a single change.
  if newCount > oldCount:
    let additions = allocCStringArray(newSeq[string](newCount - oldCount))
    defer: deallocCStringArray(additions)
    gtk_string_list_splice(model, cuint(oldCount), 0, additions)
  elif newCount < oldCount:
    gtk_string_list_splice(model, cuint(newCount), cuint(oldCount - newCount), nil)

type SortableColumn* = object
  title*: string
  expand*: bool
  resizable*: bool
  fixedWidth*: int
  sortable*: bool

proc initSortableColumn*(title: string,
                         expand: bool = false,
                         resizable: bool = false,
                         fixedWidth: int = -1,
                         sortable: bool = true): SortableColumn =
  SortableColumn(title: title, expand: expand, resizable: resizable,
                 fixedWidth: fixedWidth, sortable: sortable)

renderable SortableColumnView of BaseWidget:
  rows: int ## Number of rows
  columns: seq[SortableColumn]
  sortColumn: int = -1 ## Index of the column shown as sorted, -1 for none
  sortDescending: bool

  selectionMode: SelectionMode
  showRowSeparators: bool = false
  showColumnSeparators: bool = false
  singleClickActivate: bool = false

  proc viewItem(row, column: int): Widget
  proc activate(index: int)
  proc sort(column: int, descending: bool) ## Called when a header is clicked

  type
    CellState = object
      widgetState: WidgetState

    ColumnStateObj = object
      index: int
      widgetState {.cursor.}: SortableColumnViewState
      gtk: GtkColumnViewColumn
      factory: GtkListItemFactory
      cellStates: Table[GtkWidget, CellState] ## By list item

    ColumnState = ref ColumnStateObj

  model {.private, onlyState.}: GListModel
  selectionModel {.private, onlyState.}: GtkSelectionModel
  columnStates {.private, onlyState.}: seq[ColumnState]
  settingSort {.private, onlyState.}: bool ## Ignore sorter changes made by us
  settingRows {.private, onlyState.}: bool ## `viewItem` is still the old callback

  hooks:
    beforeBuild:
      state.model = gtk_string_list_new(nil)
      state.internalWidget = gtk_column_view_new(GtkSelectionModel(nil))
    update:
      # The rows hook may not have run yet, so use the incoming row count
      let rowCount = if widget.hasRows: widget.valRows else: state.rows
      for columnIndex, column in state.columnStates:
        for listItem, itemState in column.cellStates.mpairs:
          let position = gtk_list_item_get_position(listItem)
          if position == GtkInvalidListPosition or int(position) >= rowCount:
            continue # Removed, will be unbound by GTK
          let updater = state.viewItem.callback(int(position), columnIndex)
          updater.assignApp(state.app)
          let newState =
            if itemState.widgetState.isNil: updater.build()
            else: updater.update(itemState.widgetState)
          if not newState.isNil:
            gtk_list_item_set_child(listItem, newState.unwrapInternalWidget())
            itemState.widgetState = newState
    connectEvents:
      proc activateCallback(widget: GtkWidget,
                            position: cuint,
                            data: ptr EventObj[proc (index: int)]) {.cdecl.} =
        logExceptions:
          data[].callback(int(position))
          data[].redraw()

      state.connect(state.activate, "activate", activateCallback)

      proc sorterChangedCallback(sorter: GtkSorter,
                                 change: cint,
                                 data: ptr EventObj[proc (column: int, descending: bool)]) {.cdecl.} =
        logExceptions:
          let state = SortableColumnViewState(data[].widget)
          if state.settingSort:
            return
          let primary = gtk_column_view_sorter_get_primary_sort_column(sorter)
          var column = -1
          for it, columnState in state.columnStates:
            if pointer(columnState.gtk) == pointer(primary):
              column = it
          let descending =
            gtk_column_view_sorter_get_primary_sort_order(sorter) == GtkSortDescending
          state.sortColumn = column
          state.sortDescending = descending
          data[].callback(column, descending)
          data[].redraw()

      if not state.sort.isNil:
        state.sort.widget = state
        state.sort.handler = g_signal_connect(
          pointer(gtk_column_view_get_sorter(state.internalWidget)),
          "changed",
          sorterChangedCallback,
          state.sort[].addr
        )
    disconnectEvents:
      state.internalWidget.disconnect(state.activate)
      if not state.sort.isNil:
        assert state.sort.handler > 0
        g_signal_handler_disconnect(
          pointer(gtk_column_view_get_sorter(state.internalWidget)),
          state.sort.handler
        )
        state.sort.handler = 0
        state.sort.widget = nil

  hooks columns:
    (build, update):
      if widget.hasColumns:
        state.columns = widget.valColumns

        proc bindCallback(factory: GtkListItemFactory,
                          listItem: GtkWidget,
                          stateObj: ptr ColumnStateObj) {.cdecl.} =
          logExceptions:
            if stateObj[].widgetState.settingRows:
              # Bound while the model changes; built by the update hook
              stateObj[].cellStates[listItem] = CellState()
              return
            let
              index = int(gtk_list_item_get_position(listItem))
              updater = stateObj[].widgetState.viewItem.callback(index, stateObj[].index)
            updater.assignApp(stateObj[].widgetState.app)
            let widgetState = updater.build()
            stateObj[].cellStates[listItem] = CellState(widgetState: widgetState)
            gtk_list_item_set_child(listItem, widgetState.unwrapInternalWidget())

        proc unbindCallback(factory: GtkListItemFactory,
                            listItem: GtkWidget,
                            stateObj: ptr ColumnStateObj) {.cdecl.} =
          logExceptions:
            stateObj[].cellStates.del(listItem)

        proc applyProperties(columnState: ColumnState, column: SortableColumn) =
          gtk_column_view_column_set_title(columnState.gtk, column.title.cstring)
          gtk_column_view_column_set_resizable(columnState.gtk, cbool(ord(column.resizable)))
          gtk_column_view_column_set_expand(columnState.gtk, cbool(ord(column.expand)))
          gtk_column_view_column_set_fixed_width(columnState.gtk, cint(column.fixedWidth))
          # A sorter makes the header clickable. It never compares anything,
          # since the rows are sorted by the application.
          var sorter = GtkSorter(nil)
          if column.sortable:
            sorter = gtk_custom_sorter_new(nil, nil, nil)
          gtk_column_view_column_set_sorter(columnState.gtk, sorter)
          if column.sortable:
            g_object_unref(pointer(sorter))

        var it = 0
        while it < state.columnStates.len and it < widget.valColumns.len:
          state.columnStates[it].applyProperties(widget.valColumns[it])
          it += 1

        while it < widget.valColumns.len:
          let columnState = ColumnState(index: it, widgetState: state)
          columnState.factory = gtk_signal_list_item_factory_new()
          discard g_signal_connect(columnState.factory, "bind", pointer(bindCallback), columnState[].addr)
          discard g_signal_connect(columnState.factory, "unbind", pointer(unbindCallback), columnState[].addr)
          columnState.gtk = gtk_column_view_column_new(widget.valColumns[it].title.cstring,
                                                       columnState.factory)
          columnState.applyProperties(widget.valColumns[it])
          gtk_column_view_append_column(state.internalWidget, columnState.gtk)
          state.columnStates.add(columnState)
          it += 1

        while it < state.columnStates.len:
          let columnState = state.columnStates.pop()
          gtk_column_view_remove_column(state.internalWidget, columnState.gtk)

  hooks sortColumn:
    (build, update):
      if widget.hasSortColumn:
        state.sortColumn = widget.valSortColumn
      if widget.hasSortDescending:
        state.sortDescending = widget.valSortDescending
      let
        sorter = gtk_column_view_get_sorter(state.internalWidget)
        current = gtk_column_view_sorter_get_primary_sort_column(sorter)
        currentDescending =
          gtk_column_view_sorter_get_primary_sort_order(sorter) == GtkSortDescending
        wanted =
          if state.sortColumn in 0 ..< state.columnStates.len:
            state.columnStates[state.sortColumn].gtk
          else:
            GtkColumnViewColumn(nil)
      if pointer(wanted) != pointer(current) or
          (not pointer(wanted).isNil and currentDescending != state.sortDescending):
        state.settingSort = true
        gtk_column_view_sort_by_column(
          state.internalWidget, wanted,
          if state.sortDescending: GtkSortDescending else: GtkSortAscending
        )
        state.settingSort = false

  hooks rows:
    (build, update):
      if widget.hasRows:
        state.settingRows = true
        state.model.setRowCount(state.rows, widget.valRows)
        state.settingRows = false
        state.rows = widget.valRows

  hooks selectionMode:
    property:
      case state.selectionMode:
        of SelectionNone:
          state.selectionModel = gtk_no_selection_new(state.model)
        of SelectionSingle:
          state.selectionModel = gtk_single_selection_new(state.model)
        of SelectionBrowse, SelectionMultiple:
          state.selectionModel = gtk_multi_selection_new(state.model)
      gtk_column_view_set_model(state.internalWidget, state.selectionModel)

  hooks showRowSeparators:
    property:
      gtk_column_view_set_show_row_separators(state.internalWidget,
        cbool(ord(state.showRowSeparators)))

  hooks showColumnSeparators:
    property:
      gtk_column_view_set_show_column_separators(state.internalWidget,
        cbool(ord(state.showColumnSeparators)))

  hooks singleClickActivate:
    property:
      gtk_column_view_set_single_click_activate(state.internalWidget,
        cbool(ord(state.singleClickActivate)))

export SortableColumnView
