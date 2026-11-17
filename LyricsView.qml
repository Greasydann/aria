import QtQuick
import qs.Commons
import qs.Commons as Theme
import qs.Ui

// Synced lyrics for the playing track, Spotify-style: the active line
// highlights and the view follows it; clicking a line seeks there.
// Unsynced lyrics show as plain text without highlighting.
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
  signal seekRequested(real seconds)
  signal retryRequested()
  signal closed()

  readonly property var lines: lyrics && Array.isArray(lyrics.lines) ? lyrics.lines : []
  // Highlight slightly early so a line is on screen as it starts.
  readonly property real leadSeconds: 0.3
  readonly property int activeIndex: {
    var target = positionSeconds + leadSeconds
    var index = -1
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= target) index = i
      else break
    }
    return index
  }
  readonly property bool syncedView: status === "found" && lines.length > 0

  onActiveIndexChanged: Qt.callLater(scrollToActive)
  onVisibleChanged: if (visible) Qt.callLater(scrollToActive)

  // Minimal scroll: only moves when the active line is out of view, and
  // always in the direction of the line (never up when the line is below).
  function scrollToActive() {
    if (!syncedView || activeIndex < 0) return
    view.positionViewAtIndex(activeIndex, ListView.Contain)
  }

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

  ListView {
    id: view
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(10)
    model: root.syncedView ? root.lines : []
    visible: root.syncedView
    spacing: Style.space(12)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    delegate: Item {
      id: lineDelegate
      required property var modelData
      required property int index
      width: view.width
      height: lineText.implicitHeight + Style.space(14)
      readonly property bool isActive: index === root.activeIndex

      Text {
        id: lineText
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        text: lineDelegate.modelData.text !== "" ? lineDelegate.modelData.text : "♪"
        color: lineDelegate.isActive ? root.accent
          : (lineDelegate.index < root.activeIndex ? root.foreground : root.muted)
        opacity: lineDelegate.isActive ? 1 : 0.8
        font.family: root.fontFamily
        font.pixelSize: lineDelegate.isActive
          ? Style.font.subtitle : Style.font.body
        font.bold: lineDelegate.isActive
        wrapMode: Text.WordWrap
        Behavior on color { ColorAnimation { duration: Style.duration(150) } }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.seekRequested(lineDelegate.modelData.time)
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
