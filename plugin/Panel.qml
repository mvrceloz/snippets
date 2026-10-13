import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Snippets popup: a searchable list of saved items plus an inline editor.
// All file I/O goes through the `snip` CLI so the on-disk format lives in
// one place (daemon/src/store.rs).
Panel {
  id: root
  moduleName: "mvrcelo.snippets"
  ipcTarget: "mvrcelo.snippets"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string snipBinary: setting("snipBinary", "") || (home + "/.local/bin/snip")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")

  readonly property color fg: Color.popups.text
  readonly property color muted: Util.alpha(fg, 0.55)
  readonly property color faint: Util.alpha(fg, 0.38)
  readonly property color cursorFill: Util.alpha(Color.accent, 0.14)
  readonly property int panelWidth: 448

  // ---- data ---------------------------------------------------------------

  property var items: []
  property string query: ""
  property string loadError: ""
  readonly property var filtered: filterItems(items, query)
  property int cursor: 0

  // "list" | "edit"
  property string mode: "list"
  property string editId: ""        // empty while creating a new item
  property string editCreated: ""
  property string originalTitle: ""
  property string originalBody: ""
  property string confirmDeleteId: ""

  function filterItems(all, q) {
    var terms = String(q || "").toLowerCase().split(/\s+/).filter(function(t) { return t !== "" })
    if (terms.length === 0) return all
    return all.filter(function(item) {
      var hay = (item.title + "\n" + item.body).toLowerCase()
      for (var i = 0; i < terms.length; i++) if (hay.indexOf(terms[i]) === -1) return false
      return true
    })
  }

  function displayTitle(item) {
    if (item.title) return item.title
    return String(item.body || "").trim().replace(/\s+/g, " ") || "Untitled"
  }

  function previewText(item) {
    if (!item.title) return "" // the body is already shown in place of a title
    return String(item.body || "").trim().replace(/\s+/g, " ")
  }

  function formatDate(iso) {
    var d = new Date(iso)
    if (isNaN(d.getTime())) return ""
    var now = new Date()
    if (d.toDateString() === now.toDateString()) return Qt.formatDateTime(d, "HH:mm")
    if (d.getFullYear() === now.getFullYear()) return Qt.formatDateTime(d, "d MMM")
    return Qt.formatDateTime(d, "d MMM yyyy")
  }

  function refresh() {
    if (listProc.running) listProc.pending = true
    else listProc.running = true
  }

  function clampCursor() {
    cursor = Math.max(0, Math.min(cursor, filtered.length - 1))
  }

  onFilteredChanged: clampCursor()

  // ---- lifecycle ----------------------------------------------------------

  function open() { openFromHotkey() }

  function openFromHotkey() {
    if (!root.opened) {
      mode = "list"
      query = ""
      searchField.text = ""
      cursor = 0
      confirmDeleteId = ""
    }
    root.controller.show()
    refresh()
  }

  function openNew() {
    openFromHotkey()
    startEdit(null)
  }

  function close() {
    // Closing by clicking outside shouldn't throw away an edit in progress.
    if (mode === "edit") commitEdit()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  // ---- editing ------------------------------------------------------------

  function startEdit(item) {
    confirmDeleteId = ""
    editId = item ? item.id : ""
    editCreated = item ? item.created : ""
    originalTitle = item ? item.title : ""
    originalBody = item ? item.body : ""
    titleField.text = originalTitle
    bodyArea.text = originalBody
    mode = "edit"
    Qt.callLater(function() {
      bodyArea.forceActiveFocus()
      bodyArea.cursorPosition = bodyArea.length
    })
  }

  readonly property bool editDirty: mode === "edit"
    && (titleField.text !== originalTitle || bodyArea.text !== originalBody)

  // Saves when something changed, then returns to the list. A new item with
  // no content is simply discarded.
  function commitEdit() {
    var title = titleField.text.trim()
    var body = bodyArea.text
    var isNew = editId === ""
    if (editDirty && !(isNew && title === "" && body.trim() === "")) {
      runSave({ id: isNew ? null : editId, title: title, body: body })
    }
    backToList()
  }

  function backToList() {
    mode = "list"
    confirmDeleteId = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function requestDelete(id) {
    if (confirmDeleteId !== id) {
      confirmDeleteId = id
      confirmTimer.restart()
      return
    }
    confirmDeleteId = ""
    items = items.filter(function(i) { return i.id !== id }) // optimistic
    deleteProc.command = [snipBinary, "delete", id]
    deleteProc.running = true
    if (mode === "edit" && editId === id) backToList()
  }

  // ---- processes ----------------------------------------------------------

  Process {
    id: listProc
    property bool pending: false
    command: [root.snipBinary, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.items = JSON.parse(String(text || "[]"))
          root.loadError = ""
        } catch (e) {
          root.loadError = "Could not read snippets"
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.loadError = String(text).trim()
    }
    onExited: function(code) {
      if (code !== 0 && root.loadError === "") root.loadError = "snip list failed (" + root.snipBinary + ")"
      if (pending) {
        pending = false
        running = true
      }
    }
  }

  // Saves are queued so a quick edit-then-edit never races two writers.
  property var saveQueue: []

  function runSave(request) {
    saveQueue = saveQueue.concat([JSON.stringify(request)])
    if (!saveProc.running) startNextSave()
  }

  function startNextSave() {
    if (saveQueue.length === 0) return
    saveProc.payload = saveQueue[0]
    saveQueue = saveQueue.slice(1)
    saveProc.command = [snipBinary, "save"]
    saveProc.running = true
  }

  Process {
    id: saveProc
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    onExited: function(code) {
      if (code !== 0) root.loadError = "Saving failed"
      root.refresh()
      root.startNextSave()
    }
  }

  Process {
    id: deleteProc
    onExited: root.refresh()
  }

  // The CLI touches this file after every write, including captures from the
  // double-Shift daemon, so an open panel picks up new items immediately.
  FileView {
    path: root.stateHome + "/snippets/changed"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      root.refresh()
    }
  }

  Timer {
    id: confirmTimer
    interval: 2500
    onTriggered: root.confirmDeleteId = ""
  }

  // ---- UI -----------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: root.mode === "edit" ? bodyArea : searchField
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(Style.space(520))

    // ---------------- list view ----------------
    ColumnLayout {
      anchors.fill: parent
      visible: root.mode === "list"
      spacing: Style.space(12)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        TextField {
          id: searchField
          Layout.fillWidth: true
          placeholderText: "Search snippets"
          foreground: root.fg
          leftPadding: Style.space(32)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(11)
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF0349) // nf-md-magnify
            color: searchField.activeFocus ? Color.accent : root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }
          onTextChanged: {
            root.query = text
            root.cursor = 0
          }

          Keys.onPressed: function(event) {
            var ctrl = event.modifiers & Qt.ControlModifier
            if (event.key === Qt.Key_Escape) {
              if (text !== "") text = ""
              else root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) {
              root.cursor = Math.min(root.cursor + 1, root.filtered.length - 1)
              list.positionViewAtIndex(root.cursor, ListView.Contain)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
              root.cursor = Math.max(root.cursor - 1, 0)
              list.positionViewAtIndex(root.cursor, ListView.Contain)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.filtered.length > 0) root.startEdit(root.filtered[root.cursor])
              event.accepted = true
            } else if (ctrl && event.key === Qt.Key_N) {
              root.startEdit(null)
              event.accepted = true
            } else if (ctrl && (event.key === Qt.Key_D || event.key === Qt.Key_Delete)) {
              if (root.filtered.length > 0) root.requestDelete(root.filtered[root.cursor].id)
              event.accepted = true
            }
          }
        }

        Button {
          iconText: String.fromCodePoint(0xF0415) // nf-md-plus
          foreground: Color.accent
          bordered: true
          tooltipText: "New snippet (Ctrl+N)"
          Layout.preferredHeight: searchField.height
          Layout.preferredWidth: searchField.height
          onClicked: root.startEdit(null)
        }
      }

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(4)
        boundsBehavior: Flickable.StopAtBounds
        model: root.filtered
        currentIndex: root.cursor

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool current: index === root.cursor
          readonly property bool confirming: root.confirmDeleteId === modelData.id

          width: ListView.view.width - Style.space(6)
          implicitHeight: rowColumn.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: current ? root.cursorFill
            : rowHover.hovered ? Style.hoverFillFor(root.fg, Color.accent)
            : "transparent"

          HoverHandler { id: rowHover }

          // Accent bar marks the keyboard cursor.
          Rectangle {
            visible: row.current
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: Style.space(8)
            anchors.bottomMargin: Style.space(8)
            width: Style.space(2)
            radius: width / 2
            color: Color.accent
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.cursor = row.index
              root.startEdit(row.modelData)
            }
          }

          ColumnLayout {
            id: rowColumn
            anchors.left: parent.left
            anchors.right: actions.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(4)

            // Untitled captures read best as the text itself, wrapped.
            Text {
              readonly property bool titled: row.modelData.title !== ""
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: titled ? row.modelData.title : root.displayTitle(row.modelData)
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: titled ? Style.font.subtitle : Style.font.body
              font.bold: titled
              wrapMode: titled ? Text.NoWrap : Text.Wrap
              elide: Text.ElideRight
              maximumLineCount: titled ? 1 : 2
            }

            Text {
              Layout.fillWidth: true
              visible: text !== ""
              textFormat: Text.PlainText
              text: root.previewText(row.modelData)
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              elide: Text.ElideRight
              maximumLineCount: 2
            }
          }

          // Date by default; edit/delete actions on hover or keyboard cursor.
          Item {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(dateLabel.implicitWidth, actionRow.implicitWidth)
            height: actionRow.implicitHeight

            Text {
              id: dateLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: !actionRow.visible
              textFormat: Text.PlainText
              text: root.formatDate(row.modelData.created)
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              id: actionRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: rowHover.hovered || row.confirming
              spacing: Style.space(2)

              Button {
                iconText: String.fromCodePoint(0xF03EB) // nf-md-pencil
                foreground: root.muted
                tooltipText: "Edit"
                onClicked: root.startEdit(row.modelData)
              }
              Button {
                text: row.confirming ? "Delete?" : ""
                iconText: row.confirming ? "" : String.fromCodePoint(0xF01B4) // nf-md-delete
                foreground: row.confirming ? Color.urgent : root.muted
                background: row.confirming ? Util.alpha(Color.urgent, 0.15) : "transparent"
                tooltipText: row.confirming ? "" : "Delete"
                onClicked: root.requestDelete(row.modelData.id)
              }
            }
          }
        }

        Text {
          anchors.centerIn: parent
          width: parent.width - Style.space(40)
          visible: list.count === 0
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          text: root.loadError !== "" ? root.loadError
            : root.query !== "" ? "No snippets match “" + root.query + "”"
            : "No snippets yet.\nSelect text anywhere and tap Shift twice,\nor press + to write one."
        }
      }

      PanelSeparator {
        Layout.fillWidth: true
        foreground: root.fg
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: -Style.space(4)
        spacing: Style.space(12)

        Text {
          textFormat: Text.PlainText
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          text: (root.query !== "" ? root.filtered.length + " of " : "") + root.items.length
            + (root.items.length === 1 ? " snippet" : " snippets")
        }

        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          color: root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideLeft
          text: "⇧⇧ capture   ↵ edit   ^N new   ^D delete"
        }
      }
    }

    // ---------------- editor ----------------
    ColumnLayout {
      id: editor
      anchors.fill: parent
      visible: root.mode === "edit"
      spacing: Style.space(12)

      function editorKeys(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        if (event.key === Qt.Key_Escape) {
          root.commitEdit()
          event.accepted = true
        } else if (ctrl && (event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          root.commitEdit()
          event.accepted = true
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Button {
          iconText: String.fromCodePoint(0xF004D) // nf-md-arrow_left
          tooltipText: "Back (Esc saves)"
          onClicked: root.commitEdit()
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.editId === "" ? "New snippet" : "Edit snippet"
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          visible: root.editCreated !== ""
          text: {
            var d = new Date(root.editCreated)
            return isNaN(d.getTime()) ? "" : Qt.formatDateTime(d, "d MMM yyyy, HH:mm")
          }
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      TextField {
        id: titleField
        Layout.fillWidth: true
        placeholderText: "Title (optional)"
        foreground: root.fg
        font.bold: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ControlModifier) root.commitEdit()
            else bodyArea.forceActiveFocus()
            event.accepted = true
            return
          }
          editor.editorKeys(event)
        }
      }

      ScrollView {
        id: bodyScroll
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        TextArea {
          id: bodyArea
          readonly property var borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"), root.fg, Color.accent)

          wrapMode: TextEdit.Wrap
          placeholderText: "Snippet text"
          placeholderTextColor: root.muted
          color: root.fg
          selectionColor: Style.selectionFillFor(root.fg, Color.accent)
          selectedTextColor: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          leftPadding: Style.spacing.controlPaddingX + Border.left(borderSpec)
          rightPadding: Style.spacing.controlPaddingX + Border.right(borderSpec)
          topPadding: Style.spacing.inputPaddingY + Border.top(borderSpec) + Style.space(2)
          bottomPadding: Style.spacing.inputPaddingY + Border.bottom(borderSpec) + Style.space(2)

          background: BorderSurface {
            color: Style.controlFill(bodyArea.activeFocus, bodyArea.hovered, root.fg, Color.accent)
            borderSpec: bodyArea.borderSpec
            radius: Style.cornerRadius
          }

          Keys.onPressed: function(event) { editor.editorKeys(event) }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Button {
          visible: root.editId !== ""
          readonly property bool confirming: root.confirmDeleteId === root.editId
          text: confirming ? "Really delete?" : "Delete"
          foreground: Color.urgent
          background: confirming ? Util.alpha(Color.urgent, 0.15) : "transparent"
          bordered: true
          onClicked: root.requestDelete(root.editId)
        }

        Item { Layout.fillWidth: true }

        Text {
          textFormat: Text.PlainText
          text: "^S save"
          color: root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Button {
          text: "Cancel"
          bordered: true
          onClicked: root.backToList()
        }

        Button {
          text: "Save"
          foreground: Color.accent
          bordered: true
          selected: true
          onClicked: root.commitEdit()
        }
      }
    }
  }
}
