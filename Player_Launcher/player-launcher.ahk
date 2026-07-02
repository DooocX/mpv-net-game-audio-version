;================================================================
;  player-launcher.ahk  (AutoHotkey v2)
;  为 mpv.net 配套的极简播放列表启动器
;
;  用法：
;    player-launcher.exe                → 空 GUI（idle 状态）
;    player-launcher.exe "D:/vid.mp4"   → 播放该文件 + 列出同目录其他视频
;
;  核心机制：
;    - mpv.net 通过 mpv.conf 里 input-ipc-server=\\.\pipe\mpvnet_launcher 开管道
;    - launcher 首启 → 拉起 mpvnet.exe → 连接管道 → 通过 IPC loadfile
;    - 后续再次双击视频文件：会再启一个 launcher，但它探测到管道已存在，
;      直接 IPC loadfile 后退出（不弹新 GUI），实现"同一个 mpv、同一个列表"
;
;  作者：DocX / Jeff
;================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off  ; 我们自己做基于 mutex 的单例

;---------------- 配置 ----------------
; launcher 会按下面顺序查找 mpvnet.exe：
;   1) 与 launcher 同目录（编译分发时）
;   2) 开发期硬编码兜底路径
;   3) 系统 PATH 里的 mpvnet.exe
global MPV_EXE := ResolveMpvExe()

ResolveMpvExe() {
    candidates := [
        A_ScriptDir "\mpvnet.exe",
        "E:\Software\mpv.net\mpvnet.exe",
    ]
    for p in candidates {
        if FileExist(p)
            return p
    }
    return "mpvnet.exe"    ; 交给系统 PATH
}

global MPV_IPC_PIPE  := "\\.\pipe\mpvnet_launcher"      ; 与 mpv.conf 保持一致
global MUTEX_NAME    := "PlayerLauncherSingletonMutex_DocX"    ; 会话级单例
global VIDEO_EXTS    := ["mp4","mkv","mov","avi","wmv","flv","webm","mpg","mpeg","m4v","ts","rmvb","3gp","ogv"]
global AUDIO_EXTS    := ["mp3","wav","flac","m4a","ogg","opus","wma","ac3","dts","aac"]

; Win32 常量（必须在 auto-execute 段内声明，否则函数里访问会拿到 unset）
global GENERIC_READ   := 0x80000000
global GENERIC_WRITE  := 0x40000000
global OPEN_EXISTING  := 3
global PIPE_BUFSIZE   := 8192

; 持久 IPC 读通道句柄和行缓冲
global gReadPipe := 0
global gReadBuf  := ""
global gCurrentPlayingPath := ""
global gAutoNextEnabled := true

; Snap 状态：记录上次已 snap 过的 mpv 窗口路径，避免每次事件都重复摆
global gSnappedForPath := ""

; MediaInfo.dll 全局句柄（懒加载）
global gMediaInfoDll := 0
global gMediaInfoDllPath := ""

; 时长扫描游标
global gScanIndex := 0
global gScanBatch := 5

; 排序状态（表头点击接管）
; sortCol 值：1=文件名 / 2=时长 / 3=大小 / 4=扩展
; sortAsc  true 升序 / false 降序
global gSortCol := 1
global gSortAsc := true

; 布局常量（Resize 使用），必须在 auto-execute 段声明
global LP_MARGIN     := 8
global LP_BTN_OPEN_W := 80
global LP_BTN_REF_W  := 60
global LP_BTN_GAP    := 8
global LP_TOP_H      := 32
global LP_STATUS_H   := 20

; 会被 Resize 更新的按钮引用
global gBtnOpen := 0
global gBtnRefresh := 0

; 已看过标记：Map(路径归一化字符串 -> true)
global gWatchedSet := Map()
global gWatchedFile := A_ScriptDir "\watched.json"
LoadWatchedSet()

global gArg := (A_Args.Length >= 1 ? A_Args[1] : "")

;---------------- 单实例判定 ----------------
; 用 Windows 内核 mutex 判断：抢到 → 首实例，抢不到 → 副本
;   - 副本仅：拉起 mpv（如未运行）+ IPC loadfile + 退出，不弹 GUI
;   - 首实例：正常构建 GUI，从此常驻
gMutexHandle := CreateSingletonMutex(MUTEX_NAME)
if gMutexHandle = 0 {
    ; 副本流程
    if gArg != "" {
        EnsureMpvRunning()
        LoadFileIntoMpv(gArg)
    }
    ExitApp
}

;---------------- 首个实例：构建 GUI ----------------
global gCurrentDir := ""
global gAllFiles   := []
global gMainGui, gLV, gSearchEdit, gStatus

BuildGui()

; 启动带参 → 拉起 mpv + 加载目录列表
if gArg != "" {
    EnsureMpvRunning()
    LoadFileIntoMpv(gArg)
    LoadDirectoryFromPath(gArg)
} else {
    EnsureMpvRunning()
    UpdateStatus("就绪 · 拖入视频文件或点『打开文件夹』")
}

; Step 3.2-3.4：建立 IPC 读通道 + 订阅事件 + 启动 200ms 轮询
InitIpcReader()
SetTimer(PollMpvEvents, 200)

; 安装 ListView Custom Draw（灰色已看过行）
InstallCustomDraw()
return

