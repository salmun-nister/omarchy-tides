import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.woogy7.tides"
  ipcTarget: "io.github.woogy7.tides"

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel (same contract as the weather plugin).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    weatherLocationFile.reload()
    tidesLocationFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    weatherLocationFile.reload()
    tidesLocationFile.reload()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Parsed Open-Meteo Marine response. Kept on failure so stale data stays
  // visible until the next successful fetch.
  property var marineReport: null
  property int marineRetries: 0

  // Ticks so "next tide", countdown, and current height track wall time.
  property var now: new Date()

  Timer {
    interval: 30 * 1000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  // ---- Location. The tides panel has its own state file; when it is unset
  //      it follows the weather widget's location (owned by
  //      omarchy-weather-location), so out of the box the two agree.
  readonly property string tidesLocationPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/tides.json"
  property var weatherLocationState: ({ name: "", latitude: null, longitude: null })
  property var tidesLocationState: ({ name: "", latitude: null, longitude: null })

  readonly property bool hasOwnLocation: tidesLocationState.latitude !== null && tidesLocationState.longitude !== null
  readonly property var configuredLocationState: hasOwnLocation ? tidesLocationState : weatherLocationState
  readonly property bool hasCoordinates: configuredLocationState.latitude !== null && configuredLocationState.longitude !== null
  readonly property string locationKey: hasCoordinates ? configuredLocationState.latitude + "," + configuredLocationState.longitude : ""

  onLocationKeyChanged: {
    marineRetries = 0
    marineProc.running = false
    Qt.callLater(refresh)
  }

  property FileView weatherLocationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.weatherLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.weatherLocationState = Model.parseLocationFile("")
  }

  property FileView tidesLocationFile: FileView {
    path: root.tidesLocationPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.tidesLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.tidesLocationState = Model.parseLocationFile("")
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: { weatherLocationFile.reload(); tidesLocationFile.reload() }
  }

  // ---- Click-to-edit location (mirrors the weather panel's editor).
  property bool editingLocation: false
  property bool savingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.configuredLocationState.name
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var text = locationField.text.trim()
    if (text === "") {
      clearLocation()
      return
    }
    var choices = locationSuggestions || []
    var index = Math.max(0, Math.min(suggestionIndex, choices.length - 1))
    if (choices[index]) pickSuggestion(choices[index])
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  // Empty commit or ✕ returns to following the weather location.
  function clearLocation() {
    locationSaveProc.command = ["rm", "-f", root.tidesLocationPath]
    locationSaveProc.running = true
    cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    locationSaveProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"", "_",
      root.tidesLocationPath, Model.locationFileContents(name, latitude, longitude)]
    locationSaveProc.running = true
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      tidesLocationFile.reload()
      if (root.savingLocation) root.cancelEditingLocation()
    }
  }

  // Debounced geocoding. Only one curl runs at a time; if the query moved on
  // while a fetch was in flight, the latest query is fetched right after.
  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  // ---- Derived tide state.
  readonly property var events: Model.tideEvents(marineReport)
  readonly property var upcoming: Model.upcomingEvents(events, now, 4)
  readonly property var nextEvent: upcoming.length > 0 ? upcoming[0] : null
  readonly property var dayTides: Model.dayTides(events, now)
  readonly property var currentHeight: Model.heightAt(marineReport, now)

  readonly property string waveIcon: "󰞍" // nf-md-waves
  readonly property string label: nextEvent ? waveIcon : ""

  // ---- Scrubbing: hovering/dragging over the curve moves the cursor along
  //      it. null = follow "now".
  property var scrubTime: null
  readonly property var cursorTime: scrubTime || now
  readonly property bool scrubbing: scrubTime !== null

  function refresh() {
    if (!hasCoordinates) return
    marineRetries = 0
    startFetch()
  }

  function startFetch() {
    if (marineProc.running || !hasCoordinates) return
    var url = "https://marine-api.open-meteo.com/v1/marine"
      + "?latitude=" + encodeURIComponent(String(configuredLocationState.latitude))
      + "&longitude=" + encodeURIComponent(String(configuredLocationState.longitude))
      + "&hourly=sea_level_height_msl"
      + "&forecast_days=3"
      + "&timezone=auto"
    marineProc.command = ["curl", "-fsS", "--max-time", "10", url]
    marineProc.running = true
  }

  function scheduleRetry() {
    if (marineRetries >= 3) return
    marineRetries++
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.startFetch()
  }

  Process {
    id: marineProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          if (!parsed.hourly) throw new Error("no hourly data")
          root.marineReport = parsed
          root.marineRetries = 0
        } catch (e) {
          root.scheduleRetry()
        }
      }
    }
  }

  // Predictions are stable; refetch occasionally to keep 3 days of horizon.
  Timer {
    interval: 3 * 60 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(tidesColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: tidesColumn
        width: parent.width
        spacing: Style.space(14)

        // ---- Header row: wave mark + location (click to edit) on the left;
        //      stats on the right.
        Item {
          width: parent.width
          height: Math.max(heroLeft.height, heroRight.height)

          Row {
            id: heroLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.waveIcon
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: 30
            }

            Item {
              anchors.verticalCenter: parent.verticalCenter
              visible: !root.editingLocation
              width: locationLabel.implicitWidth
              height: locationLabel.implicitHeight

              Text {
                id: locationLabel
                text: root.configuredLocationState.name !== ""
                  ? root.configuredLocationState.name.toUpperCase()
                  : (root.hasCoordinates ? "" : "SET LOCATION")
                color: locationHover.hovered ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              TapHandler {
                onTapped: root.startEditingLocation()
              }
              HoverHandler {
                id: locationHover
                cursorShape: Qt.PointingHandCursor
              }
            }

            Row {
              visible: root.editingLocation
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              TextField {
                id: locationField
                width: Style.space(190)
                enabled: !root.savingLocation
                placeholderText: "Search town or beach"
                foreground: root.bar.foreground
                font.family: root.bar.fontFamily

                onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelEditingLocation()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    if (root.suggestionIndex > 0) root.suggestionIndex--
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitLocation()
                    event.accepted = true
                  }
                }
              }

              // ✕ returns to following the weather location; becomes a
              // spinner while a picked location is being saved.
              Rectangle {
                width: Style.space(18)
                height: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
                radius: Math.min(4, Style.cornerRadius)
                color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: root.savingLocation ? "󰦖" : "✕"
                  font.family: root.bar.fontFamily
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.pixelSize: Style.font.bodySmall

                  RotationAnimator on rotation {
                    running: root.savingLocation
                    from: 0; to: 360
                    duration: 800
                    loops: Animation.Infinite
                  }
                }

                MouseArea {
                  id: clearLocationArea
                  anchors.fill: parent
                  enabled: !root.savingLocation
                  hoverEnabled: true
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.clearLocation()
                }
              }
            }
          }

          Column {
            id: heroRight
            width: tideStats.implicitWidth
            anchors.right: parent.right
            anchors.rightMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            Row {
              id: tideStats
              visible: !!root.nextEvent
              spacing: Style.space(36)

              Column {
                spacing: Style.space(5)
                Text {
                  text: "NOW"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                Text {
                  text: Model.formatHeight(root.currentHeight)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }

              Column {
                spacing: Style.space(5)
                Text {
                  text: "TIDE"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                Text {
                  text: root.nextEvent ? (root.nextEvent.high ? "Rising" : "Falling") : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }

              Column {
                spacing: Style.space(5)
                Text {
                  text: "RANGE"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
                Text {
                  text: Model.todayRange(root.events, root.now)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
            }
          }
        }

        // ---- Geocoding suggestions while the location is being edited.
        Column {
          visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
          width: parent.width
          spacing: 0

          Repeater {
            model: root.locationSuggestions

            Rectangle {
              required property var modelData
              required property int index
              width: parent.width
              height: suggestionRow.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Row {
                id: suggestionRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: modelData.name
                  color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  visible: text !== ""
                  text: modelData.description
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: root.suggestionIndex = index
                onClicked: root.pickSuggestion(modelData)
              }
            }
          }
        }

        Text {
          visible: !root.nextEvent
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.hasCoordinates ? "Fetching tides…" : "Click the location to set one"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // ---- Tide curve: rolling 24h window (6h back, 18h ahead) with
        //      6-hour grid, high/low markers, and a scrubbable cursor.
        Item {
          visible: !!root.marineReport && !!root.nextEvent
          width: parent.width
          height: Style.space(136)

          Canvas {
            id: tideCurve
            anchors.fill: parent
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(20)

            readonly property color fg: root.bar.foreground
            onFgChanged: requestPaint()

            // Window geometry shared with the scrub handler.
            readonly property real windowStartMs: root.now.getTime() - 6 * 3600 * 1000
            readonly property real windowMs: 24 * 3600 * 1000

            function timeAtX(px) {
              var frac = Math.max(0, Math.min(1, px / width))
              var tm = windowStartMs + frac * windowMs

              // Gentle magnet: settle on a high/low when the pointer is
              // within ~15 minutes of it, so peaks are easy to land on
              // without the cursor fighting the hand elsewhere.
              var snapMs = 15 * 60 * 1000
              var best = null
              var targets = [root.now.getTime()]
              for (var i = 0; i < root.events.length; i++) targets.push(root.events[i].time.getTime())
              for (i = 0; i < targets.length; i++) {
                var d = Math.abs(targets[i] - tm)
                if (d <= snapMs && (best === null || d < Math.abs(best - tm))) best = targets[i]
              }
              return new Date(best !== null ? best : tm)
            }

            Connections {
              target: root
              function onMarineReportChanged() { tideCurve.requestPaint() }
              function onNowChanged() { tideCurve.requestPaint() }
              function onScrubTimeChanged() { tideCurve.requestPaint() }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.SizeHorCursor
              onPositionChanged: function(mouse) { root.scrubTime = tideCurve.timeAtX(mouse.x) }
              onPressed: function(mouse) { root.scrubTime = tideCurve.timeAtX(mouse.x) }
              onExited: root.scrubTime = null
            }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              if (!root.marineReport) return

              var w = width
              var h = height
              var captionPx = Style.font.caption
              var padTop = captionPx + 8
              // Two label bands below the plot: the cursor label in the
              // first, axis hour labels in the second.
              var padBottom = captionPx * 2 + 22
              var startMs = windowStartMs
              var endMs = startMs + windowMs

              // Sample the curve every 10 minutes.
              var pts = []
              var minH = Infinity
              var maxH = -Infinity
              for (var t = startMs; t <= endMs; t += 10 * 60 * 1000) {
                var v = Model.smoothHeightAt(root.marineReport, t)
                if (v === null) continue
                pts.push({ t: t, v: v })
                if (v < minH) minH = v
                if (v > maxH) maxH = v
              }
              if (pts.length < 2) return
              var span = Math.max(0.5, maxH - minH)
              minH -= span * 0.08
              maxH += span * 0.08

              function x(tm) { return (tm - startMs) / (endMs - startMs) * w }
              function y(v) { return padTop + (1 - (v - minH) / (maxH - minH)) * (h - padTop - padBottom) }

              var fgc = String(fg)
              ctx.font = captionPx + "px " + root.bar.fontFamily
              ctx.textAlign = "center"

              // Hour labels every 6 hours along the bottom (no grid lines).
              var tick = new Date(startMs)
              tick.setMinutes(0, 0, 0)
              while (tick.getHours() % 6 !== 0) tick.setTime(tick.getTime() + 3600 * 1000)
              ctx.globalAlpha = 0.45
              ctx.fillStyle = fgc
              for (var tm = tick.getTime(); tm < endMs; tm += 6 * 3600 * 1000) {
                ctx.fillText(Model.pad2(new Date(tm).getHours()), x(tm), h - 2)
              }

              // The curve itself.
              ctx.globalAlpha = 1
              ctx.strokeStyle = fgc
              ctx.lineWidth = 2
              ctx.lineJoin = "round"
              ctx.beginPath()
              ctx.moveTo(x(pts[0].t), y(pts[0].v))
              for (var i = 1; i < pts.length; i++) ctx.lineTo(x(pts[i].t), y(pts[i].v))
              ctx.stroke()

              // Cursor position (now, or wherever the pointer is scrubbing).
              var cursorMs = root.cursorTime.getTime()
              var cx = x(cursorMs)
              var cv = Model.smoothHeightAt(root.marineReport, cursorMs)

              // High/low markers (dots only — times live in the row below,
              // and the scrub cursor reads any point off the line).
              for (i = 0; i < root.events.length; i++) {
                var e = root.events[i]
                var em = e.time.getTime()
                if (em < startMs || em > endMs) continue
                var ex = x(em)
                var ey = y(e.height)
                ctx.globalAlpha = 1
                ctx.fillStyle = fgc
                ctx.beginPath()
                ctx.arc(ex, ey, 2.5, 0, Math.PI * 2)
                ctx.fill()
              }

              // "Now": a bolder line with its own dot on the curve. Always
              // drawn, so the present stays findable while scrubbing (dimmed
              // a little then, so the cursor leads).
              var nx = x(root.now.getTime())
              var nv = Model.smoothHeightAt(root.marineReport, root.now.getTime())
              ctx.globalAlpha = root.scrubbing ? 0.3 : 0.5
              ctx.strokeStyle = fgc
              ctx.lineWidth = 1.5
              ctx.beginPath()
              ctx.moveTo(nx, padTop)
              ctx.lineTo(nx, h - padBottom)
              ctx.stroke()
              if (nv !== null) {
                ctx.globalAlpha = root.scrubbing ? 0.6 : 1
                ctx.fillStyle = fgc
                ctx.beginPath()
                ctx.arc(nx, y(nv), 4, 0, Math.PI * 2)
                ctx.fill()
              }

              // Cursor: hairline, ringed dot riding the curve, and a
              // time · height label in the band under the plot. When not
              // scrubbing the cursor sits on "now" and just adds the ring.
              if (root.scrubbing) {
                ctx.globalAlpha = 0.45
                ctx.strokeStyle = fgc
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(cx, padTop)
                ctx.lineTo(cx, h - padBottom)
                ctx.stroke()
              }
              if (cv !== null) {
                ctx.globalAlpha = 1
                ctx.fillStyle = fgc
                ctx.beginPath()
                ctx.arc(cx, y(cv), 4, 0, Math.PI * 2)
                ctx.fill()
                ctx.globalAlpha = 0.5
                ctx.strokeStyle = fgc
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.arc(cx, y(cv), 7.5, 0, Math.PI * 2)
                ctx.stroke()

                ctx.globalAlpha = 1
                ctx.fillStyle = fgc
                var labelText = Model.formatTime(root.cursorTime) + " · " + Model.formatHeight(cv)
                var labelX = Math.min(Math.max(cx, 40), w - 40)
                ctx.fillText(labelText, labelX, h - padBottom + captionPx + 10)
              }
            }
          }
        }

        // ---- Divider between the curve and the day's tides row.
        Rectangle {
          visible: root.dayTides.events.length > 0
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }

        // ---- The day's tides, chronological left to right, mirroring the
        //      weather forecast cells. Equal-width columns across the panel
        //      so a 4-tide day always fits inside the border.
        Item {
          visible: root.dayTides.events.length > 0
          width: parent.width
          height: eventsRow.height

          Row {
            id: eventsRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(20)
            spacing: 0

            readonly property int count: Math.max(1, root.dayTides.events.length)
            readonly property real cellWidth: width / count

            Repeater {
              model: root.dayTides.events

              Item {
                required property var modelData
                required property int index
                width: eventsRow.cellWidth
                height: cellRow.implicitHeight

                Row {
                  id: cellRow
                  // First cell hugs the left margin; the rest sit at the
                  // start of their column so the row reads as one grid.
                  anchors.left: parent.left
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.high ? "▲" : "▼"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      text: (modelData.high ? "HIGH" : "LOW") + (root.dayTides.label === "TOMORROW" ? " · TMRW" : "")
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Row {
                      spacing: Style.space(5)

                      Text {
                        text: Model.formatTime(modelData.time)
                        color: modelData.time.getTime() < root.now.getTime() ? Qt.darker(root.bar.foreground, 1.5) : root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        text: Model.formatHeight(modelData.height)
                        color: Qt.darker(root.bar.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
