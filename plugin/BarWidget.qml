import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "mvrcelo.snippets"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for `omarchy-shell shell toggle mvrcelo.snippets '{}'`
  // (the bar looks for open/close/opened on the widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // For keybinds: `omarchy-shell snippets toggle` / `omarchy-shell snippets create`.
  // One bar per monitor means one handler per monitor; Quickshell keeps the
  // first, which is fine since every instance drives the same files.
  IpcHandler {
    target: "snippets"
    function toggle(): void { if (panelLoader.item) panelLoader.item.toggle() }
    function create(): void { if (panelLoader.item) panelLoader.item.openNew() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF014C) // nf-md-clipboard_text
    slotSize: Style.bar.statusSlot
    tooltipText: ""

    onPressed: function(b) {
      if (!panelLoader.item) return
      if (b === Qt.LeftButton) panelLoader.item.toggle()
      else if (b === Qt.RightButton) panelLoader.item.openNew()
    }
  }
}
