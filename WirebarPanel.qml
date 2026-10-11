import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Wirebar: WireGuard manager for the Omarchy bar.
//
// Tunnels are NetworkManager profiles, so everything runs unprivileged through
// nmcli (see backend.sh). NetworkManager does not report the last handshake
// time — that needs `wg show` as root — so health is shown as live throughput
// and, optionally, ping through the tunnel.
//
// Click map (same as the other Omarchy widgets):
//   left   open the panel        right  quick connect / disconnect
//   middle refresh
//
// Ideas borrowed from glafeara/omarchy-wireguard and VirtualDataPro/omarchy-wireguard
// (both MIT) — see CREDITS.md.
Panel {
  id: root
  manageIpc: false

  // ---- tunnel state ----------------------------------------------------
  property var tunnels: []            // [{ name, device, active, lastUsed }]
  property string selectedName: ""
  property var detail: ({})           // parsed `nmcli connection show` for the selection
  property string status: ""
  property bool statusIsError: false
  property bool busy: false
  property var prevActive: ({})       // name -> true, for "dropped behind your back" notices
  property var expectedDown: ({})     // name -> timestamp of a drop we caused ourselves

  // ---- inline forms ----------------------------------------------------
  property string mode: ""            // "" | "name" | "rename" | "edit" | "qr" | "delete"
  property string pendingPath: ""     // config file waiting for a name
  property bool pendingIsTemp: false  // pendingPath is a clipboard dump we must delete
  property string qrPath: ""

  // ---- live numbers (sampled only while the panel is open) --------------
  property var samples: []            // [{ t, rx, tx, down, up }], newest last
  property var pingHistory: []        // ms per probe, -1 for a lost one

  readonly property string backend: decodeURIComponent(Qt.resolvedUrl("backend.sh").toString().replace("file://", ""))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property string wanted: String(setting("connection", ""))
  readonly property var current: pickCurrent()
  readonly property bool connected: current !== null && current.active
  readonly property var quick: quickTarget()
  readonly property bool anyActive: quick !== null && quick.active
  readonly property var peers: parsePeers(detail["wireguard.peers"])
  readonly property var latest: samples.length > 0 ? samples[samples.length - 1] : null

  // ---- parsing ---------------------------------------------------------

  function cleanName(s) { return String(s).replace(/\\:/g, ":").replace(/\\\\/g, "\\") }

  function parseList(text) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      // name:type:device:timestamp, with ':' inside values escaped as '\:'
      var m = lines[i].match(/^(.*):wireguard:([^:]*):(\d*)$/)
      if (m) out.push({ name: cleanName(m[1]), device: m[2], active: m[2] !== "", lastUsed: Number(m[3] || 0) })
    }
    // What is up comes first, then alphabetical.
    out.sort(function(a, b) {
      if (a.active !== b.active) return a.active ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    notifyDrops(out)
    tunnels = out
  }

  // A tunnel that was up and is not, and that we did not take down, was dropped
  // by something else (nmcli in a terminal, a NetworkManager restart, ...).
  function notifyDrops(next) {
    var now = Date.now()
    var live = {}
    for (var i = 0; i < next.length; i++) if (next[i].active) live[next[i].name] = true
    for (var name in prevActive) {
      if (live[name]) continue
      var ours = expectedDown[name] !== undefined && now - expectedDown[name] < 20000
      if (!ours) Quickshell.execDetached(["omarchy-notification-send", "WireGuard: " + name + " disconnected", "The tunnel went down outside Wirebar."])
    }
    prevActive = live
  }

  function expectDown(name) {
    var e = expectedDown
    e[name] = Date.now()
    expectedDown = e
  }

  function pickCurrent() {
    if (tunnels.length === 0) return null
    var i
    for (i = 0; i < tunnels.length; i++)
      if (tunnels[i].name === selectedName) return tunnels[i]
    return quickTarget()
  }

  // What a right-click acts on: the live tunnel if there is one, otherwise the
  // favorite (the `connection` setting), otherwise the most recently used one.
  function quickTarget() {
    if (tunnels.length === 0) return null
    var i
    for (i = 0; i < tunnels.length; i++)
      if (tunnels[i].active) return tunnels[i]
    for (i = 0; i < tunnels.length; i++)
      if (wanted !== "" && tunnels[i].name === wanted) return tunnels[i]
    var best = tunnels[0]
    for (i = 1; i < tunnels.length; i++)
      if (tunnels[i].lastUsed > best.lastUsed) best = tunnels[i]
    return best
  }

  function parseDetail(text) {
    var out = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i].indexOf(":")
      if (at > 0) out[lines[i].slice(0, at)] = lines[i].slice(at + 1).replace(/\\:/g, ":")
    }
    detail = out
  }

  // NetworkManager: "<key> allowed-ips=a;b endpoint=h:p persistent-keepalive=25, <key> ..."
  function parsePeers(raw) {
    var out = []
    var parts = String(raw || "").split(/,\s+/)
    for (var i = 0; i < parts.length; i++) {
      var tokens = parts[i].trim().split(/\s+/)
      if (tokens[0] === "") continue
      var peer = { key: tokens[0], allowedIps: "", endpoint: "", keepalive: "" }
      for (var j = 1; j < tokens.length; j++) {
        var eq = tokens[j].indexOf("=")
        if (eq < 0) continue
        var k = tokens[j].slice(0, eq)
        var v = tokens[j].slice(eq + 1)
        if (k === "allowed-ips") peer.allowedIps = v.split(/[;,]/).join(", ")
        else if (k === "endpoint") peer.endpoint = v
        else if (k === "persistent-keepalive") peer.keepalive = v
      }
      out.push(peer)
    }
    return out
  }

  // ---- formatting ------------------------------------------------------

  function formatBytes(n) {
    if (n < 0) return ""
    var units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var u = 0
    while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
    return (u === 0 ? n.toFixed(0) : n.toFixed(2)) + " " + units[u]
  }

  function formatRate(v) {
    if (v >= 1048576) return (v / 1048576).toFixed(1) + " MiB/s"
    if (v >= 1024) return (v / 1024).toFixed(1) + " KiB/s"
    return Math.round(v) + " B/s"
  }

  function join(a, b) { return a !== "" && b !== "" ? a + ", " + b : a + b }
  function addresses() { return join(String(detail["ipv4.addresses"] || ""), String(detail["ipv6.addresses"] || "")) }
  function dnsServers() { return join(String(detail["ipv4.dns"] || ""), String(detail["ipv6.dns"] || "")) }

  // "US-New York 03.conf" -> "US-New-York-03" (interface names are 15 chars of [A-Za-z0-9_=+.-])
  function suggestName(path) {
    var base = String(path).split("/").pop().replace(/\.conf$/i, "")
    return base.replace(/[^A-Za-z0-9_=+.-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 15)
  }

  function peakRate() {
    var peak = 0
    for (var i = 0; i < samples.length; i++) peak = Math.max(peak, samples[i].down, samples[i].up)
    return peak
  }

  // ---- ping target: pingHost, else the tunnel's DNS, else a host inside its first AllowedIPs ----
  function pingTarget() {
    var custom = String(setting("pingHost", "")).trim()
    if (custom !== "") return custom
    var dns = String(detail["ipv4.dns"] || "").split(",")[0].trim()
    if (dns !== "") return dns
    if (peers.length === 0) return ""
    var first = peers[0].allowedIps.split(",")[0].trim()
    var m = first.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)\/(\d+)$/)
    if (!m) return ""
    var bits = Number(m[5])
    if (bits === 0) return "1.1.1.1"
    if (bits === 32) return m[1] + "." + m[2] + "." + m[3] + "." + m[4]
    if (m[4] === "0") return m[1] + "." + m[2] + "." + m[3] + ".1"
    return ""
  }

  function pingSummary() {
    var h = pingHistory
    if (h.length === 0) return ""
    var ok = h.filter(function(v) { return v >= 0 })
    var loss = Math.round(100 * (h.length - ok.length) / h.length)
    if (ok.length === 0) return "no reply (" + loss + "% loss)"
    return ok[ok.length - 1].toFixed(0) + " ms · " + loss + "% loss"
  }

  function nameValid() {
    var t = nameField.text.trim()
    if (mode === "rename") return t !== "" && t.indexOf(":") < 0
    return /^[A-Za-z0-9_=+.-]{1,15}$/.test(t)
  }

  // ---- actions ---------------------------------------------------------

  function say(text, isError) {
    status = text
    statusIsError = isError === true
  }

  function copyText(label, value) {
    if (value === "") return
    Quickshell.execDetached(["wl-copy", value])
    say("Copied " + label, false)
  }

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  function refreshDetail() {
    if (!current || detailProcess.running) return
    detailProcess.command = ["nmcli", "-t", "connection", "show", "id", current.name]
    detailProcess.running = true
  }

  function sample() {
    if (!current || !current.active || current.device === "" || statsProcess.running) return
    statsProcess.command = ["sh", "-c", "cat /sys/class/net/\"$1\"/statistics/rx_bytes /sys/class/net/\"$1\"/statistics/tx_bytes", "sh", current.device]
    statsProcess.running = true
  }

  function probe() {
    var target = pingTarget()
    if (!current || !current.active || current.device === "" || target === "" || pingProcess.running) return
    pingProcess.command = ["ping", "-c", "1", "-W", "1", "-I", current.device, target]
    pingProcess.running = true
  }

  function runBackend(args, afterOk) {
    if (actionProcess.running) return
    busy = true
    say("", false)
    actionProcess.afterOk = afterOk || null
    actionProcess.command = ["bash", backend].concat(args)
    actionProcess.running = true
  }

  function toggleTunnel(t) {
    if (!t) return
    if (t.active) {
      expectDown(t.name)
      runBackend(["down", t.name])
    } else {
      for (var i = 0; i < tunnels.length; i++) if (tunnels[i].active) expectDown(tunnels[i].name)
      runBackend(["switch", t.name])
    }
  }

  // Right-click on the bar icon: connect the favorite / last used tunnel, or drop the live one.
  function quickToggle() {
    var t = quickTarget()
    if (!t) { open(); return }   // nothing to connect yet: show the panel so one can be added
    toggleTunnel(t)
  }

  // The favorite is the widget's `connection` setting. Settings can only be
  // written through the shell, so go through `omarchy bar set`.
  function setFavorite(name) {
    if (favoriteProcess.running) return
    favoriteProcess.command = ["omarchy", "bar", "set", "tzv.wirebar", "connection", name]
    favoriteProcess.running = true
  }
  function toggleFavorite(name) { setFavorite(wanted === name ? "" : name) }

  function selectRelative(step) {
    if (tunnels.length === 0) return
    var at = 0
    for (var i = 0; i < tunnels.length; i++) if (current && tunnels[i].name === current.name) at = i
    selectedName = tunnels[(at + step + tunnels.length) % tunnels.length].name
    cancelForm()
  }

  // ---- forms -----------------------------------------------------------

  function backendQuiet(args) { Quickshell.execDetached(["bash", backend].concat(args)) }

  function cancelForm() {
    if (mode === "qr") backendQuiet(["qr-clean"])
    if (pendingIsTemp && pendingPath !== "") Quickshell.execDetached(["rm", "-f", pendingPath])
    pendingPath = ""
    pendingIsTemp = false
    qrPath = ""
    mode = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openForm(which) {
    if (which !== "name" && !current) return
    mode = which
    if (which === "rename") nameField.text = current.name
    Qt.callLater(function() {
      var f = which === "edit" ? addrField : (which === "name" || which === "rename") ? nameField : null
      if (f) { f.forceActiveFocus(); f.selectAll() }
    })
  }

  function addTunnel() {
    if (pickerProcess.running || actionProcess.running) return
    say("Choose a WireGuard .conf file…", false)
    pickerProcess.running = true
  }

  function pasteTunnel() {
    if (clipProcess.running || actionProcess.running) return
    say("Reading the clipboard…", false)
    clipProcess.running = true
  }

  function submitName() {
    var name = nameField.text.trim()
    if (mode === "name") {
      var path = pendingPath
      var temp = pendingIsTemp
      pendingPath = ""
      pendingIsTemp = false
      mode = ""
      if (temp) clipCleanup.path = path
      runBackend(["import", path, name], function() { selectedName = name })
    } else if (mode === "rename") {
      var old = current ? current.name : ""
      mode = ""
      if (old !== "" && name !== old) {
        var wasFavorite = wanted === old
        runBackend(["rename", old, name], function() {
          selectedName = name
          if (wasFavorite) setFavorite(name)
        })
      }
    }
  }

  function submitEdit() {
    if (!current) return
    var name = current.name
    mode = ""
    runBackend(["modify", name, addrField.text, dnsField.text, mtuField.text])
  }

  // Open one of the inline forms directly (used by the `form` IPC command).
  function showForm(which) {
    if (which === "qr") showQr()
    else if (which === "delete") { if (current) mode = "delete" }
    else if (which === "name") {
      pendingPath = ""
      pendingIsTemp = false
      nameField.text = "branch-office"
      openForm("name")
    } else openForm(which)   // "rename" | "edit"
  }

  function showQr() {
    if (!current || actionProcess.running) return
    mode = "qr"
    qrPath = ""
    qrProcess.command = ["bash", backend, "qr", current.name]
    qrProcess.running = true
  }

  function deleteTunnel() {
    if (!current) return
    var name = current.name
    if (name === wanted) setFavorite("")
    mode = ""
    selectedName = ""
    expectDown(name)
    runBackend(["delete", name])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  onCurrentChanged: {
    detail = ({})
    samples = []
    pingHistory = []
    refreshDetail()
    sample()
  }
  onOpenedChanged: {
    if (opened) {
      say("", false)   // never show a message left over from the last time it was open
      refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      cancelForm()
      samples = []
      pingHistory = []
    }
  }

  // omarchy-shell wirebar form <name|rename|edit|qr|delete>
  // Opens the panel on one of its inline forms: handy for keybindings and screenshots.
  IpcHandler {
    target: "wirebar"
    function form(which: string): string {
      if (["name", "rename", "edit", "qr", "delete"].indexOf(which) < 0) return "unknown form: " + which
      root.open()
      Qt.callLater(function() { root.showForm(which) })
      return "ok"
    }
  }

  Timer {
    interval: Math.max(2, Number(root.setting("refreshIntervalSec", 10))) * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    running: root.opened && root.connected
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }

  Timer {
    interval: 3000
    running: root.opened && root.connected
    repeat: true
    triggeredOnStart: true
    onTriggered: root.probe()
  }

  // ---- processes -------------------------------------------------------

  Process {
    id: listProcess
    command: ["nmcli", "-t", "-f", "NAME,TYPE,DEVICE,TIMESTAMP", "connection", "show"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { root.parseList(text); root.refreshDetail() } }
  }

  Process {
    id: detailProcess
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseDetail(text) }
  }

  Process {
    id: statsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = String(text || "").trim().split("\n")
        if (n.length < 2 || n[0] === "") return
        var now = Date.now() / 1000
        var rx = Number(n[0]), tx = Number(n[1])
        var prev = root.latest
        var dt = prev ? now - prev.t : 0
        var ok = prev && dt > 0 && dt < 15 && rx >= prev.rx && tx >= prev.tx
        var next = root.samples.slice(-29)
        next.push({ t: now, rx: rx, tx: tx, down: ok ? (rx - prev.rx) / dt : 0, up: ok ? (tx - prev.tx) / dt : 0 })
        root.samples = next
      }
    }
  }

  Process {
    id: pingProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").match(/time=([\d.]+) ms/)
        var h = root.pingHistory.slice(-9)
        h.push(m ? Number(m[1]) : -1)
        root.pingHistory = h
      }
    }
  }

  Process {
    id: pickerProcess
    command: ["omarchy-file-select", "--title", "Import WireGuard tunnel", "--extensions", "conf"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim().split("\n")[0]
        root.say("", false)
        if (path === "") return
        root.pendingPath = path
        root.pendingIsTemp = false
        nameField.text = root.suggestName(path)
        root.openForm("name")
      }
    }
  }

  // Clipboard -> a private temp file, so the backend can validate it like any other import.
  Process {
    id: clipProcess
    command: ["sh", "-c", "umask 077; f=\"${XDG_RUNTIME_DIR:-/tmp}/wirebar-clip-$$.conf\"; if wl-paste --no-newline >\"$f\" 2>/dev/null && [ -s \"$f\" ]; then printf '%s' \"$f\"; else rm -f \"$f\"; exit 1; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path === "") return
        root.say("", false)
        root.pendingPath = path
        root.pendingIsTemp = true
        nameField.text = "wireguard"
        root.openForm("name")
      }
    }
    onExited: function(code) { if (code !== 0) root.say("The clipboard is empty or does not hold text", true) }
  }

  QtObject { id: clipCleanup; property string path: "" }

  Process {
    id: qrProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.qrPath = String(text || "").trim()
    }
    stderr: StdioCollector { id: qrErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) { root.mode = ""; root.say(String(qrErr.text || "Could not make the QR code").trim(), true) }
    }
  }

  Process {
    id: favoriteProcess
    stderr: StdioCollector { id: favoriteErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.say(String(favoriteErr.text || "Could not save favorite").trim(), true)
    }
  }

  Process {
    id: actionProcess
    property var afterOk: null
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode === 0) {
        root.say(String(actionOut.text || "").trim(), false)
        if (afterOk) afterOk()
      } else {
        root.say(String(actionErr.text || actionOut.text || "Command failed").trim(), true)
      }
      afterOk = null
      if (clipCleanup.path !== "") { Quickshell.execDetached(["rm", "-f", clipCleanup.path]); clipCleanup.path = "" }
      root.refresh()
    }
  }

  // ---- bar icon --------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    useActiveColor: false
    foreground: root.anyActive ? root.barForeground : Qt.darker(root.barForeground, 1.6)
    tooltipText: !root.quick ? "Wirebar: no tunnels — click to add one"
      : root.busy ? "Wirebar: working…"
      : root.anyActive ? "Wirebar " + root.quick.name + ": connected (right-click to disconnect)"
      : "Wirebar: right-click to connect " + root.quick.name

    onPressed: function(b) {
      if (b === Qt.RightButton) root.quickToggle()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---- panel -----------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.mode !== "" && root.mode !== "delete"
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.selectRelative(dy > 0 ? 1 : -1) }
      onCloseRequested: root.mode !== "" ? root.cancelForm() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.current) root.mode = "delete"
      onReturnRequested: if (root.mode === "delete") root.deleteTunnel()
      onTextKey: function(t) {
        if (root.mode !== "") return
        if (t === "t" || t === "T") root.toggleTunnel(root.current)
        else if (t === "a" || t === "A") root.addTunnel()
        else if (t === "v" || t === "V") root.pasteTunnel()
        else if (t === "n" || t === "N") root.openForm("rename")
        else if (t === "e" || t === "E") root.openForm("edit")
        else if (t === "q" || t === "Q") root.showQr()
        else if (t === "r" || t === "R") root.refresh()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.current ? root.current.name : "Wirebar"
            meta: !root.current ? "No tunnels yet — add one below"
              : root.busy ? "Working…"
              : root.connected ? "Active" : "Inactive"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰖂"
                color: root.connected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                visible: root.current !== null
                checked: root.connected
                busy: root.busy
                foreground: hero.foreground
                onToggled: root.toggleTunnel(root.current)
              }
            }
          }

          Text {
            visible: root.status !== ""
            width: parent.width
            text: root.status
            textFormat: Text.PlainText
            color: root.statusIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // ---- tunnel list ----
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "TUNNELS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Text {
              visible: root.tunnels.length === 0
              width: parent.width
              text: "No WireGuard tunnels found. Use “Add tunnel” to import a .conf file, or “Paste” to import one from the clipboard."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.tunnels.length > 1
              width: parent.width
              text: root.wanted !== "" ? "★ marks the tunnel a right-click on the bar icon connects."
                                       : "Right-click on the bar icon connects the last-used tunnel. Star one to pin it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.tunnels
              CursorSurface {
                id: row
                required property var modelData
                readonly property bool isCurrent: root.current !== null && root.current.name === modelData.name
                width: parent.width
                implicitHeight: rowInner.implicitHeight + Style.spacing.xl
                current: isCurrent
                foreground: root.foreground
                fill: root.hoverFill
                currentFill: root.selectedFill

                Row {
                  id: rowInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Text {
                    text: row.modelData.active ? "󰒃" : "󰦞"
                    color: row.modelData.active ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: Style.space(22)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: row.modelData.name
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: row.isCurrent
                    elide: Text.ElideRight
                    width: parent.width - Style.space(22) - Style.space(8) - Style.space(30)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.selectedName = row.modelData.name; root.cancelForm() }
                }

                Item {
                  id: star
                  readonly property bool onlyTunnel: root.tunnels.length === 1
                  readonly property bool favorite: onlyTunnel || root.wanted === row.modelData.name
                  width: Style.space(26)
                  height: Style.space(26)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  z: 2

                  Text {
                    anchors.centerIn: parent
                    text: star.favorite ? "★" : "☆"
                    color: star.favorite ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                  MouseArea {
                    id: starMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!star.onlyTunnel) root.toggleFavorite(row.modelData.name)
                  }
                  PanelToolTip {
                    visible: starMouse.containsMouse
                    text: star.onlyTunnel ? "Your only tunnel, so right-click always connects it"
                        : star.favorite ? "Favorite: right-click on the bar icon connects this tunnel. Click to unset."
                        : "Make this the right-click quick-connect tunnel"
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }

          PanelSeparator { visible: root.current !== null; foreground: root.foreground }

          // ---- interface ----
          Column {
            visible: root.current !== null
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "INTERFACE"; foreground: root.foreground; fontFamily: root.fontFamily }

            DetailRow { label: "Status"; value: root.connected ? "Active" : "Inactive"; copyable: false }
            DetailRow { label: "Interface"; value: String(root.detail["connection.interface-name"] || "") }
            DetailRow { label: "Addresses"; value: root.addresses() }
            DetailRow { label: "DNS servers"; value: root.dnsServers() }
            DetailRow { label: "MTU"; value: { var m = String(root.detail["wireguard.mtu"] || ""); return m === "0" ? "" : m } }
            DetailRow { label: "Listen port"; value: { var p = String(root.detail["wireguard.listen-port"] || ""); return p === "0" ? "" : p } }
          }

          Repeater {
            model: root.current ? root.peers : []
            Column {
              id: peerCol
              required property var modelData
              required property int index
              width: column.width
              spacing: Style.space(6)

              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: root.peers.length > 1 ? "PEER " + (peerCol.index + 1) : "PEER"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              DetailRow { label: "Public key"; value: peerCol.modelData.key }
              DetailRow { label: "Allowed IPs"; value: peerCol.modelData.allowedIps }
              DetailRow { label: "Endpoint"; value: peerCol.modelData.endpoint }
              DetailRow { label: "Keepalive"; value: peerCol.modelData.keepalive !== "" ? peerCol.modelData.keepalive + " s" : ""; copyable: false }
            }
          }

          // ---- live traffic ----
          Column {
            visible: root.connected && root.latest !== null
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "TRAFFIC"; foreground: root.foreground; fontFamily: root.fontFamily }

            Row {
              width: parent.width
              Text {
                width: parent.width / 2
                text: "↓ " + root.formatRate(root.latest ? root.latest.down : 0)
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width / 2
                horizontalAlignment: Text.AlignRight
                text: "↑ " + root.formatRate(root.latest ? root.latest.up : 0)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Canvas {
              id: graph
              width: parent.width
              height: Style.space(90)
              property var data: root.samples
              property color downColor: Color.accent
              property color upColor: root.foreground
              onDataChanged: requestPaint()
              onDownColorChanged: requestPaint()
              onUpColorChanged: requestPaint()
              onWidthChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var max = 1024
                for (var i = 0; i < data.length; i++) max = Math.max(max, data[i].down, data[i].up)
                ctx.lineWidth = 1
                ctx.strokeStyle = Qt.rgba(upColor.r, upColor.g, upColor.b, 0.12)
                for (var g = 0; g < 3; g++) {
                  var gy = 4 + (height - 8) * g / 2
                  ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(width, gy); ctx.stroke()
                }
                function line(key, color) {
                  ctx.strokeStyle = color
                  ctx.lineWidth = 2
                  ctx.beginPath()
                  for (var k = 0; k < data.length; k++) {
                    var x = width * (30 - data.length + k) / 29
                    var y = height - 4 - (height - 8) * data[k][key] / max
                    if (k === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                  }
                  ctx.stroke()
                }
                line("down", downColor)
                line("up", upColor)
              }
            }

            Text {
              text: "Last minute while the panel is open · peak " + root.formatRate(root.peakRate())
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            DetailRow { label: "Received"; value: root.latest ? root.formatBytes(root.latest.rx) : ""; copyable: false }
            DetailRow { label: "Sent"; value: root.latest ? root.formatBytes(root.latest.tx) : ""; copyable: false }
            DetailRow { label: "Latency"; value: root.pingSummary(); copyable: false }
            Text {
              visible: root.pingTarget() !== "" && root.pingHistory.length > 0
              text: "Ping to " + root.pingTarget() + " through the tunnel. Set pingHost to use another address."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---- inline forms ----
          Column {
            visible: root.mode === "name" || root.mode === "rename"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.mode === "name" ? "IMPORT AS" : "RENAME"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: nameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Tunnel name"
              maximumLength: root.mode === "name" ? 15 : 64
              Keys.onEscapePressed: root.cancelForm()
              onAccepted: if (root.nameValid()) root.submitName()
            }
            Text {
              width: parent.width
              visible: root.mode === "name"
              text: "Up to 15 characters: letters, digits and _ = + . - (this becomes the interface name). Imported tunnels are never connected automatically."
              color: nameField.text !== "" && !root.nameValid() ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: root.mode === "name" ? "Import" : "Save"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.nameValid() && !root.busy
                onClicked: root.submitName()
              }
              Button { text: "Cancel"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.cancelForm() }
            }
          }

          Column {
            visible: root.mode === "edit"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "EDIT " + (root.current ? root.current.name.toUpperCase() : ""); foreground: root.foreground; fontFamily: root.fontFamily }

            Text { text: "Address(es)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            TextField {
              id: addrField
              width: parent.width
              foreground: root.foreground
              placeholderText: "10.0.0.2/32"
              text: root.mode === "edit" ? root.addresses() : ""
              Keys.onEscapePressed: root.cancelForm()
              onAccepted: dnsField.forceActiveFocus()
            }
            Text { text: "DNS servers (comma separated, optional)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            TextField {
              id: dnsField
              width: parent.width
              foreground: root.foreground
              placeholderText: "10.0.0.1"
              text: root.mode === "edit" ? root.dnsServers() : ""
              Keys.onEscapePressed: root.cancelForm()
              onAccepted: mtuField.forceActiveFocus()
            }
            Text { text: "MTU (0 = default)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            TextField {
              id: mtuField
              width: parent.width
              foreground: root.foreground
              placeholderText: "0"
              text: root.mode === "edit" ? String(root.detail["wireguard.mtu"] || "0") : ""
              Keys.onEscapePressed: root.cancelForm()
              onAccepted: root.submitEdit()
            }
            Text {
              width: parent.width
              text: root.connected ? "Reconnect the tunnel for changes to take effect. Peers and keys are not touched." : "Peers and keys are not touched."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(8)
              Button { text: "Save"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.submitEdit() }
              Button { text: "Cancel"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.cancelForm() }
            }
          }

          Column {
            visible: root.mode === "qr"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "QR CODE"; foreground: root.foreground; fontFamily: root.fontFamily }
            Text {
              width: parent.width
              text: "This code contains the tunnel's private key. Scanning it moves the profile to the phone: two devices sharing one key knock each other offline. Close it when you're done."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Rectangle {
              width: Style.space(220)
              height: width
              color: "white"
              anchors.horizontalCenter: parent.horizontalCenter
              Image {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                source: root.qrPath !== "" ? "file://" + root.qrPath : ""
                fillMode: Image.PreserveAspectFit
                smooth: false
                cache: false
              }
            }
            Button { text: "Close"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.cancelForm() }
          }

          Row {
            visible: root.mode === "delete"
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "Delete “" + (root.current ? root.current.name : "") + "”?"
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            Button { text: "Delete"; foreground: root.urgent; fontFamily: root.fontFamily; onClicked: root.deleteTunnel() }
            Button { text: "Cancel"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.cancelForm() }
          }

          // ---- actions ----
          Flow {
            visible: root.mode === ""
            width: parent.width
            spacing: Style.space(8)

            Button { text: "Add tunnel"; iconText: "󰐕"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.addTunnel() }
            Button { text: "Paste"; iconText: "󰆒"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.pasteTunnel() }
            Button { visible: root.current !== null; text: "Rename"; iconText: "󰏫"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.openForm("rename") }
            Button { visible: root.current !== null; text: "Edit"; iconText: "󰒓"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.openForm("edit") }
            Button { visible: root.current !== null; text: "QR"; iconText: "󰐲"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.showQr() }
            Button { visible: root.current !== null; text: "Delete"; iconText: "󰆴"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !root.busy; onClicked: root.mode = "delete" }
          }
        }
      }
    }
  }

  component DetailRow: RowLayout {
    id: detailRow
    property string label: ""
    property string value: ""
    property bool copyable: true
    visible: value !== ""
    width: parent ? parent.width : 0
    spacing: Style.space(10)

    Text {
      text: detailRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      Layout.preferredWidth: Style.space(96)
      Layout.alignment: Qt.AlignTop
    }
    Text {
      text: detailRow.value
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WrapAnywhere
      Layout.fillWidth: true

      MouseArea {
        anchors.fill: parent
        enabled: detailRow.copyable
        hoverEnabled: true
        cursorShape: detailRow.copyable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.copyText(detailRow.label.toLowerCase(), detailRow.value)
      }
    }
  }
}
