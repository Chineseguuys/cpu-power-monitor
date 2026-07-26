# CPU Power Monitor — 使用与原理文档

本文档总结 KDE Plasma `cpu-power-monitor` 插件的四个方面：

1. KDE 插件项目的目录结构
2. CPU 功耗的计算原理
3. 折线图绘制方案
4. 安装、卸载与使用方法

---

## 1. KDE 插件项目结构

本插件是纯 QML 的 Plasma 6 Plasmoid，没有 C++ 编译产物，所有逻辑由 QML 声明与 JavaScript 实现。目录约定遵循 KPackage 规范：

```
cpu-power-monitor/
├── package/                          ← 打包根目录，整个目录被 zip 成 .plasmoid 发布
│   ├── metadata.json                 ← KPlugin 元数据，Id=boi.walle.cpuPowerMonitor
│   └── contents/
│       ├── config/
│       │   ├── main.xml              ← KConfig schema（delay / bold / chartMaxPoints）
│       │   └── config.qml            ← 配置面板入口（声明 General 类别指向 ConfigGeneral.qml）
│       └── ui/
│           ├── main.qml              ← 主 UI 与业务逻辑
│           └── ConfigGeneral.qml     ← General 配置页 UI（SpinBox + CheckBox）
├── doc/
│   └── Usage.md                      ← 本文档
├── images/                           ← README 预览图
├── rapl.txt                          ← RAPL sysfs 节点 dump 参考样本
├── README.md
├── COPYING
└── .github/workflows/build.yml       ← CI：把 package/ zip 成 .plasmoid 发布到 release
```

### 关键约定

- **`metadata.json`**：`KPlugin.Id` 是插件的唯一标识（`boi.walle.cpuPowerMonitor`），卸载用这个 Id；`KPackageStructure` 必须为 `Plasma/Applet`。
- **`contents/`**：固定子目录名，Plasma 按约定扫描 `contents/ui/main.qml` 作为入口，`contents/config/main.xml` 作为配置 schema。
- **`.plasmoid` = `package/` 目录的 zip**，扩展名只是让 KDE 识别。CI 里就是这么打的。
- **无构建步骤**：`plasmapkg6`/`kpackagetool6` 直接对 `package/` 目录或 `.plasmoid` 文件操作，不编译任何东西。

---

## 2. CPU 功耗计算原理

### 数据来源：Intel RAPL sysfs 接口

插件不调用任何性能计数器库，直接读内核 powercap 暴露的 `intel-rapl` sysfs 文件：

- 默认路径：`/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj`
- 内容：CPU 封装（package-0）的**累计能量**，单位微焦耳（μJ），单调递增
- Intel 处理器专属；AMD 或不支持 RAPL 的机器读不到，UI 显示 `FX-PR`

`rapl.txt` 的实测样本验证了这一点：

```
intel-rapl/intel-rapl:0/name        package-0
intel-rapl/intel-rapl:0/energy_uj   73904878796    ← 累计 μJ
intel-rapl/intel-rapl:0:0/energy_uj 32612448433    ← core
intel-rapl/intel-rapl:0:1/energy_uj 88927          ← uncore
intel-rapl/intel-rapl:0:2/energy_uj 5281798063      ← dram
```

### 功率换算：差分法

RAPL 给的是累计能量，瞬时功率 = 两次采样之间能量差除以时间差：

```
P(W) = (joules_now - joules_prev) / (time_now - time_prev)
     = (energy_uj_now / 1e6 - baseNRG) / Δt
```

保留一位小数：`Math.round(... * 10) / 10`，格式化为 `"xx.x W"`。

### 数据流（修复后）

```
Timer (delay*100ms)
   └─► update() ── 只负责"拍快门"发起 cat
         │
         ▼ 异步
   DataSource.exec('cat /sys/.../energy_uj')
         │
         ▼ onNewData 回调
   handleReading(stdout)
         ├─ 解析 μJ → joules
         ├─ 首次读数：只记基准（primed=true），不算功率（避免 0→真实值污染）
         ├─ 后续：ΔE/Δt 算 p，经 sanity 过滤（p>=0 && p<1000）后 pushSample
         └─ 更新 baseNRG / baseTime 为本次读数，作为下次差分基准
                  │
                  ▼
            pushSample(p)
            ├─ history[] 环形缓冲（chartMaxPoints 个点）
            ├─ peakPower = max(peakPower, p)
            ├─ sumPower += p; sampleCount++
            └─ emit samplePushed()
                       │
                       ▼
            Canvas.requestPaint() （compact / full 各自连接）
```

