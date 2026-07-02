# player-launcher 架构文档

> 面向下次改代码的你。读完再动手，省得重踩坑。

---

## 一句话

`player-launcher.ahk`（AutoHotkey v2）是 mpv.net 的独立播放列表 GUI。双击视频 → launcher 启动，扫描同目录视频/音频，通过 **Windows 命名管道 IPC** 让 mpv.net 无缝换片，配合时长、大小、已看标记、自动 Snap 等元数据。

- 语言：AutoHotkey v2
- 依赖：`mpvnet.exe`（IPC 端点）+ `MediaInfo.dll`（读时长）
- 单实例：`CreateMutexW` 会话级 mutex

---

## 布局约束（**launcher 必须放在 mpv.net 根目录**）

```
mpv.net/                          ← 分发根目录 = A_ScriptDir
├─ mpvnet.exe
├─ libmpv-2.dll
├─ MediaInfo.dll
├─ ffmpeg.exe
├─ portable_config/
│   └─ mpv.conf                   ← 必须含 input-ipc-server=\\.\pipe\mpvnet_launcher
├─ player-launcher.exe            ← Ahk2Exe 编译产物
└─ watched.json                   ← 运行时生成
```

---

## 主流程（脚本从上到下的 auto-execute 段）

```
1. 全局常量 & 状态声明
2. LoadWatchedSet()             加载已看
3. 单实例判定（CreateMutexW）
   ├─ 副本：EnsureMpvRunning + LoadFileIntoMpv + ExitApp
   └─ 首实例：继续
4. BuildGui()                   建 GUI + 置顶 + 注册热键
5. 带参数：EnsureMpvRunning + LoadFileIntoMpv + LoadDirectoryFromPath
6. InitIpcReader()              建读通道 + observe_property
7. SetTimer(PollMpvEvents, 200)
8. InstallCustomDraw()          WM_NOTIFY 拦截，用于灰色行
9. return
```

后续全是事件驱动：GUI 回调、定时器、Hotkey。

---

## 模块划分

| 段 | 大致行号 | 职责 |
|---|---|---|
| 全局常量与状态 | 1-100 | 所有 `global` 变量，AHK v2 要求 auto-execute 段声明 |
| 单实例 | 100-150 | mutex + 副本流程 |
| GUI 构建 | 135-250 | `BuildGui / OnGuiResize / OnSearchChanged / OnOpenFolder / OnListDoubleClick / OnColClick / OnDropFiles / HandleEnterPlay` |
| 目录扫描 & 渲染 | 265-360 | `LoadDirectoryList / RenderList / IsPlayingFile / IsMediaExt / FormatFileSize / ApplyCurrentSort / CompareItem` |
| MediaInfo 时长 | 435-540 | `ScanDurationsWorker / EnsureMediaInfoLoaded / GetMediaDurationDetailed / FormatDuration` |
| mpv IPC | 555-635 | `EnsureMpvRunning / TryPingMpv / LoadFileIntoMpv / OpenMpvPipe / IpcSendFireAndForget / OpenReadPipe` |
| 单实例 mutex | 640-660 | `CreateSingletonMutex` |
| IPC 事件轮询 | 665-810 | `InitIpcReader / PollMpvEvents / HandleMpvEvent / ExtractJsonString / PlayNextInList / RefreshCurrentSearch` |
| 已看过 | 815-920 | `NormPath / IsWatched / MarkAsWatched / UpdateWatchedFlagsInList / LoadWatchedSet / SaveWatchedSet / ArrayJoin` |
| 删除到回收站 | 925-1010 | `HandleDeleteFile / MoveToRecycleBin` |
| Custom Draw 灰色行 | 1015-1090 | `LV_OnNotify / InstallCustomDraw` |
| Snap | 1095-1210 | `HandleSnapHotkey / SnapToMpvWindow / FindMpvWindow / GetWindowRect / GetWorkAreaForWindow / SnapLog` |

---

## IPC 协议

### mpv IPC 命名管道

- 服务端：mpvnet.exe（由 `mpv.conf` 里 `input-ipc-server=\\.\pipe\mpvnet_launcher` 启动）
- 客户端：launcher.exe

