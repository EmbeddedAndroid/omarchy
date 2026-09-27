import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// CPU, GPU and NPU load at a glance, with frequencies, temperatures and fans
// in the popup. CPU, clocks, sensors and the video engine come from
// omarchy-system-load; GPU and NPU load come from a long-running `nvtop -l`
// when nvtop is installed.
Panel {
  id: root
  moduleName: "omarchy.system-load"
  ipcTarget: "omarchy.system-load"

  readonly property int intervalMs: Math.max(1000, Number(setting("interval", 2)) * 1000)
  property var previous: null
  property var sample: null
  property var loads: ({ total: null, cores: [] })
  property var accel: ({ gpu: null, npu: null })
  property bool nvtopAvailable: false
  property string nvtopBuffer: ""

  readonly property bool hot: Model.isHot(sample ? sample.hot : null)
  readonly property var cpuClusters: Model.clusters(sample ? sample.freqs : [], loads.cores)
  readonly property var gpuTop: Model.topProcesses(accel.gpu ? accel.gpu.processes : [], 3)
  readonly property var tempCells: {
    var s = sample
    var cells = []
    if (!s) return cells
    var names = [["cpu", "CPU"], ["gpu", "GPU"], ["npu", "NPU"], ["ddr", "DDR"]]
    for (var i = 0; i < names.length; i++) {
      var value = Model.celsius(s.temps[names[i][0]])
      if (value !== null) cells.push({ label: names[i][1], value: value })
    }
    return cells
  }
  readonly property var fanCells: Model.fanCells(sample ? sample.fans : [])
  readonly property var memSegments: Model.memorySegments(sample ? sample.memory : null, sample ? sample.apps : [])
  readonly property bool gpuShown: accel.gpu !== null && accel.gpu.util !== null
  readonly property bool npuShown: accel.npu !== null && accel.npu.util !== null
  readonly property var vpu: Model.videoEngine(sample)
  // Only engines with a reading appear; an unreadable one is left out.
  readonly property var engines: {
    var list = []
    if (loads.total !== null) list.push({ letter: "C", value: loads.total })
    if (gpuShown) list.push({ letter: "G", value: accel.gpu.util })
    if (npuShown) list.push({ letter: "N", value: accel.npu.util })
    // The video engine reports power, not load: lit while powered, no percentage.
    if (vpu) list.push({ letter: "V", value: vpu.active ? 100 : 0, bare: true })
    return list
  }
  readonly property bool hasReading: engines.length > 0
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: Color.urgent

  function takeSample(raw) {
    var next = Model.parseSample(raw)
    loads = Model.cpuLoads(previous, next)
    previous = next
    sample = next
  }

  function takeNvtopLine(line) {
    nvtopBuffer += line + "\n"
    if (line !== "]") return
    var taken = Model.takeNvtopSnapshot(nvtopBuffer)
    nvtopBuffer = taken.rest
    if (taken.devices) accel = Model.accelerators(taken.devices)
  }

  function engineColor(value) {
    return Model.engineState(value) === "busy" ? root.accentColor : button.foreground
  }

  function engineOpacity(value) {
    var state = Model.engineState(value)
    return state === "idle" || state === "none" ? 0.45 : 1.0
  }

  Process {
    id: sampleProc
    // Per-program memory costs a scan of /proc, so only while the popup shows it.
    command: root.opened ? ["omarchy-system-load", "--processes"] : ["omarchy-system-load"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeSample(text) }
  }

  onOpenedChanged: if (opened && !sampleProc.running) sampleProc.running = true

  Timer {
    interval: root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sampleProc.running) sampleProc.running = true
  }

  Process {
    id: nvtopProbe
    command: ["bash", "-c", "command -v nvtop"]
    running: true
    onExited: function(exitCode) { root.nvtopAvailable = exitCode === 0 }
  }

  Process {
    id: nvtopProc
    command: ["nvtop", "-l", "-d", String(Math.round(root.intervalMs / 100))]
    running: root.nvtopAvailable
    stdout: SplitParser { onRead: function(line) { root.takeNvtopLine(line) } }
    onExited: {
      root.nvtopBuffer = ""
      root.accel = { gpu: null, npu: null }
      if (root.nvtopAvailable) nvtopRestart.restart()
    }
  }

  Timer {
    id: nvtopRestart
    interval: 10000
    onTriggered: if (root.nvtopAvailable && !nvtopProc.running) nvtopProc.running = true
  }

  visible: hasReading
  implicitWidth: hasReading ? button.implicitWidth : 0
  implicitHeight: hasReading ? button.implicitHeight : 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : readout.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? readout.implicitHeight + scaledVerticalPadding * 2 : -1
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.bar.run("omarchy-launch-or-focus-tui btop")
      else root.toggle()
    }

    Rectangle {
      anchors.fill: readout
      anchors.margins: -Style.space(3)
      visible: root.hot
      color: "transparent"
      radius: Style.space(4)
      border.width: Math.max(1, Style.space(1))
      border.color: root.urgentColor
    }

    Grid {
      id: readout
      anchors.centerIn: parent
      columns: root.vertical ? 1 : root.engines.length + (root.hot ? 1 : 0)
      columnSpacing: Style.space(8)
      rowSpacing: Style.space(2)

      Repeater {
        model: root.engines
        Text {
          required property var modelData
          textFormat: Text.PlainText
          text: modelData.bare ? modelData.letter : root.vertical ? modelData.letter + modelData.value : Model.label(modelData.letter, modelData.value)
          color: root.engineColor(modelData.value)
          opacity: root.engineOpacity(modelData.value)
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          Behavior on opacity { NumberAnimation { duration: 250 } }
        }
      }

      Text {
        visible: root.hot
        textFormat: Text.PlainText
        text: root.sample && root.sample.hot ? Model.celsius(root.sample.hot.temp) : ""
        color: root.urgentColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        EngineHeader { title: Model.label("CPU", root.loads.total); detail: Model.joinPresent([Model.celsius(root.sample ? root.sample.temps.cpu : null)]) }

        Repeater {
          model: root.cpuClusters
          Row {
            id: clusterRow
            required property var modelData
            width: column.width
            spacing: Style.space(3)

            InfoLabel {
              width: Style.space(42)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.cpuRange(clusterRow.modelData.cpus)
            }

            Repeater {
              model: clusterRow.modelData.loads
              Rectangle {
                required property var modelData
                width: Style.space(30)
                height: Style.space(20)
                radius: Style.space(3)
                color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.12 + 0.88 * ((modelData || 0) / 100))

                Text {
                  anchors.centerIn: parent
                  visible: parent.modelData !== null
                  textFormat: Text.PlainText
                  text: parent.modelData
                  color: (parent.modelData || 0) > 55 ? Color.background : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Item { width: Style.space(6); height: 1 }

            InfoValue {
              anchors.verticalCenter: parent.verticalCenter
              text: Model.joinPresent([Model.frequency(clusterRow.modelData.cur), Model.frequency(clusterRow.modelData.max)], " / ")
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.gpuShown }

        Column {
          visible: root.gpuShown
          width: column.width
          spacing: Style.space(6)

          EngineHeader {
            title: Model.label("GPU", root.accel.gpu ? root.accel.gpu.util : null)
            detail: Model.joinPresent([root.accel.gpu && root.accel.gpu.clock ? root.accel.gpu.clock + " MHz" : null, Model.celsius(root.sample ? root.sample.temps.gpu : null)])
          }
          LoadBar { value: root.accel.gpu ? root.accel.gpu.util : 0 }
          InfoLabel {
            visible: root.gpuTop.length > 0
            text: root.gpuTop.map(function(p) { return p.name + " " + p.usage + "%" }).join(" · ")
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.npuShown }

        Column {
          visible: root.npuShown
          width: column.width
          spacing: Style.space(6)

          EngineHeader {
            title: Model.label("NPU", root.accel.npu ? root.accel.npu.util : null)
            detail: Model.joinPresent([root.accel.npu && root.accel.npu.clock ? root.accel.npu.clock + " MHz" : null, Model.celsius(root.sample ? root.sample.temps.npu : null)])
          }
          UnitRow { name: "Scalar"; value: root.accel.npu ? root.accel.npu.util : null }
          UnitRow { name: "Vector"; value: root.accel.npu ? root.accel.npu.hvx : null; visible: value !== null }
          UnitRow { name: "Matrix"; value: root.accel.npu ? root.accel.npu.hmx : null; visible: value !== null }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.vpu !== null }

        Column {
          visible: root.vpu !== null
          width: column.width
          spacing: Style.space(6)

          EngineHeader { title: "VPU"; detail: root.vpu ? root.vpu.state : "" }
          InfoLabel {
            visible: text !== ""
            width: column.width
            text: Model.videoUsers(root.vpu)
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.tempCells.length > 0 }

        EngineHeader { title: "Thermals"; visible: root.tempCells.length > 0 }

        TileRow { cells: root.tempCells }

        PanelSeparator { foreground: root.bar.foreground; visible: root.fanCells.length > 0 }

        EngineHeader { title: "Fans"; visible: root.fanCells.length > 0 }

        TileRow { cells: root.fanCells }

        InfoLabel {
          visible: root.hot
          color: root.urgentColor
          opacity: 1
          text: root.sample && root.sample.hot ? root.sample.hot.zone + " is " + Model.celsius(root.sample.hot.temp) + ", throttles at " + Model.celsius(root.sample.hot.limit) : ""
        }

        PanelSeparator { foreground: root.bar.foreground; visible: memoryBlock.visible }

        Column {
          id: memoryBlock
          visible: Model.memory(root.sample ? root.sample.memory : null) !== null
          width: column.width
          spacing: Style.space(6)

          EngineHeader { title: "Memory"; detail: Model.memory(root.sample ? root.sample.memory : null) || "" }

          Item {
            width: column.width
            implicitHeight: Style.space(10)

            Rectangle {
              anchors.fill: parent
              radius: Style.space(3)
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)
            }
            Row {
              anchors.fill: parent
              Repeater {
                model: root.memSegments
                Rectangle {
                  required property var modelData
                  width: parent.width * modelData.fraction
                  height: parent.height
                  color: modelData.other
                    ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, modelData.alpha)
                    : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, modelData.alpha)
                }
              }
            }
          }

          Repeater {
            model: root.memSegments
            Row {
              required property var modelData
              width: column.width
              spacing: Style.space(8)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(10)
                height: Style.space(10)
                radius: Style.space(2)
                color: parent.modelData.other
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, parent.modelData.alpha)
                  : Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, parent.modelData.alpha)
              }
              InfoLabel { width: column.width - Style.space(10) - Style.space(16) - Style.space(70); text: parent.modelData.name }
              InfoValue { width: Style.space(70); horizontalAlignment: Text.AlignRight; text: Model.size(parent.modelData.kb) }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Row {
          width: column.width
          spacing: Style.space(6)

          Button {
            visible: root.nvtopAvailable
            width: (column.width - Style.space(6)) / 2
            text: "Open nvtop"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: { root.close(); root.bar.run("omarchy-launch-or-focus-tui nvtop") }
          }
          Button {
            width: root.nvtopAvailable ? (column.width - Style.space(6)) / 2 : column.width
            text: "Open btop"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: { root.close(); root.bar.run("omarchy-launch-or-focus-tui btop") }
          }
        }
      }
    }
  }

  component EngineHeader: Row {
    property string title: ""
    property string detail: ""
    width: column.width

    Text {
      id: headerTitle
      textFormat: Text.PlainText
      text: parent.title
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }
    Item { width: Math.max(0, column.width - headerTitle.implicitWidth - headerDetail.implicitWidth); height: 1 }
    InfoLabel { id: headerDetail; text: parent.detail; visible: text !== ""; anchors.verticalCenter: headerTitle.verticalCenter }
  }

  component TileRow: Row {
    id: tileRow
    property var cells: []
    visible: cells.length > 0
    width: column.width
    spacing: Style.space(8)

    Repeater {
      model: tileRow.cells
      Rectangle {
        id: tile
        required property var modelData
        width: (column.width - tileRow.spacing * (tileRow.cells.length - 1)) / tileRow.cells.length
        height: tileText.implicitHeight + Style.space(16)
        radius: Style.space(6)
        color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.06)

        Column {
          id: tileText
          anchors.centerIn: parent
          spacing: Style.space(2)
          InfoLabel { anchors.horizontalCenter: parent.horizontalCenter; text: tile.modelData.label }
          InfoValue { anchors.horizontalCenter: parent.horizontalCenter; text: tile.modelData.value; font.bold: true; font.pixelSize: Style.font.body }
        }
      }
    }
  }

  component LoadBar: Item {
    property var value: 0
    width: column.width
    implicitHeight: Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
    }
    Rectangle {
      height: parent.height
      radius: height / 2
      color: root.accentColor
      width: Math.max(parent.height, parent.width * Math.min(100, Number(parent.value) || 0) / 100)
      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    }
  }

  component UnitRow: Row {
    property string name: ""
    property var value: null
    width: column.width
    spacing: Style.space(8)

    InfoLabel { width: Style.space(56); text: parent.name }
    LoadBar { width: column.width - Style.space(56) - Style.space(44) - Style.space(16); value: parent.value; anchors.verticalCenter: parent.verticalCenter }
    InfoValue { width: Style.space(44); horizontalAlignment: Text.AlignRight; text: parent.value + "%" }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