;================================================================
; GUI
;================================================================
BuildGui() {
    global gMainGui, gLV, gSearchEdit, gStatus, gBtnOpen, gBtnRefresh

    myGui := Gui("+Resize +MinSize420x320", "播放列表")
    myGui.OnEvent("Close", (*) => ExitApp())
    myGui.OnEvent("Escape", (*) => myGui.Hide())
    myGui.OnEvent("Size", OnGuiResize)
    myGui.MarginX := LP_MARGIN, myGui.MarginY := LP_MARGIN
    myGui.SetFont("s10", "Microsoft YaHei UI")

    myGui.Add("Text", "x8 y10 w40", "搜索:")
    gSearchEdit := myGui.Add("Edit", "x50 y8 w200 h24")
    gSearchEdit.OnEvent("Change", OnSearchChanged)

    gBtnOpen    := myGui.Add("Button", "x260 y8 w" LP_BTN_OPEN_W " h24", "打开文件夹")
    gBtnOpen.OnEvent("Click", OnOpenFolder)
    gBtnRefresh := myGui.Add("Button", "x348 y8 w" LP_BTN_REF_W " h24", "刷新")
    gBtnRefresh.OnEvent("Click", (*) => (gCurrentDir != "" ? LoadDirectoryList(gCurrentDir) : ""))

    ; ListView：4 列，去掉 Sort，我们自己接管 ColClick
    gLV := myGui.Add("ListView", "x8 y40 w500 h380 -Multi Grid -LV0x10 +LV0x10000", ["文件名","时长","大小","扩展"])
    gLV.ModifyCol(1, 300)
    gLV.ModifyCol(2, 60)
    gLV.ModifyCol(3, 80)
    gLV.ModifyCol(4, 50)
    gLV.OnEvent("DoubleClick", OnListDoubleClick)
    gLV.OnEvent("ColClick", OnColClick)

    gStatus := myGui.Add("Text", "x8 y426 w500 h" LP_STATUS_H, "启动中...")

    ; 支持拖入文件到窗口
    myGui.OnEvent("DropFiles", OnDropFiles)

    myGui.Show("w520 h456")
    gMainGui := myGui

    ; 一直置顶（悬浮于 mpv 之上）
    WinSetAlwaysOnTop(true, "ahk_id " myGui.Hwnd)

    ; 注册热键（作用域：仅当 launcher 窗口激活）
    HotIfWinactive("ahk_id " myGui.Hwnd)
    Hotkey("Enter", HandleEnterPlay, "On")
    Hotkey("NumpadEnter", HandleEnterPlay, "On")
    Hotkey("Delete", HandleDeleteFile, "On")
    Hotkey("^l", HandleSnapHotkey, "On")     ; Ctrl+L 手动 Snap
    HotIf()
    ; 全局 Ctrl+L 也生效：即便焦点在 mpv 窗口
    Hotkey("~^l", HandleSnapHotkey, "On")
}

; Enter：播放当前 ListView 选中行；播放后保持该行为已聚焦/已选中，↑↓ 从这行继续
HandleEnterPlay(*) {
    global gLV
    if !IsSet(gLV)
        return
    row := gLV.GetNext(0)
    if row < 1 {
        ; 无选中：如果有焦点行就用它，否则用第一行
        focusedRow := gLV.GetNext(0, "F")
        row := focusedRow > 0 ? focusedRow : 1
    }
    OnListDoubleClick(gLV, row)
    ; 保持选中 + 焦点在该行，方便下一次 ↑↓ 从这里继续移动
    try {
        gLV.Modify(0, "-Select -Focus")
        gLV.Modify(row, "Select Focus Vis")
        gLV.Focus()
    }
}

; 窗口尺寸变化：把搜索框、ListView、状态栏、按钮位置重新排布
OnGuiResize(guiObj, minMax, width, height) {
    global gSearchEdit, gBtnOpen, gBtnRefresh, gLV, gStatus
    if minMax = -1
        return    ; 最小化时不动
    if !IsSet(gLV)
        return

    ; 顶部：按钮固定右上，搜索框动态延伸到按钮左边
    btnRefX := width - LP_MARGIN - LP_BTN_REF_W
    btnOpenX := btnRefX - LP_BTN_GAP - LP_BTN_OPEN_W
    searchW := btnOpenX - LP_BTN_GAP - 50    ; 50 = "搜索:" 的 x+w
    if searchW < 100
        searchW := 100

    gSearchEdit.Move(50, 8, searchW, 24)
    gBtnOpen.Move(btnOpenX, 8, LP_BTN_OPEN_W, 24)
    gBtnRefresh.Move(btnRefX, 8, LP_BTN_REF_W, 24)

    ; 底部状态栏贴底
    lvW := width - 2 * LP_MARGIN
    statusY := height - LP_MARGIN - LP_STATUS_H
    gStatus.Move(LP_MARGIN, statusY, lvW, LP_STATUS_H)

    ; ListView 占中间
    lvY := LP_MARGIN + LP_TOP_H
    lvH := statusY - lvY - LP_MARGIN
    if lvH < 60
        lvH := 60
    gLV.Move(LP_MARGIN, lvY, lvW, lvH)
}

OnSearchChanged(ctrl, *) {
    RenderList(StrLower(Trim(ctrl.Value)))
}

OnOpenFolder(*) {
    dir := DirSelect("*" A_MyDocuments, 3, "选择包含视频的文件夹")
    if dir = ""
        return
    LoadDirectoryList(dir)
}

OnListDoubleClick(ctrl, rowNum) {
    if rowNum < 1
        return
    fname := ctrl.GetText(rowNum, 1)
    ext   := ctrl.GetText(rowNum, 4)      ; 列顺序：文件名 / 时长 / 大小 / 扩展
    ; 去掉可能存在的 ▶ 前缀
    if SubStr(fname, 1, 2) = "▶ "
        fname := SubStr(fname, 3)
    fullpath := gCurrentDir "\" fname "." ext
    if !FileExist(fullpath) {
        MsgBox("文件不存在: " fullpath)
        return
    }
    if !EnsureMpvRunning() {
        return
    }
    ok := LoadFileIntoMpv(fullpath)
    UpdateStatus(ok ? "已切换: " fname : "IPC 发送失败: " fname)
}