核心原则：**算功率必须在 cat 真实返回那一刻做，而不是在下次 tick 用陈旧值凑算**。

### 历史采样缺陷与修复

修复前 `update()` 同步流程里用 `root.newNRG` 算功率，但 `newNRG` 是上一次 cat 返回写入的旧值（本次 cat 还没返回），导致三个叠加 Bug：

| 缺陷 | 现象 | 根因 |
|---|---|---|
| 用陈旧 `newNRG` 算 ΔE | 平均值飘到 0.x W | cat 漂移到下一 tick 后，`ΔE=0` 反复推 0 进 history |
| 乱序返回覆盖 | 出现 -1.1W 负功率 | 并发 cat 不保证 FIFO，旧返回值顶掉新值，`ΔE<0` |
| 首样本污染 peak | peak 永久停在天文数字 | `baseNRG=0` 初始化，首读 0→真实值在 tiny dt 下算出巨值 |

修复要点：
- `primed` 标志：首读只记基准不算功率
- `inFlight` 互斥：同时只有一个 cat 在跑，杜绝乱序覆盖
- `p >= 0 && p < 1000` 过滤残余异常值（RAPL 回绕、race 残留）
- `resetStats` 把 `primed=false` 也清掉，避免 reset 后用老基准算离谱值

### 权限处理

`energy_uj` 默认只对 root 可读，普通用户 `cat` 失败。插件右键菜单提供两个动作：

- **Fix Sensor Permission**：`pkexec chmod 444 <raplPath>` 临时授权，重启失效
- **Permanently Fix Permission**：把 `@reboot chmod 444 <raplPath>` 写入 `/etc/crontab`
- **Reset Statistics**：清空 history / peak / avg / 基准

---

## 3. 折线图绘制方案

### 方案选型

| 方案 | 依赖 | 改动量 | 评价 |
|---|---|---|---|
| **纯 QML `Canvas`**（采用） | 无 | ~100 行 | 零外部依赖，最贴合纯 QML widget 理念 |
| KDE `ksysguard` `LineChart` | Plasma sensor 框架 | 重构数据源 | 需把 `root.power` 包成 Sensor，与现有 `cat` 路径耦合 |
| Qt Charts QML | `qt6-charts` 包 | ~50 行 | 杀鸡用牛刀，用户可能没装该包，import 失败 |

选 Canvas：依赖最少、控制力最强、与现有打包/分发理念一致。

### 双表示架构（Plasma 6 标准）

Plasma 6 的 `PlasmoidItem` 原生支持两个表示：

- **`compactRepresentation`**：面板（taskbar）里的精简 UI
- **`fullRepresentation`**：弹出浮窗 / 桌面 widget 本体

关键点：Plasma 6 **不会自动**给 `compactRepresentation` 绑定"点击展开 popup"的行为，必须在 `compactRepresentation` 内显式声明 `MouseArea` 并调用 `root.expanded = !root.expanded`。这是 Plasma 6 与 5 的关键差异。

```qml
compactRepresentation: Item {
    Layout.preferredWidth: 48
    Layout.fillHeight: true

    Canvas { /* 迷你折线，纯图无字 */ }

    MouseArea {
        anchors.fill: parent
        onClicked: root.expanded = !root.expanded   // ← 必须显式声明
    }
}
```

### 绘制逻辑

`drawChart(ctx, w, h, data, opts)` 是共享函数，被 compact / full 两个 Canvas 复用：

- **Y 轴自适应**：`yMax = max(history, 1) * 1.1`，低功耗时也清晰
- **可选网格**：big chart 画 4 条水平网格线，mini chart 不画
- **可选填充**：big chart 在折线下方画半透明填充区（透明度 0.18）
- **颜色**：统一用 `Kirigami.Theme.textColor`，自动适配深浅主题

### 数据与渲染解耦

`compactRepresentation` 和 `fullRepresentation` 按需实例化，未必同时存在。用 `samplePushed()` 信号 + 各 `Canvas` 内 `Connections` 监听，未实例化的一侧不会触发空指针。

### 配置项

| 配置 | 类型 | 默认 | 作用 |
|---|---|---|---|
| `delay` | Double | 1.0 | 采样间隔（秒，实际 ×100ms） |
| `bold` | Bool | false | 文字加粗 |
| `chartMaxPoints` | Int | 120 | 折线图历史点数，范围 10–1000 |

---

## 4. 安装、卸载与使用

### 命令名更正

