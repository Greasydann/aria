import QtQuick
import qs.Commons
import qs.Commons as Theme
import qs.Ui

// Synced lyrics for the playing track, teleprompter-style: the text block
// itself glides so the highlighted line always sits at the center of the
// viewport. Nothing is user-scrollable — the song is the scroller. Clicking
// a line seeks there. Unsynced lyrics show as plain text.
Item {
  id: root

  property var lyrics: null // { lines: [{time, text}], plain, instrumental, trackName, artistName }
  property string status: "" // "loading", "found", "plain", "instrumental", "notfound", "error"
  property string errorText: ""
  property color foreground: Theme.Color.foreground
  property color muted: Theme.Color.muted
  property color accent: Theme.Color.accent
  property string fontFamily: Style.font.family
  property real positionSeconds: 0
  property bool playing: true
  signal seekRequested(real seconds)
  signal retryRequested()
  signal closed()

  readonly property var lines: lyrics && Array.isArray(lyrics.lines) ? lyrics.lines : []
  // Highlight slightly early so a line is centered as it starts.
  readonly property real leadSeconds: 0.4
  // The service refreshes its position anchor every few seconds; this view
  // interpolates it locally so the glide is smooth between updates.
  property double anchorAt: Date.now()
  property real livePosition: 0
  onPositionSecondsChanged: anchorAt = Date.now()
  onPlayingChanged: anchorAt = Date.now()

  Timer {
    interval: 200
    running: root.visible && root.playing
    repeat: true
    onTriggered: {
      root.livePosition = root.positionSeconds
        + (Date.now() - root.anchorAt) / 1000
    }
  }

  readonly property int activeIndex: {
    var target = livePosition + leadSeconds
    var index = -1
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= target) index = i
      else break
    }
    return index
  }
  readonly property bool syncedView: status === "found" && lines.length > 0

  // The text block is translated so the active line's center sits at the
  // viewport's center — always, including the first and last lines.
  function updateLyricsOffset() {
    if (!syncedView) return
    var item = linesRepeater.itemAt(activeIndex)
    if (!item) return
    linesColumn.y = Math.round(viewport.height / 2
      - (item.y + item.height / 2))
  }
  onActiveIndexChanged: Qt.callLater(updateLyricsOffset)
  onLinesChanged: Qt.callLater(updateLyricsOffset)
  onVisibleChanged: if (visible) Qt.callLater(updateLyricsOffset)

  Column {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(4)
    spacing: Style.space(4)

    Button {
      text: "Back"
      iconText: "󰅂"
      foreground: root.foreground
      hasCursor: true
      onClicked: root.closed()
    }

    Text {
      width: parent.width
      text: "Lyrics"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      width: parent.width
      text: root.lyrics && root.lyrics.trackName
        ? (root.lyrics.trackName
          + (root.lyrics.artistName ? " · " + root.lyrics.artistName : ""))
        : ""
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      visible: text !== ""
    }
  }

  Item {
    id: viewport
    clip: true
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.bottom: parent.bottom

    Column {
      id: linesColumn
      width: parent.width
      spacing: Style.space(18)
      y: viewport.height / 2 - activeLineCenter
      Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

      Repeater {
        id: linesRepeater
        model: root.syncedView ? root.lines : []

        Item {
          id: lineDelegate
          required property var modelData
          required property int index
          width: linesColumn.width
          height: lineText.implicitHeight + Style.space(14)
          readonly property bool isActive: index === root.activeIndex

          Text {
            id: lineText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: lineDelegate.modelData.text !== ""
              ? lineDelegate.modelData.text : "♪"
            color: lineDelegate.isActive ? root.accent
              : (lineDelegate.index < root.activeIndex
                ? root.foreground : root.muted)
            opacity: lineDelegate.isActive ? 1 : 0.75
            font.family: root.fontFamily
            font.pixelSize: lineDelegate.isActive
              ? Style.font.subtitle : Style.font.body
            font.bold: lineDelegate.isActive
            wrapMode: Text.WordWrap
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.seekRequested(lineDelegate.modelData.time)
          }
        }
      }
    }
  }

  // Status overlays for the non-synced states
  Column {
    anchors.fill: parent
    anchors.topMargin: header.height + Style.space(10)
    visible: !root.syncedView

    Text {
      width: parent.width
      visible: root.status === "loading"
      text: "Loading lyrics…"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      visible: root.status === "notfound"
      text: "No lyrics found for this track."
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      visible: root.status === "instrumental"
      text: "♪  Instrumental track"
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      width: parent.width
      visible: root.status === "plain"
      textFormat: Text.PlainText
      text: root.lyrics ? root.lyrics.plain : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: root.status === "error"
      text: root.errorText || "Could not load lyrics."
      color: Theme.Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    Button {
      visible: root.status === "error"
      text: "Try again"
      iconText: "󰑐"
      foreground: root.foreground
      onClicked: root.retryRequested()
    }
  }
}