; 表头点击：接管排序
OnColClick(ctrl, colNum) {
    global gSortCol, gSortAsc
    if colNum = gSortCol
        gSortAsc := !gSortAsc     ; 相同列切换升降序
    else {
        gSortCol := colNum
        gSortAsc := true
    }
    ApplyCurrentSort()
    RefreshCurrentSearch()
}

OnDropFiles(guiObj, ctrlObj, fileArray, x, y, *) {
    if fileArray.Length = 0
        return
    first := fileArray[1]
    if InStr(FileGetAttrib(first), "D") {
        LoadDirectoryList(first)
    } else {
        LoadDirectoryFromPath(first)
        EnsureMpvRunning()
        LoadFileIntoMpv(first)
    }
}

UpdateStatus(text) {
    global gStatus
    try gStatus.Text := text
}

;================================================================
; 目录扫描 & 列表渲染
;================================================================
LoadDirectoryFromPath(anyFilePath) {
    SplitPath(anyFilePath, , &dir)
    if dir != ""
        LoadDirectoryList(dir)
}

LoadDirectoryList(dir) {
    global gCurrentDir, gAllFiles, gSearchEdit

    if !DirExist(dir) {
        UpdateStatus("目录不存在: " dir)
        return
    }
    gCurrentDir := dir

    files := []
    Loop Files, dir "\*.*", "F" {
        ext := StrLower(A_LoopFileExt)
        if IsMediaExt(ext) {
            SplitPath(A_LoopFileName, , , , &nameNoExt)
            files.Push({
                name: nameNoExt,
                ext: ext,
                full: A_LoopFileFullPath,
                duration: "",
                durationMs: 0,               ; 用于时长列排序
                sizeBytes: A_LoopFileSize,
                sizeStr: FormatFileSize(A_LoopFileSize),
                watched: IsWatched(A_LoopFileFullPath)
            })
        }
    }

    gAllFiles := files
    ApplyCurrentSort()                    ; 应用当前排序（默认文件名升序）
    gSearchEdit.Value := ""
    RenderList("")
    UpdateStatus(Format("已加载 {} 个媒体文件 · 扫描时长中…", files.Length))

    ; 加载完把焦点移到列表，方便 ↑↓ + Enter 键盘操作
    try gLV.Focus()

    ; 时长扫描放到 SetTimer 里异步跑，不阻塞 GUI
    if files.Length > 0
        SetTimer(ScanDurationsWorker, -50)
}

RenderList(keyword) {
    global gLV, gAllFiles, gCurrentPlayingPath
    gLV.Opt("-Redraw")
    gLV.Delete()
    for f in gAllFiles {
        if keyword = "" || InStr(StrLower(f.name), keyword) {
            marker := IsPlayingFile(f.full) ? "▶ " : ""
            gLV.Add(, marker f.name, f.duration, f.sizeStr, f.ext)
        }
    }
    gLV.Opt("+Redraw")
}

; 自动单位：<1KB=B / <1MB=KB / <1GB=MB / else=GB
FormatFileSize(bytes) {
    if bytes < 1024
        return bytes " B"
    if bytes < 1048576                     ; 1024^2
        return Round(bytes / 1024) " KB"
    if bytes < 1073741824                  ; 1024^3
        return Round(bytes / 1048576) " MB"
    return Format("{:.2f} GB", bytes / 1073741824)
}