Plasma 6 时代没有 `plasmapkg6` 这个命令。Manjaro / Arch 上实际工具是 **`kpackagetool6`**。`plasmapkg2` 只是 Plasma 5 时代残留的兼容入口。

### 安装

#### 方式 A：从 KDE 商店在线安装（README 推荐）

1. 桌面右键 → `Enter Edit Mode` → `Add or Manage Widgets`
2. `Get New` → `Download New Plasma Widgets`
3. 搜索 `CPU Power Monitor` → Install

#### 方式 B：本地手动安装 `.plasmoid` 文件

```bash
kpackagetool6 -i cpmPlasma6.plasmoid --type Plasma/Applet
systemctl --user restart plasma-plasmashell.service
```

#### 方式 C：从源码直接安装（开发调试用）

```bash
cd /path/to/cpu-power-monitor

# 首次安装
kpackagetool6 -i package --type Plasma/Applet

# 代码变更后升级（已安装时必须用 -u，-i 遇到同名会失败）
kpackagetool6 -u package --type Plasma/Applet

# 重启 plasmashell 让其重新扫描
systemctl --user restart plasma-plasmashell.service
```

### 验证安装是否可用（分层确认）

```bash
ID=boi.walle.cpuPowerMonitor
DIR=~/.local/share/plasma/plasmoids/$ID

# [1] 注册表：kpackagetool6 能读出元数据
kpackagetool6 --show "$ID" --type Plasma/Applet | head -5
# 期望输出：名称：CPU Power Monitor / 描述 / 插件ID / 路径

# [2] 落地文件：关键文件确实存在
ls "$DIR/contents/ui/main.qml" "$DIR/metadata.json"

# [3] 重新扫描：让 plasmashell 发现新插件
systemctl --user restart plasma-plasmashell.service

# [4] 运行时：GUI Add Widgets 搜索能找到
qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.toggleWidgetExplorer
# 在弹出面板搜 "CPU Power"，搜到即通过

# [5] 传感器可读：数据通路活着
ls -l /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj
# 期望 -r--r--r-- 或至少当前用户可读
cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj
# 期望单调递增的大整数（μJ）
```

### 使用

1. 桌面或面板空白处右键 → `Enter Edit Mode` → `Add Widgets`
2. 找到 `CPU Power Monitor`，拖到桌面或 taskbar
3. 首次出现若显示 `FX-PR`：右键 widget → `Fix Sensor Permission` → 输入密码授权一次
4. 面板里显示迷你折线图（无数字），点击展开浮窗显示大折线 + 当前功率 + 峰值/平均

### 配置

右键 widget → `Configure CPU Power Monitor`：

- **Update Delay**：采样间隔（0.1–10 秒）
- **Use Bold Text**：当前功率加粗
- **Chart Points**：折线图历史点数（10–1000，默认 120）

### 卸载

#### 只删除 widget 实例（保留插件包）

进入 Edit Mode，点 widget 上的 ✕ 即可。

#### 彻底卸载插件包

```bash
# 用 metadata.json 里的 KPlugin.Id，不是文件名也不是 Name
kpackagetool6 -r boi.walle.cpuPowerMonitor --type Plasma/Applet
```

#### 清理权限改动（可选）

- **临时授权**：重启后自动失效，无需手动清理
- **永久授权**：编辑 `/etc/crontab`，删除那行 `@reboot chmod 444 /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj`

### 卸载后验证

```bash
kpackagetool6 --show boi.walle.cpuPowerMonitor --type Plasma/Applet
# 退出码非 0 / 报 "不存在的包" 即为卸载成功
ls ~/.local/share/plasma/plasmoids/boi.walle.cpuPowerMonitor/
# 目录应已删除
```

### 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| 显示 `FX-PR` | `energy_uj` 不可读 / 处理器不支持 RAPL | 右键 `Fix Sensor Permission`；AMD 处理器无解 |
| `plasmapkg6: command not found` | Plasma 6 没有此命令 | 用 `kpackagetool6 --type Plasma/Applet` |
| `-i` 安装报已存在 | 同名插件已安装 | 改用 `-u` 升级，或先 `-r` 卸载再 `-i` |
| Add Widgets 搜不到 | plasmashell 未重新扫描 | `systemctl --user restart plasma-plasmashell.service` |
| 点击面板 widget 不弹窗 | Plasma 6 不自动绑定点击展开 | 确认 `compactRepresentation` 内有 `MouseArea` + `onClicked: root.expanded = !root.expanded` |
| 平均功率异常（0.x / 负值） | 旧版用陈旧 `newNRG` 算差分 | 已修复，确保部署的是 ≥ 0.6 版本 |
```