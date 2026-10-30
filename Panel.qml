import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OpenCode usage in one bar slot: Go allowance windows, today's tokens, the
// last week, and per-model totals. Every number comes from one stdlib Python
// collector run (helpers/collector); this file never touches a session store
// itself, so adding a source means touching one file.
Panel {
  id: root
  moduleName: "io.github.amergrgic.opencode-usage"
  ipcTarget: "io.github.amergrgic.opencode-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string collectorPath: decodeURIComponent(
    Qt.resolvedUrl("helpers/collector").toString().replace(/^file:\/\//, ""))

  // Five named wedges plus "other"; more than that turns a 150px ring into
  // confetti.
  readonly property int donutSlices: 5

  readonly property string authorName: "amergrgic"
  readonly property string authorUrl: "https://amergrgic.com"

  property var report: ({})
  property bool loading: false
  property string errorText: ""
  property double updatedMs: 0
  // Per-session section state: collapsing is a reading aid, not a preference,
  // and shell.json is read-only from a widget.
  property bool modelsExpanded: true
  // Countdowns and "Updated HH:mm" read this instead of Date.now(), so a panel
  // left open keeps telling the truth without rebuilding every row.
  property double nowMs: Date.now()

  readonly property var limits: report.limits || []
  readonly property var totals: report.totals || ({})
  readonly property var todayStats: report.today || ({})
  readonly property var sources: report.sources || []
  readonly property string statusText: String(report.statusText || "")
  readonly property int refreshSec: Math.max(15, Number(setting("refreshSec", 60)))
  readonly property bool hasData: (report.models || []).length > 0 || limits.length > 0

  // The same model id can arrive from more than one client (`omp` and
  // `opencode` both run deepseek-v4.1-flash), and the legend no longer prints
  // the client per row — so fold those into one row here and let the tooltip
  // say which clients fed it. Otherwise the list shows duplicate names.
  readonly property var modelsByName: {
    var all = report.models || []
    var byName = ({})
    var order = []
    for (var i = 0; i < all.length; i++) {
      var row = all[i]
      var name = root.modelTitle(row)
      var entry = byName[name]
      if (!entry) {
        entry = byName[name] = {
          label: name, total: 0, input: 0, output: 0,
          cacheRead: 0, cacheWrite: 0, clients: []
        }
        order.push(name)
      }
      entry.total += Number(row.total || 0)
      entry.input += Number(row.input || 0)
      entry.output += Number(row.output || 0)
      entry.cacheRead += Number(row.cacheRead || 0)
      entry.cacheWrite += Number(row.cacheWrite || 0)
      var client = String(row.client || "")
      if (client !== "" && entry.clients.indexOf(client) < 0) entry.clients.push(client)
    }
    order.sort(function(a, b) { return byName[b].total - byName[a].total })
    var out = []
    for (var k = 0; k < order.length; k++) out.push(byName[order[k]])
    return out
  }

  readonly property real modelTotal: {
    var sum = 0
    for (var i = 0; i < modelsByName.length; i++) sum += Number(modelsByName[i].total || 0)
    return sum
  }

  // Wedges and legend rows come from one list so they can never disagree: the
  // five heaviest models, then an honest "other" for the remainder.
  readonly property var slices: {
    var top = modelsByName.slice(0, donutSlices)
    var total = root.modelTotal
    var out = []
    var used = 0
    for (var i = 0; i < top.length; i++) {
      var tokens = Number(top[i].total || 0)
      used += tokens
      out.push({
        label: top[i].label,
        total: tokens,
        share: total > 0 ? tokens / total : 0,
        color: root.sliceColor(i),
        tooltip: root.aggregateTooltip(top[i])
      })
    }
    var rest = total - used
    if (rest > 0) {
      var hidden = modelsByName.length - top.length
      out.push({
        label: "other",
        total: rest,
        share: rest / total,
        color: root.dim,
        tooltip: root.formatTokens(rest) + " tokens outside the top five ("
          + hidden + (hidden === 1 ? " model)" : " models)")
      })
    }
    return out
  }

  // --------------------------------------------------------------- refresh

  function refresh(force) {
    if (collector.running) return
    var command = ["/usr/bin/timeout", "20", collectorPath]
    if (force === true) command.push("--force")
    collector.command = command
    collector.running = true
    loading = true
  }

  function applyPayload(text) {
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (e) {
      errorText = "Collector returned invalid JSON"
      return
    }
    if (!parsed || typeof parsed !== "object") {
      errorText = "Collector returned nothing"
      return
    }
    errorText = ""
    report = parsed
    updatedMs = Date.now()
  }

  Process {
    id: collector
    running: false
    onExited: function(code) {
      root.loading = false
      if (code !== 0 && root.errorText === "") root.errorText = "Collector exited " + code
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(text)
    }

    // Per-source failures are reported on stderr while the record still
    // carries every source that did work, so stderr is diagnostic only: the
    // exit code decides whether the panel shows an error.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("opencode-usage", text.trim())
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: {
    if (!opened) return
    nowMs = Date.now()
    flick.contentY = 0
    if (Date.now() - updatedMs > 20000) refresh(false)
  }

  // ------------------------------------------------------------ formatting

  function formatTokens(value) {
    var count = Number(value || 0)
    if (!isFinite(count) || count <= 0) return "0"
    if (count >= 1e9) return (count / 1e9).toFixed(1) + "B"
    if (count >= 1e6) return (count / 1e6).toFixed(1) + "M"
    if (count >= 1e3) return (count / 1e3).toFixed(1) + "k"
    return String(Math.round(count))
  }

  function resetText(iso) {
    if (!iso) return ""
    var at = new Date(String(iso))
    if (isNaN(at.getTime())) return ""
    var remaining = at.getTime() - nowMs
    if (remaining <= 0) return "resetting"
    var minutes = Math.floor(remaining / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return "resets in " + days + "d " + (hours % 24) + "h"
    if (hours > 0) return "resets in " + hours + "h " + (minutes % 60) + "m"
    return "resets in " + Math.max(1, minutes) + "m"
  }

  // Wedges step around the accent's hue and lightness instead of fading its
  // alpha: alpha over a dark panel collapses into one indistinguishable blue.
  function sliceColor(index) {
    var accent = root.accent
    var hue = (accent.hslHue + index * 0.055) % 1.0
    var saturation = Math.max(0.3, accent.hslSaturation * (1 - index * 0.08))
    var lightness = Math.min(0.82, Math.max(0.34, accent.hslLightness * (1 - index * 0.11)))
    return Qt.hsla(hue, saturation, lightness, 1)
  }

  function shareLabel(share) {
    var percent = Number(share || 0) * 100
    if (percent <= 0) return "0%"
    if (percent < 1) return "<1%"
    return Math.round(percent) + "%"
  }

  function modelTitle(row) {
    return String(row.model || "unknown")
  }

  function aggregateTooltip(row) {
    var clients = row.clients || []
    return "in " + formatTokens(row.input) + " · out " + formatTokens(row.output)
      + " · cache read " + formatTokens(row.cacheRead) + " · cache write " + formatTokens(row.cacheWrite)
      + (clients.length > 0 ? " · via " + clients.join(" + ") : "")
  }

  function updatedLabel() {
    if (errorText !== "") return errorText
    if (!updatedMs) return loading ? "Scanning…" : "Not scanned yet"
    return "Updated " + Qt.formatTime(new Date(updatedMs), "HH:mm") + " · R"
  }

  function barTooltip() {
    var parts = []
    for (var i = 0; i < limits.length; i++)
      parts.push(String(limits[i].title || limits[i].label || "limit") + " "
        + Math.round(Number(limits[i].percent || 0) * 100) + "%")
    var head = "OpenCode Go · " + formatTokens(todayStats.tokens) + " today"
    if (modelsByName.length > 0)
      head += " · top " + modelsByName[0].label + " " + formatTokens(modelsByName[0].total)
    if (parts.length > 0) head += "\n" + parts.join(" · ")
    return head
  }

  // Collapsing only hides a body; the Repeater keeps its delegates, so
  // re-expanding costs no rebuild. contentY is clamped afterwards: the list
  // disappearing must not leave the card scrolled past its new bottom.
  function toggleModels() {
    modelsExpanded = !modelsExpanded
    Qt.callLater(clampScroll)
  }

  function clampScroll() {
    flick.contentY = Math.max(0, Math.min(flick.contentY, flick.contentHeight - flick.height))
  }

  function sourceSummary() {
    var parts = []
    for (var i = 0; i < sources.length; i++) {
      if (!sources[i].present) continue
      parts.push(String(sources[i].id) + " " + formatTokens(sources[i].tokens))
    }
    return parts.join(" · ")
  }

  // Bar: nothing to say until a scan finds something, then one glyph.
  visible: hasData || loading
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function toggleModels(): string { root.toggleModels(); return String(root.modelsExpanded) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.errorText !== ""
    tooltipText: root.barTooltip()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    // No arbitrary cap: the card is exactly as tall as its content, clamped
    // only by the screen. A cap a few pixels under the content made the panel
    // scroll by a hair on open.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, panel.availableCardHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.refresh(true)
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "r") root.refresh(true)
        else if (key === "m") root.toggleModels()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // ------------------------------------------------ header
          Item {
            width: parent.width
            implicitHeight: Math.max(title.implicitHeight, headline.implicitHeight)

            Text {
              id: title
              textFormat: Text.PlainText
              text: "OpenCode"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.weight: Font.DemiBold
            }

            Text {
              id: headline
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.formatTokens(root.todayStats.tokens) + " today"
              color: root.statusText !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.statusText !== ""
            width: parent.width
            text: root.statusText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // ------------------------------------------------ limits
          Column {
            width: parent.width
            visible: root.limits.length > 0
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "GO LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits
              LimitRow {
                required property var modelData
                width: parent.width
                window: modelData
              }
            }
          }

          PanelSeparator {
            visible: root.limits.length > 0 && root.modelsByName.length > 0
            foreground: root.foreground
          }

          // ------------------------------------------------ by model
          Column {
            width: parent.width
            visible: root.modelsByName.length > 0
            spacing: Style.spacing.md

            SectionHeader {
              width: parent.width
              title: "TOKENS BY MODEL"
              expanded: root.modelsExpanded
              onToggled: root.toggleModels()
            }

            Column {
              width: parent.width
              visible: root.modelsExpanded
              spacing: Style.spacing.md

              Donut {
                width: parent.width
                slices: root.slices
                caption: root.formatTokens(root.modelTotal)
                subcaption: root.modelsByName.length + " models"
              }

              Repeater {
                model: root.slices
                ShareRow {
                  required property var modelData
                  width: parent.width
                  label: modelData.label
                  total: modelData.total
                  share: modelData.share
                  swatch: modelData.color
                  tooltip: modelData.tooltip
                }
              }
            }
          }

          // ------------------------------------------------ footer
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            topPadding: Style.space(2)
            text: root.sourceSummary()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          // Scan time on the left, credit on the right. The credit stays a
          // plain Text rather than a styled-text anchor so the only thing
          // rendered is the constant below.
          Item {
            width: parent.width
            implicitHeight: Math.max(updatedText.implicitHeight, creditText.implicitHeight)

            Text {
              id: updatedText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: creditText.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.updatedLabel()
              color: root.errorText !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: creditText
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "made by " + root.authorName
              color: creditHover.containsMouse ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: creditHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally(root.authorUrl)
              }
            }
          }
        }
      }
    }
  }

  // Section title that doubles as a collapse control: chevron, label, and a
  // full-width click target. The body stays in the tree (only hidden), so a
  // toggle is a re-layout, never a rebuild.
  component SectionHeader: Item {
    id: header
    property string title: ""
    property bool expanded: true
    signal toggled()

    implicitHeight: Math.max(chevron.implicitHeight, label.implicitHeight)

    Text {
      id: chevron
      textFormat: Text.PlainText
      text: header.expanded ? "▾" : "▸"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelSectionHeader {
      id: label
      text: header.title
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.left: chevron.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: header.toggled()
    }
  }

  // One allowance window: label, percentage, meter, reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: {
          var title = String(limitRow.window ? limitRow.window.title : "")
          var span = String(limitRow.window ? limitRow.window.label : "")
          return span !== "" ? title + " (" + span + ")" : title
        }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(Number(limitRow.window ? limitRow.window.percent : 0) * 100) + "%"
        color: Number(limitRow.window ? limitRow.window.percent : 0) >= 0.9 ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Meter {
      width: parent.width
      ratio: Number(limitRow.window ? limitRow.window.percent : 0)
      fill: Number(limitRow.window ? limitRow.window.percent : 0) >= 0.9 ? root.urgent : root.accent
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.resetText(limitRow.window ? limitRow.window.resetsAt : "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A full-bleed meter: track plus filled portion, clamped to 0..1.
  component Meter: Rectangle {
    id: meter
    property real ratio: 0
    property color fill: root.accent

    height: Style.space(6)
    radius: height / 2
    color: root.track

    Rectangle {
      width: parent.width * Math.max(0, Math.min(1, meter.ratio))
      height: parent.height
      radius: parent.radius
      color: meter.fill
    }
  }

  // Token share as a ring plus a centred total. Canvas rather than Shape:
  // the wedges are painted once per data change, and Canvas is already used
  // elsewhere in the shell (SpeedTestOverlay, Dropdown QR) so nothing new has
  // to resolve at load time.
  component Donut: Item {
    id: donut
    property var slices: []
    property string caption: ""
    property string subcaption: ""

    implicitHeight: Style.space(150)

    readonly property real ringSize: {
      var limit = Math.max(0, Math.min(width, implicitHeight) - Style.space(8))
      return limit > 0 ? limit : 0
    }

    Canvas {
      id: ring
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      width: donut.ringSize
      height: donut.ringSize

      Connections {
        target: donut
        function onSlicesChanged() { ring.requestPaint() }
      }

      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      Component.onCompleted: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var size = Math.min(width, height)
        if (!(size > 0)) return
        var thickness = Math.max(6, size * 0.15)
        var radius = (size - thickness) / 2
        var middle = size / 2
        var start = -Math.PI / 2
        ctx.lineWidth = thickness
        ctx.lineCap = "butt"
        for (var i = 0; i < donut.slices.length; i++) {
          var sweep = Math.max(0, Number(donut.slices[i].share) || 0) * Math.PI * 2
          if (!(sweep > 0)) continue
          ctx.beginPath()
          ctx.strokeStyle = String(donut.slices[i].color)
          ctx.arc(middle, middle, radius, start, start + sweep)
          ctx.stroke()
          start += sweep
        }
      }
    }

    Column {
      anchors.centerIn: ring
      spacing: 0

      Text {
        width: ring.width
        textFormat: Text.PlainText
        text: donut.caption
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: ring.width
        textFormat: Text.PlainText
        text: donut.subcaption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  // Legend row for one wedge: swatch, model (+client), share and total.
  component ShareRow: Item {
    id: shareRow
    property string label: ""
    property real total: 0
    property real share: 0
    property color swatch: root.accent
    property string tooltip: ""

    implicitHeight: Math.max(swatchItem.height, nameText.implicitHeight, valueText.implicitHeight)
      + Style.spacing.md

    Rectangle {
      id: swatchItem
      width: Style.space(7)
      height: width
      radius: width / 2
      color: shareRow.swatch
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: nameText
      textFormat: Text.PlainText
      anchors.left: swatchItem.right
      anchors.leftMargin: Style.space(8)
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: shareRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: valueText
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.formatTokens(shareRow.total) + "  " + root.shareLabel(shareRow.share)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: hover.containsMouse && shareRow.tooltip !== ""
      text: shareRow.tooltip
    }
  }
}
