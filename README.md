# mpv-net-game-audio-version

一个开箱即用的 mpv.net 定制版。核心改造：**h / k / e 三键无损切片**、内置 ffmpeg、uosc 皮肤修补、中文字幕默认样式。

免安装，解压即用。

---

## 快速开始

1. 到 [Releases](https://github.com/<你的用户名>/mpv-net-game-audio-version/releases) 下载最新 zip
2. 解压到任意目录
3. 双击 `mpvnet.exe`，或把视频拖到图标上

> 如果想要 clone 本仓库，把 `portable_config/` 拷进自己的 mpv.net 目录即可。

---

## 亮点

| | |
|---|---|
| **强内核** | mpv 0.41，支持 MKV / H.265 / HDR / 10bit / VP9 / AV1 / FLAC / DTS / Atmos |
| **高画质** | `gpu-hq` + NVIDIA `nvdec` 硬解 |
| **现代 UI** | uosc 皮肤，鼠标移到底部自动出控制栏 |
| **无损切片** | `h / k / e` 三键导出片段，`-c copy` 不重编码 |
| **便携** | 全部配置在 `portable_config/`，不写注册表 |
| **中文字幕** | 微软雅黑 45pt 金黄 + 深色描边 |

---

## 快捷键

### 播放控制

| 键 | 作用 |
|---|---|
| `空格` | 播放 / 暂停 |
| `双击` | 全屏切换 |
| `f` | 全屏切换 |
| `q` / `Esc` | 退出 |
| `右键` | 呼出菜单 |

### 跳转

| 键 | 作用 |
|---|---|
| `←` / `→` | 快退 / 快进 **5 秒** |
| `↑` / `↓` | 快退 / 快进 **60 秒** |
| `Shift+←` / `Shift+→` | 精细 **1 秒** |
| `Shift+↑` / `Shift+↓` | 精细 **5 秒** |
| `,` / `.` | **逐帧** 后退 / 前进 |
| `Home` / `End` | 跳到最前 / 最后 |
| 点进度条 | 拖到任意位置 |

### 音量 / 字幕 / 截图

| 键 | 作用 |
|---|---|
| `滚轮` | 音量 |
| `m` | 静音 |
| `j` | 切字幕 |
| `#` | 切音轨 |
| `s` | 截图（含字幕） |
| `S` | 截图（不含字幕） |

### 播放列表

打开视频后，同目录其他视频/音频**自动加进列表**，播完自动下一个。

| 键 | 作用 |
|---|---|
| `TAB` | 打开 / 关闭列表 |
| `>` / `<` | 下一集 / 上一集 |
| `↑` `↓` `Enter` | 列表内导航（列表打开时） |
| `Backspace` | 从列表移除 |

> 列表打开时方向键用于导航；关闭后恢复跳转功能。

### 无损切片

| 键 | 作用 |
|---|---|
| `h` | 设起点 |
| `k` | 设终点 |
| `e` | 导出 |
| `Shift+h` / `Shift+k` | 跳回起点 / 终点复听 |
| `t` | 切换是否剥离元数据 |

**导出位置**：源文件同目录，自动编号 `原文件名 1.mp4` / `原文件名 2.mp4`
**限制**：视频起点必须落在关键帧上，会自动回落到最近的 I 帧；音频不受影响。要精确到帧就得重编码，就不无损了。

---

## 常见问题

**Q. 打开视频黑屏 / 花屏：**
显卡驱动和 nvdec 不兼容。编辑 `portable_config/mpv.conf`，把 `hwdec=nvdec` 改成 `hwdec=no`。

**Q. 想记住上次播放位置：**
`portable_config/mpv.conf` 里 `save-position-on-quit=no` 改成 `yes`。

**Q. 按 `e` 没反应 / 报 Subprocess failed：**
检查 `mpvnet.exe` 同目录是否有 `ffmpeg.exe`。脚本查找顺序：主程序目录 → `portable_config/` → 系统 PATH。

**Q. 底部控制栏不见了：**
鼠标移到窗口下 1/4 区域自动弹出，3 秒不动自动隐藏。

**Q. 想换 mpv 官方 OSC：**
`mpv.conf` 里 `osc=no` 改成 `osc=yes`，然后把 `portable_config/scripts/uosc/` 删掉或改名。

**Q. 想改字幕字体 / 大小 / 颜色：**
编辑 `mpv.conf` 里 `sub-*` 相关项，重启生效。

---

## 目录结构

```
mpv.net/
├── mpvnet.exe / mpvnet.dll         主程序
├── libmpv-2.dll                    mpv 内核（含所有解码器）
├── ffmpeg.exe                      切片调用
├── MediaInfo.dll                   媒体信息
├── Locale/zh_CN/                   中文界面
└── portable_config/
    ├── mpv.conf                    画质 / 字幕 / 硬解
    ├── input.conf                  快捷键
    ├── scripts/
    │   ├── trim.lua                切片（h/k/e）
    │   ├── uosc/                   UI 皮肤
    │   ├── thumbfast.lua           进度条缩略图
    │   ├── frame-seek.lua          逐帧跳转
    │   ├── playlistmanager.lua     播放列表
    │   └── copy-timestamp.lua      复制时间戳
    └── script-opts/                插件配置
```

---

## 相比官方 mpv.net 改了什么

1. 内置 ffmpeg.exe（gyan.dev essentials 8.0.1），切片零依赖
2. `trim.lua` 改造：
   - 键位改成 `h / k / e`（原版同键按两次导出，不直观）
   - ffmpeg 路径智能查找
   - 修掉 Windows 上误触发的 macOS 通知
   - 修正子进程失败判定
3. uosc 控制栏补齐播放 / 暂停按钮（原版没有）
4. 开启 `autoload`：自动加载同目录视频进列表
5. 体积精简：删了 macOS / Linux 二进制、调试符号、多语言冗余包

---

## 更强的 ffmpeg

需要更多编码器：从 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) 下 full-shared 版覆盖 `ffmpeg.exe`。

## License

- 本仓库配置与文档：MIT
- mpv.net：GPLv2 | libmpv：LGPL | FFmpeg：LGPL/GPL
