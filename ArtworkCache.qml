import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api

// Downloads remote artwork with HTTP/1.1 into a disk cache and hands QML a
// local file URL as soon as one is ready. Until then imageUrl() returns the
// original URL, so covers still appear if the helper cannot fetch them.
Item {
  id: root

  property string cacheDir: ""
  property string scriptPath: ""
  property bool enabled: true

  readonly property int revision: root._revision
  property int _revision: 0
  property var cached: ({})
  property var requested: ({})
  property var pendingWrites: ([])

  function imageUrl(remote) {
    var url = String(remote || "")
    // Reading a property here makes every image binding depend on it, so
    // newly cached files replace their remote URLs without a manual refresh.
    var rev = root.revision
    if (!root.enabled || !Api.isCacheableImage(url)) return url
    var key = Api.artworkCacheKey(url)
    if (!root.cached[key]) root.enqueue(url)
    if (root.cached[key] && rev >= 0)
      return "file://" + encodeURI(root.cacheDir + "/" + key + ".jpg")
    return url
  }

  function enqueue(url) {
    var key = Api.artworkCacheKey(url)
    if (root.requested[key]) return
    root.requested[key] = true
    var line = url + "\n"
    if (daemon.running) daemon.write(line)
    else root.pendingWrites = root.pendingWrites.concat([line])
  }

  function onCacheLine(line) {
    var parts = String(line).trim().split(" ")
    if ((parts[0] !== "HIT" && parts[0] !== "READY") || parts.length < 2) return
    if (root.cached[parts[1]]) return
    var next = Api.shallowCopy(root.cached)
    next[parts[1]] = true
    root.cached = next
    root._revision++
  }

  Process {
    id: daemon
    command: [Quickshell.env("PYTHON") || "python3",
      root.scriptPath, root.cacheDir]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.onCacheLine(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      var lines = root.pendingWrites
      root.pendingWrites = []
      for (var i = 0; i < lines.length; i++) daemon.write(lines[i])
    }
    onExited: {
      // A fresh helper may not have the URLs QML already asked for. Clear the
      // dedupe set so the next binding refresh re-sends them.
      root.requested = ({})
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: daemon.running = true
  }

  Component.onCompleted: {
    if (root.cacheDir && root.scriptPath) daemon.running = true
  }
  onCacheDirChanged: {
    root.cached = ({})
    root.requested = ({})
    if (daemon.running) daemon.running = false
    if (root.cacheDir && root.scriptPath) daemon.running = true
  }
}