; 大小写 + 正反斜杠都不敏感地比较两个路径
IsPlayingFile(path) {
    global gCurrentPlayingPath
    if gCurrentPlayingPath = "" || path = ""
        return false
    a := StrLower(StrReplace(path, "\", "/"))
    b := StrLower(StrReplace(gCurrentPlayingPath, "\", "/"))
    return a = b
}

IsMediaExt(ext) {
    for e in VIDEO_EXTS
        if e = ext
            return true
    for e in AUDIO_EXTS
        if e = ext
            return true
    return false
}

; 按 gSortCol / gSortAsc 排序 gAllFiles（就地修改，插入排序，n^2）
; 列：1=文件名 / 2=时长 / 3=大小 / 4=扩展
ApplyCurrentSort() {
    global gAllFiles, gSortCol, gSortAsc
    arr := gAllFiles
    n := arr.Length
    if n < 2
        return
    Loop n - 1 {
        i := A_Index + 1
        cur := arr[i]
        j := i - 1
        while (j >= 1 && CompareItem(arr[j], cur) > 0) {
            arr[j + 1] := arr[j]
            j--
        }
        arr[j + 1] := cur
    }
}

; 比较两个 file item，返回负/零/正
CompareItem(a, b) {
    global gSortCol, gSortAsc
    order := gSortAsc ? 1 : -1
    switch gSortCol {
        case 1:
            return StrCompare(a.name, b.name, false) * order
        case 2:
            return (a.durationMs - b.durationMs) * order
        case 3:
            return (a.sizeBytes - b.sizeBytes) * order
        case 4:
            r := StrCompare(a.ext, b.ext, false)
            if r = 0
                r := StrCompare(a.name, b.name, false)
            return r * order
        default:
            return 0
    }
}

;================================================================
; MediaInfo.dll 时长扫描（后台）
; 用 SetTimer 分批扫描避免长时间阻塞主线程
;================================================================

ScanDurationsWorker() {
    global gAllFiles, gScanIndex, gScanBatch, gCurrentDir, gLV

    if !EnsureMediaInfoLoaded() {
        UpdateStatus("MediaInfo.dll 加载失败，时长无法显示")
        return
    }

    ; 从上次位置继续
    endIdx := Min(gScanIndex + gScanBatch, gAllFiles.Length)
    Loop endIdx - gScanIndex {
        idx := gScanIndex + A_Index
        f := gAllFiles[idx]
        if f.duration = "" {
            res := GetMediaDurationDetailed(f.full)
            f.duration := res.text
            f.durationMs := res.ms
        }
    }
    gScanIndex := endIdx

    ; 增量刷新列表（保持当前搜索过滤）
    global gSearchEdit
    RenderList(StrLower(Trim(gSearchEdit.Value)))

    if gScanIndex < gAllFiles.Length {
        SetTimer(ScanDurationsWorker, -30)   ; 让出主线程 30ms
    } else {
        gScanIndex := 0
        UpdateStatus(Format("已加载 {} 个媒体文件 · {}", gAllFiles.Length, gCurrentDir))
    }
}

; 懒加载 MediaInfo.dll
EnsureMediaInfoLoaded() {
    global gMediaInfoDll, gMediaInfoDllPath

    if gMediaInfoDll
        return true

    ; 查找 MediaInfo.dll：launcher 同目录 → 硬编码兜底
    candidates := [
        A_ScriptDir "\MediaInfo.dll",
        "E:\Software\mpv.net\MediaInfo.dll",
    ]
    for p in candidates {
        if FileExist(p) {
            gMediaInfoDllPath := p
            break
        }
    }
    if gMediaInfoDllPath = ""
        return false

    gMediaInfoDll := DllCall("LoadLibrary", "Str", gMediaInfoDllPath, "Ptr")
    return gMediaInfoDll != 0
}

; 返回 {text: "M:SS", ms: 数字} 方便排序
GetMediaDurationDetailed(filepath) {
    global gMediaInfoDll, gMediaInfoDllPath
    fail := {text: "-", ms: 0}
    if !gMediaInfoDll
        return fail

    handle := DllCall(gMediaInfoDllPath "\MediaInfoA_New", "Cdecl Ptr")
    if !handle
        handle := DllCall(gMediaInfoDllPath "\MediaInfo_New", "Cdecl Ptr")
    if !handle
        return fail

    result := fail
    try {
        opened := DllCall(gMediaInfoDllPath "\MediaInfo_Open"
            , "Ptr", handle
            , "WStr", filepath
            , "Cdecl Int")

        if opened {
            durMsPtr := DllCall(gMediaInfoDllPath "\MediaInfo_Get"
                , "Ptr", handle
                , "Int", 0
                , "Int", 0
                , "WStr", "Duration"
                , "Int", 1
                , "Int", 0
                , "Cdecl Ptr")

            if durMsPtr {
                durStr := StrGet(durMsPtr, "UTF-16")
                durMs := 0.0 + durStr
                if durMs > 0 {
                    intMs := Integer(durMs)
                    result := {text: FormatDuration(intMs), ms: intMs}
                }
            }
            DllCall(gMediaInfoDllPath "\MediaInfo_Close", "Ptr", handle, "Cdecl")
        }
    }

    try DllCall(gMediaInfoDllPath "\MediaInfo_Delete", "Ptr", handle, "Cdecl")
    return result
}

FormatDuration(ms) {
    totalSec := ms // 1000
    h := totalSec // 3600
    m := (totalSec // 60) - h * 60
    s := Mod(totalSec, 60)
    if h > 0
        return Format("{1:d}:{2:02d}:{3:02d}", h, m, s)
    return Format("{1:d}:{2:02d}", m, s)
}

;================================================================
; mpv 进程 & IPC
;================================================================
EnsureMpvRunning() {
    if TryPingMpv()
        return true

    if !FileExist(MPV_EXE) {
        MsgBox("找不到 mpvnet.exe`n期望位置: " MPV_EXE, "启动失败", "IconX")
        return false
    }
    Run(Format('"{}" --idle=yes --force-window=yes', MPV_EXE))

    Loop 30 {
        Sleep 200
        if TryPingMpv()
            return true
    }
    MsgBox("mpv 启动 6 秒后仍无法通过 IPC 连接。`n请检查 mpv.conf 里 input-ipc-server 是否配置正确。", "IPC 连接失败", "IconX")
    return false
}

;----------------------------------------------------------------
; IPC 说明：
;   AHK v2 的 FileOpen 对 Windows 命名管道支持不完善——ReadLine 在没
;   有数据时会阻塞主线程，导致 GUI 卡死。这里用 kernel32 的 CreateFile
;   + WriteFile 直接写管道，只写不读（fire-and-forget）。
;   探测 mpv 是否存活改成"能否 CreateFile 打开管道"，不发命令等回复。
;----------------------------------------------------------------

TryPingMpv() {
    h := OpenMpvPipe()
    if !h
        return false
    DllCall("kernel32.dll\CloseHandle", "Ptr", h)
    return true
}

LoadFileIntoMpv(filepath) {
    global gCurrentPlayingPath
    ; loadfile 用正斜杠避免 JSON 反斜杠转义链条
    fixed := StrReplace(filepath, "\", "/")
    fixed := StrReplace(fixed, '"', '\"')
    cmd := '{"command":["loadfile","' fixed '","replace"]}'
    ok := IpcSendFireAndForget(cmd)
    if ok {
        gCurrentPlayingPath := filepath
        try RefreshCurrentSearch()
        ; 每次 loadfile 都触发 Snap（不依赖 mpv 事件推送）
        ; SnapToMpvWindow 自带重试逻辑，覆盖 mpv 冷启动延迟
        SetTimer(() => SnapToMpvWindow(15), -300)
    }
    return ok
}

; 打开 mpv IPC 管道，只以写模式。返回句柄（>0）或 0 表示失败
OpenMpvPipe() {
    h := DllCall("kernel32.dll\CreateFileW",
        "WStr", MPV_IPC_PIPE,
        "UInt", GENERIC_WRITE,
        "UInt", 0,
        "Ptr", 0,
        "UInt", OPEN_EXISTING,
        "UInt", 0,
        "Ptr", 0,
        "Ptr")
    ; CreateFile 失败时返回 INVALID_HANDLE_VALUE = -1（在 64 位下会是 0xFFFFFFFFFFFFFFFF）
    if (h = 0 || h = -1 || h = 0xFFFFFFFFFFFFFFFF)
        return 0
    return h
}

; 只写不读，绝不阻塞 GUI
IpcSendFireAndForget(jsonLine) {
    h := OpenMpvPipe()
    if !h
        return false

    payload := jsonLine "`n"
    size := StrPut(payload, "UTF-8")     ; 含尾 NUL 的字节数
    bytes := Buffer(size, 0)
    StrPut(payload, bytes, "UTF-8")
    writeLen := size - 1                 ; 不写 NUL

    writtenActual := 0
    ok := DllCall("kernel32.dll\WriteFile",
        "Ptr", h,
        "Ptr", bytes.Ptr,
        "UInt", writeLen,
        "UInt*", &writtenActual,
        "Ptr", 0)

    DllCall("kernel32.dll\CloseHandle", "Ptr", h)
    return ok != 0
}

;================================================================
; 单实例：Global Mutex
;================================================================
CreateSingletonMutex(name) {
    ; CreateMutexW 创建/打开命名 mutex，如果已存在返回句柄，同时 GetLastError = ERROR_ALREADY_EXISTS (183)
    h := DllCall("kernel32.dll\CreateMutexW", "Ptr", 0, "Int", 0, "WStr", name, "Ptr")
    lastErr := A_LastError
    if lastErr = 183 {
        ; 已存在 → 我们是副本，关掉句柄并返回 0
        if h
            DllCall("kernel32.dll\CloseHandle", "Ptr", h)
        return 0
    }
    return h
}

;================================================================
; Step 3.2-3.4：IPC 读通道 + 事件订阅 + 轮询
;================================================================

; 初始化：建立读通道 + 订阅 path 属性 + 订阅 end-file 事件
InitIpcReader() {
    global gReadPipe
    if !EnsureMpvRunning()
        return
    OpenReadPipe()
    ; 订阅两个：
    ;   observe_property (id=1) 让 mpv 主动推送 path 变化
    ;   enable_event (end-file) mpv 默认就会推 end-file，无需订阅，但显式声明更保险
    IpcSendFireAndForget('{"command":["observe_property",1,"path"]}')
    IpcSendFireAndForget('{"command":["observe_property",2,"eof-reached"]}')
}

OpenReadPipe() {
    global gReadPipe
    if gReadPipe {
        DllCall("kernel32.dll\CloseHandle", "Ptr", gReadPipe)
        gReadPipe := 0
    }
    h := DllCall("kernel32.dll\CreateFileW",
        "WStr", MPV_IPC_PIPE,
        "UInt", GENERIC_READ | GENERIC_WRITE,
        "UInt", 0,
        "Ptr", 0,
        "UInt", OPEN_EXISTING,
        "UInt", 0,
        "Ptr", 0,
        "Ptr")
    if (h = 0 || h = -1 || h = 0xFFFFFFFFFFFFFFFF) {
        gReadPipe := 0
        return false
    }
    gReadPipe := h
    return true
}

; 定时器回调：非阻塞读管道，处理 mpv 事件
PollMpvEvents() {
    global gReadPipe, gReadBuf

    ; 通道未建立就重试
    if !gReadPipe {
        OpenReadPipe()
        if !gReadPipe
            return
        ; 新连接：重发订阅
        IpcSendFireAndForget('{"command":["observe_property",1,"path"]}')
        IpcSendFireAndForget('{"command":["observe_property",2,"eof-reached"]}')
    }

    ; PeekNamedPipe 查缓冲区
    bytesAvail := 0
    ok := DllCall("kernel32.dll\PeekNamedPipe",
        "Ptr", gReadPipe,
        "Ptr", 0,
        "UInt", 0,
        "Ptr", 0,
        "UInt*", &bytesAvail,
        "Ptr", 0)

    if !ok {
        ; 管道断了 → 释放句柄，下次 Poll 重连
        DllCall("kernel32.dll\CloseHandle", "Ptr", gReadPipe)
        gReadPipe := 0
        return
    }

    if bytesAvail <= 0
        return

    ; 有数据可读
    readSize := Min(bytesAvail, PIPE_BUFSIZE)
    buf := Buffer(readSize + 1, 0)
    bytesRead := 0
    r := DllCall("kernel32.dll\ReadFile",
        "Ptr", gReadPipe,
        "Ptr", buf.Ptr,
        "UInt", readSize,
        "UInt*", &bytesRead,
        "Ptr", 0)
    if !r || bytesRead = 0
        return

    ; UTF-8 解码 + 拼行缓冲
    chunk := StrGet(buf, bytesRead, "UTF-8")
    gReadBuf .= chunk

    ; 按 \n 切成完整行
    while (pos := InStr(gReadBuf, "`n")) {
        line := SubStr(gReadBuf, 1, pos - 1)
        gReadBuf := SubStr(gReadBuf, pos + 1)
        if Trim(line) != ""
            HandleMpvEvent(line)
    }
}

; 解析 mpv 事件行（JSON），只关心 path 变化 和 end-file
HandleMpvEvent(line) {
    global gCurrentPlayingPath, gAllFiles

    ; property-change: path 变化（仅用于同步当前路径 / ▶ 高亮，不再触发 Snap；Snap 已在 LoadFileIntoMpv 里统一触发）
    if InStr(line, '"event":"property-change"') && InStr(line, '"name":"path"') {
        newPath := ExtractJsonString(line, "data")
        if newPath != "" && newPath != gCurrentPlayingPath {
            gCurrentPlayingPath := newPath
            RefreshCurrentSearch()
        }
        return
    }

    ; end-file: 视频播完
    if InStr(line, '"event":"end-file"') {
        reason := ExtractJsonString(line, "reason")
        ; 只处理正常播完（eof），不处理用户手动 stop / redirect
        if reason = "eof" {
            ; 先把当前播完的记为已看
            if gCurrentPlayingPath != "" {
                MarkAsWatched(gCurrentPlayingPath)
                UpdateWatchedFlagsInList()
                RefreshCurrentSearch()
            }
            if gAutoNextEnabled
                PlayNextInList()
        }
        return
    }
}

; 从 JSON 行里粗提字符串字段（不做完整 parse，够用）
;   pattern: "key":"value"
ExtractJsonString(line, key) {
    needle := '"' key '":"'
    p := InStr(line, needle)
    if !p
        return ""
    startPos := p + StrLen(needle)
    ; 找下一个不带转义的 "
    endPos := 0
    i := startPos
    while (i <= StrLen(line)) {
        c := SubStr(line, i, 1)
        if c = '\\' {
            i += 2
            continue
        }
        if c = '"' {
            endPos := i
            break
        }
        i++
    }
    if !endPos
        return ""
    raw := SubStr(line, startPos, endPos - startPos)
    ; mpv 会用 \/ 转义正斜杠，还原一下
    raw := StrReplace(raw, "\/", "/")
    raw := StrReplace(raw, "\\", "\")
    return raw
}

; 播完自动下一集：在 gAllFiles 里找当前项索引，播下一项
PlayNextInList() {
    global gAllFiles, gCurrentPlayingPath
    if gAllFiles.Length = 0
        return
    idx := 0
    for i, f in gAllFiles {
        if IsPlayingFile(f.full) {
            idx := i
            break
        }
    }
    if idx = 0 || idx >= gAllFiles.Length {
        ; 到列表末尾或找不到当前项：暂停 mpv，别让它停在无声画面里
        IpcSendFireAndForget('{"command":["set_property","pause",true]}')
        UpdateStatus("已播完最后一集")
        return
    }
    next := gAllFiles[idx + 1]
    LoadFileIntoMpv(next.full)
    UpdateStatus("自动播下一集: " next.name)
}

; 触发一次列表重绘（尊重当前搜索关键词）
RefreshCurrentSearch() {
    global gSearchEdit
    if IsSet(gSearchEdit)
        RenderList(StrLower(Trim(gSearchEdit.Value)))
    else
        RenderList("")
}

;================================================================
; 已看过：本地 JSON 持久化 + 灰色行渲染
;================================================================

; 路径归一化：小写 + 反斜杠转正斜杠
NormPath(p) {
    return StrLower(StrReplace(p, "\", "/"))
}

IsWatched(path) {
    global gWatchedSet
    if !IsSet(gWatchedSet)
        return false
    return gWatchedSet.Has(NormPath(path))
}

MarkAsWatched(path) {
    global gWatchedSet
    key := NormPath(path)
    if gWatchedSet.Has(key)
        return
    gWatchedSet[key] := true
    SaveWatchedSet()
}

; 更新 gAllFiles 每项的 watched 状态（当 Set 变了或列表新加载时）
UpdateWatchedFlagsInList() {
    global gAllFiles
    if !IsSet(gAllFiles)
        return
    for f in gAllFiles {
        f.watched := IsWatched(f.full)
    }
}

LoadWatchedSet() {
    global gWatchedSet, gWatchedFile
    gWatchedSet := Map()
    if !FileExist(gWatchedFile)
        return
    try {
        content := FileRead(gWatchedFile, "UTF-8")
        ; 简易 JSON 数组解析（我们只存字符串数组）
        ; 支持："p1","p2","p3"
        pos := 1
        while (p := InStr(content, '"', , pos)) {
            startPos := p + 1
            endPos := 0
            i := startPos
            while (i <= StrLen(content)) {
                c := SubStr(content, i, 1)
                if c = '\\' {
                    i += 2
                    continue
                }
                if c = '"' {
                    endPos := i
                    break
                }
                i++
            }
            if !endPos
                break
            key := SubStr(content, startPos, endPos - startPos)
            key := StrReplace(key, "\\", "\")
            gWatchedSet[key] := true
            pos := endPos + 1
        }
    } catch {
        gWatchedSet := Map()
    }
}

SaveWatchedSet() {
    global gWatchedSet, gWatchedFile
    parts := []
    for k, _ in gWatchedSet {
        esc := StrReplace(k, "\", "\\")
        esc := StrReplace(esc, '"', '\"')
        parts.Push('"' esc '"')
    }
    json := "[" ArrayJoin(parts, ",") "]"
    try FileDelete(gWatchedFile)
    try FileAppend(json, gWatchedFile, "UTF-8")
}

ArrayJoin(arr, sep) {
    out := ""
    for i, v in arr {
        out .= (i > 1 ? sep : "") v
    }
    return out
}

;================================================================
; 删除文件（Delete 键 → 回收站）
;================================================================

HandleDeleteFile(*) {
    global gLV, gAllFiles, gCurrentDir
    if !IsSet(gLV)
        return
    row := gLV.GetNext(0)
    if row < 1
        return

    ; 从可见行反查 gAllFiles 里的真实 index
    fname := gLV.GetText(row, 1)
    if SubStr(fname, 1, 2) = "▶ "
        fname := SubStr(fname, 3)
    ext := gLV.GetText(row, 4)
    fullpath := gCurrentDir "\" fname "." ext
    if !FileExist(fullpath) {
        MsgBox("文件不存在: " fullpath)
        return
    }

    r := MsgBox("确认将文件移到回收站？`n`n" fullpath, "删除确认", "YesNo Icon?")
    if r != "Yes"
        return

    if MoveToRecycleBin(fullpath) {
        ; 从 gAllFiles 里移除该项
        idx := 0
        for i, f in gAllFiles {
            if IsPlayingFile(f.full) && f.full = fullpath
                idx := i
            else if f.full = fullpath
                idx := i
        }
        if idx > 0
            gAllFiles.RemoveAt(idx)
        RefreshCurrentSearch()
        UpdateStatus("已移到回收站: " fname)
    } else {
        MsgBox("删除失败: " fullpath, "错误", "IconX")
    }
}

; 用 SHFileOperationW 走回收站
MoveToRecycleBin(path) {
    ; SHFILEOPSTRUCT 结构体
    ; FO_DELETE = 3, FOF_ALLOWUNDO = 0x40, FOF_NOCONFIRMATION = 0x10, FOF_SILENT = 0x4
    FO_DELETE := 3
    FOF_ALLOWUNDO := 0x40
    FOF_NOCONFIRMATION := 0x10
    FOF_SILENT := 0x4
    flags := FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT

    ; 需要双 NUL 结尾
    pathBuf := Buffer((StrLen(path) + 2) * 2, 0)
    StrPut(path, pathBuf, "UTF-16")
    ; 末尾多加一个 NUL（StrPut 已写一个 NUL，再补一个）
    NumPut("UShort", 0, pathBuf, StrLen(path) * 2 + 2)

    ; SHFILEOPSTRUCTW (64-bit 布局)
    ; HWND hwnd; UINT wFunc; PCZZWSTR pFrom; PCZZWSTR pTo;
    ; FILEOP_FLAGS fFlags(short); BOOL fAnyOperationsAborted; LPVOID hNameMappings; PCWSTR lpszProgressTitle
    op := Buffer(64, 0)
    NumPut("Ptr",     0,          op, 0)     ; hwnd
    NumPut("UInt",    FO_DELETE,  op, 8)     ; wFunc
    NumPut("Ptr",     pathBuf.Ptr, op, 16)   ; pFrom
    NumPut("Ptr",     0,          op, 24)    ; pTo
    NumPut("UShort",  flags,      op, 32)    ; fFlags

    result := DllCall("shell32\SHFileOperationW", "Ptr", op.Ptr, "Int")
    return result = 0
}

;================================================================
; ListView Custom Draw：已看过的行显示为灰色
;================================================================
; NM_CUSTOMDRAW 消息码 = -12
; CDRF_NOTIFYITEMDRAW = 0x20
; CDRF_NEWFONT = 0x2
; CDDS_PREPAINT = 1
; CDDS_ITEMPREPAINT = 0x10001

LV_OnNotify(wParam, lParam, msg, hwnd) {
    global gLV, gAllFiles
    if !IsSet(gLV)
        return
    ; 检查是否是 ListView 的 NM_CUSTOMDRAW
    ; NMHDR 结构: hwndFrom(Ptr), idFrom(UPtr), code(Int)
    hwndFrom := NumGet(lParam, 0, "Ptr")
    if hwndFrom != gLV.Hwnd
        return
    code := NumGet(lParam, 16, "Int")
    if code != -12       ; NM_CUSTOMDRAW
        return

    ; NMLVCUSTOMDRAW 结构：NMCUSTOMDRAW (48 字节 on x64) + clrText + clrTextBk + iSubItem + ...
    ; NMCUSTOMDRAW: NMHDR(24) + dwDrawStage(UInt) + hdc(Ptr) + rc(16) + dwItemSpec(UPtr) + uItemState(UInt) + lItemlParam(Ptr)
    ; NMLVCUSTOMDRAW 结构（x64）：
    ;   NMHDR                24
    ;   dwDrawStage  UInt    4    → 24
    ;   (pad)                4    → 28
    ;   hdc          Ptr     8    → 32
    ;   rc(RECT)             16   → 40
    ;   dwItemSpec   UPtr    8    → 56
    ;   uItemState   UInt    4    → 64
    ;   (pad)                4    → 68
    ;   lItemlParam  Ptr     8    → 72
    ;   ==== NMCUSTOMDRAW 结束 @ 80 ====
    ;   clrText      COLORREF 4   → 80
    ;   clrTextBk    COLORREF 4   → 84
    ;   iSubItem     Int     4    → 88
    dwDrawStage := NumGet(lParam, 24, "UInt")

    if dwDrawStage = 1 {           ; CDDS_PREPAINT
        return 0x20                ; CDRF_NOTIFYITEMDRAW
    }
    if dwDrawStage = 0x10001 {     ; CDDS_ITEMPREPAINT
        rowIdx1 := NumGet(lParam, 56, "UPtr") + 1
        if rowIdx1 < 1 || rowIdx1 > gLV.GetCount()
            return 0
        fname := gLV.GetText(rowIdx1, 1)
        if SubStr(fname, 1, 2) = "▶ "
            fname := SubStr(fname, 3)
        ext := gLV.GetText(rowIdx1, 4)
        watched := false
        for f in gAllFiles {
            if f.name = fname && f.ext = ext {
                watched := f.watched
                break
            }
        }
        if watched {
            NumPut("UInt", 0x808080, lParam, 80)
        }
        return 0x2                 ; CDRF_NEWFONT
    }
    return 0
}

InstallCustomDraw() {
    global gMainGui
    OnMessage(0x4E, LV_OnNotify)   ; WM_NOTIFY
}

;================================================================
; Snap：把 launcher 窗口贴到 mpv 播放窗口左侧
;   触发时机 A：mpv 首次开始播放（path 事件）—— 见 HandleMpvEvent
;   触发时机 C：Ctrl+L 手动
;================================================================

HandleSnapHotkey(*) {
    SnapToMpvWindow(15)
}

; retriesLeft：内部重试计数，用户调用时传 0 就走默认 15 次重试
SnapToMpvWindow(retriesLeft := 15) {
    global gMainGui
    SnapLog("SnapToMpvWindow(retriesLeft=" retriesLeft ") 开始")
    if !IsSet(gMainGui) || !gMainGui {
        SnapLog("  gMainGui 未就绪，退出")
        return
    }
    mpvHwnd := FindMpvWindow()
    SnapLog("  FindMpvWindow hwnd=" mpvHwnd)
    if !mpvHwnd {
        if retriesLeft > 0 {
            SnapLog("  mpv 未找到，200ms 后重试")
            SetTimer(() => SnapToMpvWindow(retriesLeft - 1), -200)
        } else {
            SnapLog("  重试用尽，放弃")
        }
        return
    }
    mpvRect := GetWindowRect(mpvHwnd)
    if !mpvRect {
        SnapLog("  GetWindowRect 失败")
        if retriesLeft > 0
            SetTimer(() => SnapToMpvWindow(retriesLeft - 1), -200)
        return
    }
    mpvW := mpvRect.right - mpvRect.left
    mpvH := mpvRect.bottom - mpvRect.top
    SnapLog("  mpvRect: L=" mpvRect.left " T=" mpvRect.top " R=" mpvRect.right " B=" mpvRect.bottom " (w=" mpvW " h=" mpvH ")")
    if (mpvW < 100 || mpvH < 100) {
        SnapLog("  mpv 窗口尺寸未就绪，200ms 后重试")
        if retriesLeft > 0
            SetTimer(() => SnapToMpvWindow(retriesLeft - 1), -200)
        return
    }

    lHwnd := gMainGui.Hwnd
    lRect := GetWindowRect(lHwnd)
    if !lRect {
        SnapLog("  launcher GetWindowRect 失败")
        return
    }
    lWidth  := lRect.right - lRect.left
    lHeight := lRect.bottom - lRect.top
    SnapLog("  launcher rect: L=" lRect.left " T=" lRect.top " R=" lRect.right " B=" lRect.bottom " (w=" lWidth " h=" lHeight ")")

    newX := mpvRect.left - lWidth - 4
    newY := mpvRect.top
    SnapLog("  未钳制 newX=" newX " newY=" newY)

    monRect := GetWorkAreaForWindow(mpvHwnd)
    if monRect {
        SnapLog("  monRect: L=" monRect.left " T=" monRect.top " R=" monRect.right " B=" monRect.bottom)
        if newX < monRect.left
            newX := monRect.left
        if newY < monRect.top
            newY := monRect.top
        maxY := monRect.bottom - lHeight
        if newY > maxY
            newY := maxY
    } else {
        SnapLog("  monRect 未取到")
    }
    SnapLog("  钳制后 newX=" newX " newY=" newY)

    r := DllCall("user32\SetWindowPos",
        "Ptr", lHwnd,
        "Ptr", 0,
        "Int", newX,
        "Int", newY,
        "Int", 0, "Int", 0,
        "UInt", 0x1 | 0x4)
    SnapLog("  SetWindowPos 返回=" r)
}

; 诊断日志（默认关闭，需要排查时把下面 return 那行注释掉即可）
SnapLog(msg) {
    return
    ; try FileAppend("[" A_Now "] " msg "`n", A_ScriptDir "\_snap_debug.log", "UTF-8")
}

; 找 mpv.net 窗口（通过 IPC 拿到进程 ID 更稳，简化起见用类名 + 标题）
FindMpvWindow() {
    ; mpv.net 主窗口类名一般是 "mpv" 或含 "mpv.net"
    ; 用 WinExist ahk_exe 更靠谱
    return WinExist("ahk_exe mpvnet.exe")
}

GetWindowRect(hwnd) {
    rc := Buffer(16, 0)
    r := DllCall("user32\GetWindowRect", "Ptr", hwnd, "Ptr", rc.Ptr)
    if !r
        return 0
    return {
        left: NumGet(rc, 0, "Int"),
        top: NumGet(rc, 4, "Int"),
        right: NumGet(rc, 8, "Int"),
        bottom: NumGet(rc, 12, "Int")
    }
}

; 拿到 hwnd 所在显示器的工作区（去掉任务栏后的可用矩形）
GetWorkAreaForWindow(hwnd) {
    ; MONITOR_DEFAULTTONEAREST = 2
    hMon := DllCall("user32\MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    if !hMon
        return 0
    ; MONITORINFO 结构：cbSize(UInt) + rcMonitor(RECT=16) + rcWork(RECT=16) + dwFlags(UInt) = 40
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi, 0)
    r := DllCall("user32\GetMonitorInfoW", "Ptr", hMon, "Ptr", mi.Ptr)
    if !r
        return 0
    return {
        left: NumGet(mi, 20, "Int"),
        top: NumGet(mi, 24, "Int"),
        right: NumGet(mi, 28, "Int"),
        bottom: NumGet(mi, 32, "Int")
    }
}
