/*
 * Copyright 2026 Phani Pavan K <kphanipavan@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http: //www.gnu.org/licenses/gpl-3.0.html>.
 */

import QtQuick
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

PlasmoidItem { // Main component of the plasmoid
    id: root // Reference name of the main component

    // ---- Display state ----
    property var power: "FX-PR"           // String shown in the big label ("xx.x W" or "FX-PR")
    property double baseNRG: 0           // 上一次成功采样时记录的累计能量 J（差分基准）
    property double baseTime: 0          // 上一次成功采样的时间戳 ms
    property bool primed: false           // 是否已采到首个基准样本：未 primed 时只记基准不算功率，
                                           // 避免 0→真实值 在 tiny dt 下算出天文功率污染 peak/history
    property bool inFlight: false          // 是否有 cat 在路上：避免请求堆积 / 乱序覆盖（旧返回值顶掉新返回值会算出负功率）
    property string raplPath: "/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj"

    // ---- Chart state ----
    property var history: []              // Ring buffer of recent power samples (numbers, W)
    property real peakPower: 0            // Max power seen since launch
    property real sumPower: 0            // Sum of samples, for running average
    property int sampleCount: 0          // Number of samples collected

    // Emitted whenever a new sample is pushed; canvases connect to it to repaint.
    // Decouples the data path from whichever representation is currently instantiated.
    signal samplePushed()

    // ---- Command execution engine. Runs cat / chmod ----
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            // cat 返回后立刻处理（与 sysfs 真实读出时刻对齐），不再等下次 update()
            // 用陈旧 newNRG 算差；chmod 无输出走同一路径会被 handleReading 当作无效读数过滤。
            var stdout = data["stdout"];
            disconnectSource(source);
            handleReading(stdout);
        }

        function exec(cmd) {
            executable.connectSource(cmd);
        }
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Fix Sensor Permission")
            icon.name: "view-refresh"
            onTriggered: fixPermission()
        },
        PlasmaCore.Action {
            text: i18n("Permanently Fix Permission")
            icon.name: "list-add"
            onTriggered: addPermFixCron()
        },
        PlasmaCore.Action {
            // Reset the rolling statistics; useful after a permission fix re-enables sampling.
            text: i18n("Reset Statistics")
            icon.name: "edit-clear"
            onTriggered: resetStats()
        }
    ]

    function fixPermission() {
        executable.exec(["pkexec", "chmod", "444", root.raplPath].join(" "));
    }

    function addPermFixCron() {
        executable.exec(["grep", root.raplPath, "/etc/crontab", "||", "echo", "@reboot", "chmod", "444", root.raplPath, "|", "pkexec", "tee", "/etc/crontab"].join(" "));
    }

    function resetStats() {
        root.history = [];
        root.peakPower = 0;
        root.sumPower = 0;
        root.sampleCount = 0;
        // 基准也清掉，下一个读数重新当作 primed 起点；否则 reset 后用老 baseNRG 算差仍可能离谱。
        root.primed = false;
        root.baseNRG = 0;
        root.baseTime = 0;
        // inFlight 留给 handleReading 自然清，避免压住一个已完成的请求状态。
        root.samplePushed();
    }

    // Push one numeric sample into the ring buffer and update rolling stats.
    // Non-numeric / NaN samples (e.g. during the FX-PR state) are ignored so the chart
    // doesn't get polluted with sentinel values.
    function pushSample(p) {
        if (typeof p !== "number" || isNaN(p))
            return;
        var h = root.history;
        h.push(p);
        var max = plasmoid.configuration.chartMaxPoints;
        while (h.length > max)
            h.shift();
        if (p > root.peakPower)
            root.peakPower = p;
        root.sumPower += p;
        root.sampleCount += 1;
        root.samplePushed();
    }

    function update() {
        // Timer 只负责"拍快门"发起 cat —— 真正的 ΔE/Δt 算在 onNewData 那侧，因为只有
        // cat 真实返回那一刻对应的能量与时间戳才有意义。原代码在 update() 同步流程里
        // 用陈旧的 root.newNRG 算功率，导致：(a) cat 比 tick 慢时 ΔE=0 持续推 0 进 history，
        // 把平均拉到 0.x W；(b) 乱序返回时旧新值颠倒ΔE<0，推负值进 history。
        if (root.inFlight)
            return;
        root.inFlight = true;
        executable.exec('cat ' + root.raplPath);
    }

    // cat 真实返回时调用：用本次读数与上次基准做差分算功率，
    // 再经 sanity filter 投入 history，避免脏样本腐蚀 peak/avg/折线。
    function handleReading(stdout) {
        root.inFlight = false;
        var raw = String(stdout).trim();
        var parsed = parseInt(raw);
        // 不可读（权限不足 / 传感器不存在）→ 显示 FX-PR；基准不动，下次读出仍可与上次正常差分。
        if (raw === "" || isNaN(parsed) || parsed <= 0) {
            root.power = "FX-PR";
            return;
        }
        var joules = parsed / 1e+06;
        var now = (new Date).getTime();
        if (root.primed) {
            var dt = (now - root.baseTime) / 1000;
            if (dt > 0) {
                var p = Math.round((joules - root.baseNRG) * 10 / dt) / 10;
                // 过滤异常样本：负值（RAPL 回绕 / 残留乱序）和夸张巨值都不进 history。
                if (p >= 0 && p < 1000) {
                    root.power = Number.isInteger(p) ? p + ".0 W" : p + " W";
                    pushSample(p);
                }
            }
        }
        // 每次有效读数都更新基准，即便本轮 p 被过滤，避免下轮用旧基准算出离谱值。
        root.baseNRG = joules;
        root.baseTime = now;
        root.primed = true;
    }

    // Shared chart renderer used by both the mini and the big Canvas.
    // Adaptive Y range = max(history) * 1.1 with a 1W floor, so idle CPUs still show
    // a visible waveform instead of a flat line at the bottom.
    function drawChart(ctx, w, h, data, opts) {
        // opts: { stroke, fill, lineWidth, showGrid, gridColor }
        ctx.reset();
        ctx.clearRect(0, 0, w, h);
        var n = data.length;
        if (n < 2)
            return;

        var peak = 1;
        for (var i = 0; i < n; ++i)
            if (data[i] > peak) peak = data[i];
        var yMax = Math.max(peak, 1) * 1.1;

        var pad = opts.showGrid ? 8 : 0;
        var gw = w - pad * 2;
        var gh = h - pad * 2;
        if (gw <= 0 || gh <= 0)
            return;

        if (opts.showGrid && opts.gridColor) {
            ctx.strokeStyle = opts.gridColor;
            ctx.lineWidth = 1;
            for (var g = 0; g <= 4; ++g) {
                var gy = pad + gh * g / 4;
                ctx.beginPath();
                ctx.moveTo(pad, gy);
                ctx.lineTo(w - pad, gy);
                ctx.stroke();
            }
        }

        // Filled area under the curve (big chart only).
        if (opts.fill) {
            ctx.beginPath();
            for (var j = 0; j < n; ++j) {
                var x = pad + gw * j / (n - 1);
                var y = pad + gh - gh * (data[j] / yMax);
                if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
            }
            ctx.lineTo(pad + gw, pad + gh);
            ctx.lineTo(pad, pad + gh);
            ctx.closePath();
            ctx.fillStyle = opts.fill;
            ctx.fill();
        }

        // The line itself.
        ctx.strokeStyle = opts.stroke;
        ctx.lineWidth = opts.lineWidth;
        ctx.beginPath();
        for (var k = 0; k < n; ++k) {
            var px = pad + gw * k / (n - 1);
            var py = pad + gh - gh * (data[k] / yMax);
            if (k === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
        }
        ctx.stroke();
    }

    // ---- Compact representation: panel strip, chart only, no text ----
    // Plasma 6 的 PlasmoidItem 不会自动给 compactRepresentation 绑定"点击展开 popup"
    // 的行为 —— 这是 plasma 6 与 5 的关键差异。官方自带的 systemmonitor / kdeconnect
    // 都在 compactRepresentation 内显式声明 MouseArea 并调用 root.expanded = !root.expanded。
    // 没有这个 MouseArea，panel 上的点击事件无处可去，popup 永远不弹出。
    compactRepresentation: Item {
        // Prefer a square-ish strip on horizontal panels; vertical panels fall back to fill.
        Layout.preferredWidth: 48
        Layout.fillHeight: true

        Canvas {
            id: miniChart
            anchors.fill: parent
            renderStrategy: Canvas.Threaded

            Connections {
                target: root
                function onSamplePushed() { miniChart.requestPaint() }
            }

            onPaint: {
                var ctx = miniChart.getContext("2d");
                root.drawChart(ctx, miniChart.width, miniChart.height, root.history, {
                    stroke: Kirigami.Theme.textColor,
                    fill: Qt.rgba(0, 0, 0, 0),
                    lineWidth: 1.5,
                    showGrid: false
                });
            }
        }

        // 点击 toggle popup —— Plasma 6 标准协议, PlasmoidItem 不代劳。
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expanded = !root.expanded
        }
    }

    // ---- Full representation: popup / desktop, large chart + current + peak/avg ----
    fullRepresentation: ColumnLayout {
        id: popup
        Layout.minimumWidth: 240
        Layout.minimumHeight: 200
        spacing: Kirigami.Units.smallSpacing

        // Current power, big.
        PlasmaComponents.Label {
            text: root.power
            font.bold: plasmoid.configuration.bold
            font.pixelSize: Kirigami.Units.gridUnit * 3
            fontSizeMode: Text.Fit
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
        }

        // Peak / average row.
        RowLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            PlasmaComponents.Label {
                text: i18n("Peak: %1 W", root.peakPower.toFixed(1))
                opacity: 0.8
            }
            PlasmaComponents.Label {
                text: i18n("Avg: %1 W", root.sampleCount > 0 ? (root.sumPower / root.sampleCount).toFixed(1) : "0.0")
                opacity: 0.8
            }
        }

        // Large chart with grid + filled area.
        Canvas {
            id: bigChart
            Layout.fillWidth: true
            Layout.fillHeight: true
            renderStrategy: Canvas.Threaded

            Connections {
                target: root
                function onSamplePushed() { bigChart.requestPaint() }
            }

            onPaint: {
                var ctx = bigChart.getContext("2d");
                root.drawChart(ctx, bigChart.width, bigChart.height, root.history, {
                    stroke: Kirigami.Theme.textColor,
                    fill: Qt.rgba(Kirigami.Theme.textColor.r,
                                  Kirigami.Theme.textColor.g,
                                  Kirigami.Theme.textColor.b, 0.18),
                    lineWidth: 2,
                    showGrid: true,
                    gridColor: Qt.rgba(1, 1, 1, 0.08)
                });
            }
        }
    }

    Timer {
        // Repeating trigger which calls the update function
        interval: plasmoid.configuration.delay * 100
        repeat: true
        running: true
        onTriggered: update()
    }
}