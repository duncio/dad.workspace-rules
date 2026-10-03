import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Bar widget that manages "always open on workspace" rules.
// New windows of a listed app are moved to its assigned workspace the
// moment they open; already-open windows are relocated whenever rules
// change or the shell (re)loads. Rules persist in rules.json next to
// this plugin via scripts/workspace-rules.
Panel {
  id: root
  moduleName: "dad.workspace-rules"
  ipcTarget: "dad.workspace-rules"

  implicitWidth: bar ? (bar.vertical ? bar.barSize : button.implicitWidth) : button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string scriptDir: pluginDir + "/scripts"

  property var rules: []
  property var appOptions: []
  property string selectedApp: ""
  property string selectedWorkspace: "3"

  readonly property int ruleRowHeight: Style.space(32)

  // ── app list ──────────────────────────────────────────────────────────────
  function classForDesktopEntry(entry) {
    var startup = String(entry.startupClass || "").trim()
    if (startup.length > 0 && startup.indexOf("@@") !== 0) return startup.toLowerCase()
    var cmd = entry.command
    if (cmd && cmd.length > 0) {
      var first = String(cmd[0] || "").trim()
      if (first.length > 0) {
        var base = first.split("/").pop().split(" ")[0]
        if (base.length > 0) return base.toLowerCase()
      }
    }
    return ""
  }

  function normalizedRule(rule) {
    var cls = String(rule.class || "").trim().toLowerCase()
    var opt = root.optionByValue(String(rule.appId || ""))
    if (opt && opt.className && (cls === "" || cls.indexOf("@@") === 0)) cls = opt.className
    if (!cls) return null
    return {
      appId: String(rule.appId),
      label: String(rule.label || rule.appId || ""),
      class: cls,
      workspace: Number(rule.workspace) || 1
    }
  }

  function buildAppOptions() {
    var out = []
    var apps = DesktopEntries.applications.values
    for (var i = 0; i < apps.length; i++) {
      var entry = apps[i]
      if (!entry || !entry.id) continue
      out.push({
        label: String(entry.name || entry.id),
        description: String(entry.comment || ""),
        value: String(entry.id),
        className: root.classForDesktopEntry(entry)
      })
    }
    out.sort(function(a, b) { return String(a.label).localeCompare(String(b.label)) })
    root.appOptions = out
  }

  function optionByValue(value) {
    for (var i = 0; i < root.appOptions.length; i++) {
      if (String(root.appOptions[i].value) === String(value)) return root.appOptions[i]
    }
    return null
  }

  readonly property bool selectedAppKnown: root.selectedApp !== ""
  readonly property bool selectedAppNoClass: {
    if (root.selectedApp === "") return false
    var opt = root.optionByValue(root.selectedApp)
    return !opt || opt.className === ""
  }

  // ── script runner (single queued process) ─────────────────────────────────
  property var cmdQueue: []
  property var stdoutHandler: null

  Process {
    id: scriptProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onScriptFinished(String(text || ""))
    }
    onExited: root.nextCmd()
  }

  function runScript(args, handler) {
    root.cmdQueue.push({ args: args, handler: handler })
    if (!scriptProc.running) root.nextCmd()
  }

  function nextCmd() {
    if (scriptProc.running || root.cmdQueue.length === 0) return
    var cmd = root.cmdQueue.shift()
    root.stdoutHandler = cmd.handler
    scriptProc.command = ["python3", root.scriptDir + "/workspace-rules"].concat(cmd.args)
    scriptProc.running = true
  }

  function onScriptFinished(output) {
    var handler = root.stdoutHandler
    root.stdoutHandler = null
    if (handler) handler(output)
    root.nextCmd()
  }

  function refreshRules() {
    root.runScript(["get"], function(json) { root.loadRulesFrom(json) })
  }

  function loadRulesFrom(raw) {
    if (!raw || !String(raw).trim()) return
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { return }
    if (Object.prototype.toString.call(parsed) !== "[object Array]") return
    var out = []
    for (var i = 0; i < parsed.length; i++) {
      var norm = root.normalizedRule(parsed[i])
      if (norm) out.push(norm)
    }
    root.rules = out
    console.info("[wr] loaded", JSON.stringify(root.rules))
    root.applyRules()
  }

  function addRule() {
    var opt = root.optionByValue(root.selectedApp)
    if (!opt) {
      console.warn("workspace-rules: addRule ignored, no option for '" + root.selectedApp + "'")
      return
    }
    if (opt.className === "") {
      console.warn("workspace-rules: addRule ignored, no window class for '" + opt.label + "'")
      return
    }
    root.runScript(["add", opt.value, opt.label, opt.className, String(root.selectedWorkspace)],
      function(json) { root.loadRulesFrom(json) })
  }

  function removeRule(appId) {
    root.runScript(["remove", String(appId)],
      function(json) { root.loadRulesFrom(json) })
  }

  // ── Hyprland enforcement ──────────────────────────────────────────────────
  function ruleForClass(cls) {
    if (!cls) return null
    for (var i = 0; i < root.rules.length; i++) {
      if (String(root.rules[i].class || "") === cls) return root.rules[i]
    }
    return null
  }

  function normalizeAddress(address) {
    var value = String(address || "").trim()
    if (value.length === 0) return ""
    return value.indexOf("0x") === 0 ? value : "0x" + value
  }

  function moveWindow(address, workspace) {
    var addr = root.normalizeAddress(address)
    if (addr.length === 0) return
    Hyprland.dispatch("hl.dsp.window.move({ workspace = " + workspace +
      ", follow = false, window = \"address:" + addr + "\" })")
  }

  function handleClient(client) {
    var cls = String(client.class || client.initialClass || "").toLowerCase()
    var rule = root.ruleForClass(cls)
    if (!rule || !client.address) return
    var current = client.workspace ? Number(client.workspace.id || 0) : 0
    if (current === Number(rule.workspace)) return
    root.moveWindow(String(client.address), rule.workspace)
  }

  function applyClients(raw) {
    if (!raw || !String(raw).trim()) return
    var list
    try { list = JSON.parse(raw) } catch (e) { return }
    for (var i = 0; i < list.length; i++) root.handleClient(list[i])
  }

  function applyRules() {
    if (!clientsProc.running) clientsProc.running = true
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyClients(String(text || ""))
    }
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name === "openwindow") root.handleOpenWindow(String(event.data || ""))
    }
  }

  function handleOpenWindow(data) {
    var parts = data.split(",")
    if (parts.length < 3) return
    var cls = String(parts[2] || "").toLowerCase()
    var rule = root.ruleForClass(cls)
    if (!rule) return
    var current = parseInt(parts[0], 10)
    if (!isFinite(current) || current === Number(rule.workspace)) return
    root.moveWindow(String(parts[1] || ""), rule.workspace)
    sweepTimer.start()
  }

  Timer {
    id: sweepTimer
    interval: 600
    running: false
    repeat: false
    onTriggered: root.applyRules()
  }

  Component.onCompleted: {
    buildAppOptions()
    var opt = root.optionByValue("chromium")
    console.info("[wr] init: chromium className =", opt ? opt.className : "<none>")
    refreshRules()
  }

  Connections {
    target: DesktopEntries
    function onApplicationsChanged() { root.buildAppOptions() }
  }

  // ── bar button ────────────────────────────────────────────────────────────
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf009"
    active: root.opened
    tooltipText: "Workspace Rules"
    onPressed: root.toggle()
  }

  // ── panel ─────────────────────────────────────────────────────────────────
  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(400))
    contentHeight: popup.fittedContentHeight(Math.min(Style.space(620), stack.implicitHeight + Style.space(24)))

    Column {
      id: stack
      anchors.fill: parent
      spacing: Style.space(12)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
text: "\uf009"
          font.pixelSize: Style.font.title
          color: Color.accent
          verticalAlignment: Text.AlignVCenter
        }

        Column {
          width: parent.width - Style.space(48)
          spacing: 1

          Text {
            text: "Workspace Rules"
            font.pixelSize: Style.font.caption
            font.bold: true
            color: Color.popups.text
          }

          Text {
            text: "Always open selected apps on a workspace"
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }
      }

      PanelSeparator {}

      SearchableDropdown {
        label: "App"
        options: root.appOptions
        value: root.selectedApp
        placeholderText: "Choose an app…"
        emptyText: "No matching apps"
        foreground: Color.popups.text
        background: Color.popups.background
        popupBorder: Color.popups.border
        accent: Color.accent
        onChanged: function(v) { root.selectedApp = v }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Dropdown {
          id: workDropdown
          width: parent.width - removeButton.implicitWidth - parent.spacing
          label: "Always open on"
          options: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
          value: root.selectedWorkspace
          foreground: Color.popups.text
          background: Color.popups.background
          popupBorder: Color.popups.border
          accent: Color.accent
          onChanged: function(v) { root.selectedWorkspace = v }
        }

        BorderSurface {
          id: removeButton
          implicitWidth: Style.space(92)
          height: Style.space(28)
          radius: Style.cornerRadius
          color: Color.accent
          borderSpec: Border.controlSpec("normal", Color.accent, Color.accent)

          Text {
            anchors.centerIn: parent
            text: "Add rule"
            font.pixelSize: Style.font.caption
            font.bold: true
            color: Color.popups.background
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addRule()
          }
        }
      }

      Text {
        width: parent.width
        visible: root.selectedAppKnown && root.selectedAppNoClass
        text: "No window class is known for this app, so open windows may not match. Prefer apps that set StartupWMClass."
        font.pixelSize: Style.font.caption - 1
        wrapMode: Text.Wrap
        color: Color.urgent
      }

      PanelSeparator {}

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Rules"
          font.pixelSize: Style.font.caption
          font.bold: true
          color: Color.popups.text
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: String(root.rules.length)
          font.pixelSize: Style.font.caption
          font.bold: true
          color: Color.accent
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Item {
        width: parent.width
        height: root.rules.length > 0
          ? Math.min(root.rules.length * root.ruleRowHeight + Math.max(0, root.rules.length - 1) * Style.space(6), Style.space(210))
          : Style.space(28)

        Text {
          anchors.centerIn: parent
          visible: root.rules.length === 0
          text: "No rules yet — pick an app and workspace above."
          font.pixelSize: Style.font.caption
          color: Color.muted
        }

        ListView {
          id: rulesList
          anchors.fill: parent
          clip: true
          spacing: Style.space(6)
          boundsBehavior: Flickable.StopAtBounds
          model: root.rules

          delegate: BorderSurface {
            required property var modelData
            width: rulesList.width
            height: root.ruleRowHeight
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)

            Text {
              anchors.left: parent.left
              anchors.right: workspaceText.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: parent.borderLeft + Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.md
              text: String(modelData.label || modelData.appId || "")
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              color: Color.popups.text
            }

            Text {
              id: workspaceText
              anchors.right: removeGlyph.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.spacing.md
              text: "→ ws " + String(modelData.workspace)
              font.pixelSize: Style.font.caption
              font.bold: true
              color: Color.accent
            }

            Text {
              id: removeGlyph
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: parent.borderRight + Style.spacing.controlPaddingX
              text: "✕"
              font.pixelSize: Style.font.caption
              color: Color.muted
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.removeRule(String(modelData.appId))
            }
          }
        }
      }

      Text {
        width: parent.width
        text: "New windows of a listed app open directly on its workspace; windows already open move right away. Remove a rule to restore normal placement."
        font.pixelSize: Style.font.caption - 2
        wrapMode: Text.Wrap
        color: Color.muted
      }
    }
  }
}