### 写通道（fire-and-forget）

```
每次发命令 → CreateFileW 打开管道 → WriteFile → CloseHandle
```

**核心**：**只写不读**，避免 `FileOpen(...,"rw")` 的 `ReadLine` 阻塞 GUI。

主要命令：

| 命令 | 用途 |
|---|---|
| `{"command":["loadfile","<path>","replace"]}` | 切换播放文件 |
| `{"command":["observe_property",1,"path"]}` | 订阅 path 变化（用于 ▶ 高亮） |
| `{"command":["set_property","pause",true]}` | 到最后一集后暂停 |

### 读通道（持久）

`OpenReadPipe()` 建一次持久句柄，`SetTimer(PollMpvEvents, 200)`：
1. `PeekNamedPipe` 非阻塞探测是否有数据
2. 有数据 `ReadFile`
3. UTF-8 解码 + 拼行缓冲 + 按 `\n` 切完整行
4. 派发给 `HandleMpvEvent`

**关键事件**：
- `event:property-change, name:path` → 更新 `gCurrentPlayingPath`（用于 ▶ 高亮，**不再触发 Snap**）
- `event:end-file, reason:eof` → 标记已看 + 自动播下一集

管道断开 → `PeekNamedPipe` 返回 0 → 关句柄 → 下次 Poll 自动重连。

---

## Snap 机制

**触发点**：`LoadFileIntoMpv` 内部，每次成功 loadfile 后 300ms 触发 `SnapToMpvWindow(15)`。

这样 4 条播放触发路径全部覆盖：
- 拖视频（OnDropFiles）
- 双击列表（OnListDoubleClick）
- 首启带参（gArg）
- 自动下一集（PlayNextInList）

**为什么不用 mpv path 事件触发**：曾经用过，但 mpv 冷启动/首次 loadfile 时 path 事件推送时机不稳定，改成自己触发更可靠。

`SnapToMpvWindow(retriesLeft)`：
- 找 mpv 窗口（`WinExist("ahk_exe mpvnet.exe")`）
- 判断窗口尺寸 ≥ 100×100（避免 mpv 冷启动时窗口未就位）
- 未就绪 → 200ms 后重试，最多 15 次（共 3 秒）
- 就绪 → `SetWindowPos` 到 mpv 左侧，垂直上对齐，工作区边界钳制

**launcher 常驻置顶**：`BuildGui` 结尾用 `WinSetAlwaysOnTop(true, ...)`，全屏 mpv 也能看到。

---

## 排序

- ListView 去掉原生 `Sort` 选项，避免 ▶ 前缀让当前行排到最前
- `OnColClick` 事件接管 → 更新 `gSortCol/gSortAsc` → `ApplyCurrentSort()` → `RenderList`
- 数字列按数字比（`durationMs / sizeBytes`）；字符串列按 `StrCompare`

---

## 已看过 = 灰色行

**Windows Custom Draw**（`NM_CUSTOMDRAW` 通过 `WM_NOTIFY`）：

- `OnMessage(0x4E, LV_OnNotify)` 挂 WM_NOTIFY
- 收到 `code=-12` 且是自己的 ListView：
  - `dwDrawStage=1` → 返回 `0x20`（CDRF_NOTIFYITEMDRAW）
  - `dwDrawStage=0x10001` → 读 **offset 56** 的 `dwItemSpec`（0-based 行号）→ 反查文件项 → 已看则改 **offset 80** 的 `clrText = 0x808080` → 返回 `0x2`（CDRF_NEWFONT）

**关键坑**：`dwItemSpec` 在 x64 下位于 `NMHDR(24) + dwDrawStage+pad(8) + hdc(8) + rc(16) = 56` 字节偏移，不是 40 或 48。

---

## 已知踩过的坑（记住！）

