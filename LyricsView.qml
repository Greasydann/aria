import QtQuick
import qs.Commons
import qs.Commons as Theme
import qs.Ui

// Synced lyrics for the playing track. The active line highlights and the
// view keeps it centered; clicking a line seeks there. Unsynced lyrics show
// as plain text without highlighting.
Item {
  id: root

  property var lyrics: null // { lines: [{time, text}], plain, instrumental, trackName, artistName }
  property string status: "" // "loading", "found", "plain", "instrumental", "notfound", "error"
  property string errorText: ""
  property color foreground: Theme.Color.foreground
  property color muted: Theme.Color.muted
  property color accent: Commons.Color.accent
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
  readonly property real rowHeight: Style.space(34)
  readonly property bool syncedView: status === "found" && lines.length > 0

  function scrollToActive() {
    if (!syncedView || activeIndex < 0) return
    var target = Math.max(0, Math.min(flickable.contentHeight - flickable.height,
      activeIndex * rowHeight + rowHeight / 2 - flickable.height / 2))
    flickable.contentY = target
  }

  onActiveIndexChanged: scrollToActive()
  onLinesChanged: Qt.callLater(scrollToActive)
  onVisibleChanged: if (visible) Qt.callLater(scrollToActive)

  Column {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(4)
    spacing: Style.space(4)

    Button {
      id: backButton
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

  Flickable {
    id: flickable
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(10)
    contentWidth: width
    contentHeight: statusBody.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: statusBody
      width: flickable.width
      spacing: Style.space(6)

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

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.status === "error"

        Text {
          width: parent.width
          text: root.errorText || "Could not load lyrics."
          color: Theme.Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Button {
          text: "Try again"
          iconText: "󰑐"
          foreground: root.foreground
          onClicked: root.retryRequested()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.status === "plain"

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.lyrics ? root.lyrics.plain : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Unsynced lyrics"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Synced lines
      Repeater {
        model: root.syncedView ? root.lines : []

        Item {
          required property var modelData
          required property int index
          width: flickable.width
          height: root.rowHeight

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: modelData.text !== "" ? modelData.text : "♪"
            color: index === root.activeIndex ? root.accent
              : (index < root.activeIndex ? root.foreground : root.muted)
            font.family: root.fontFamily
            font.pixelSize: index === root.activeIndex
              ? Style.font.subtitle : Style.font.body
            font.bold: index === root.activeIndex
            opacity: index === root.activeIndex ? 1 : 0.85
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
            Behavior on color { ColorAnimation { duration: Style.duration(150) } }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.seekRequested(modelData.time)
          }
        }
      }
    }
  }
}