1. **AHK v2 `FileOpen("\\.\pipe\...", "rw")` 会阻塞 GUI**——`ReadLine` 无数据死等。必须走 DllCall。
2. **`global` 变量必须放 auto-execute 段（顶部 return 前）**声明，函数才能读到。放到 return 之后会报 "This line will never execute" 且函数里访问是 unset。
3. **DllCall 出参必须先 `var := 0` 再 `&var`**，AHK v2 判 "local variable has not been assigned"。
4. **INVALID_HANDLE 在 64 位是 `0xFFFFFFFFFFFFFFFF` 不是 -1**，两个都要判。
5. **AHK `Format` 的 `{{` `}}` 转义会踩坑**，JSON 场景直接字符串拼接：`'{"key":"' val '"}'`。
6. **MediaInfo `Duration` 参数**：`InfoKind=1, SearchKind=0` 才返回值；`InfoKind=0` 返回参数名而非值。
7. **AHK ListView 原生 Sort 会破坏 ▶ 顺序**——去掉 `Sort` + 接管 `ColClick`。
8. **`MsgBox` v2 用 `"YesNo Icon?"`**，v1 的 `IconQuestion 262144` 会报 Invalid option。
9. **NMLVCUSTOMDRAW x64 偏移**：`dwItemSpec@56`，`clrText@80`。之前算成 40 导致灰色不生效。
10. **Snap 不能追着窗口跑**（性能坑）。改成每次 loadfile 触发 + Ctrl+L 手动兜底。
11. **Ahk2Exe 不随 AHK v2 主程序附带**，需单独下载 zip 到 `C:\Program Files\AutoHotkey\Compiler\` 解压。
12. **Snap 位置计算基于 mpv 窗口矩形**——mpv 最大化时 launcher 会塞在窗口内侧左边，靠 `WinSetAlwaysOnTop` 保证可见。

---

## 扩展场景速查

### 加新的表格列

1. `BuildGui` 的 `myGui.Add("ListView", ..., [...新列名])`
2. `ModifyCol` 加宽度
3. `LoadDirectoryList` 文件对象加字段
4. `RenderList` 里 `gLV.Add()` 补参数
5. 排序：在 `CompareItem` 的 `switch` 加 `case`
6. 如果扩展名列号变了，`OnListDoubleClick` 里的 `GetText(rowNum, N)` N 要同步

### 加新的 mpv IPC 命令

```
IpcSendFireAndForget('{"command":["<cmd>","<arg>"]}')
```

参考 [mpv IPC 文档](https://mpv.io/manual/master/#json-ipc)。

### 加新的键盘热键

`BuildGui` 结尾的 `HotIfWinactive` 块里加：

```ahk
Hotkey("F5", HandleXxx, "On")
```

函数体里通过 `gLV.GetNext(0)` 拿当前行。

### 加新的 mpv 事件订阅

1. `InitIpcReader` 里发 `{"command":["observe_property",<id>,"<prop>"]}` 或 `{"command":["enable_event","<evt>"]}`
2. `HandleMpvEvent` 加 `if InStr(line, '"event":"..."')` 分支

### 打包为 exe

```
"C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" ^
  /in "player-launcher.ahk" ^
  /out "player-launcher.exe" ^
  /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

Ahk2Exe 首次装：从 https://github.com/AutoHotkey/Ahk2Exe/releases/latest 下 zip，解压到 `C:\Program Files\AutoHotkey\Compiler\`。

### 打开诊断日志

`SnapLog` 函数默认返回，如需排查把里面的 `return` 注释掉即可。日志写到 `A_ScriptDir\_snap_debug.log`。

---

## v1.0 未做的功能（future）

- 缩略图悬浮预览（ffmpeg 抽帧 + Tooltip）
- 续播（读取 mpv 的 watch-later）
- 递归扫子文件夹
- 最近文件夹历史下拉
- 播放速度按钮
- 字幕状态列
- 拖多文件追加播放列表

---

## 版本

- **v1.0** · 2026-07-02
  - IPC 无缝切换 / MediaInfo 时长 / 文件大小自动单位
  - 键盘 ↑↓/Enter/Delete
  - ▶ 高亮 + 灰色已看 + 自动下一集
  - 表头点击排序 / 窗口 Resize 自适应
  - Snap 自动贴 mpv 左侧 + Ctrl+L 手动 / 常驻置顶
  - 单文件 exe（Ahk2Exe），1.3 MB
