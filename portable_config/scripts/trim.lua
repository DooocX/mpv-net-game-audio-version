--
--  trim.lua
--  version 2026.07.01 (portable, DocX-modified)
--
--  AGPLv3 License
--  Created by github.com/aerobounce on 2019/11/18.
--  Copyright © 2019-present aerobounce. All rights reserved.
--
--  ---- 本地魔改说明 ----
--  1) 键位：h = 起点 / k = 终点 / e = 导出
--  2) ffmpeg 智能查找：mpv.net 同目录 -> portable_config -> PATH
--     便于绿色分发（把 ffmpeg.exe 放到 mpv.net 根目录即可）
--  3) 去掉 Windows 上误触发的 sh+osascript 通知调用
--  4) 修正子进程结果判断（避免把失败误判成成功）
--
local utils = require "mp.utils"
local msg = require "mp.msg"
local assdraw = require "mp.assdraw"

local is_windows = package.config:sub(1, 1) ~= "/"

------------------------------------------------------------
-- ffmpeg 智能查找
------------------------------------------------------------
-- 优先级：
--   1. mpv.net 可执行文件同目录（分发场景，最保险）
--   2. portable_config 同目录（兼容手动放置）
--   3. 系统 PATH
--
-- Windows 下用 "ffmpeg.exe"，其他系统用 "ffmpeg"

local function file_exists(path)
    if path == nil or path == "" then return false end
    local info = utils.file_info(path)
    return info ~= nil and info.is_file
end

local function join(a, b)
    if a == nil or a == "" then return b end
    local sep = is_windows and "\\" or "/"
    -- 规范化：把反斜杠转正斜杠，避免混用
    local last = string.sub(a, -1)
    if last == "/" or last == "\\" then
        return a .. b
    end
    return a .. sep .. b
end

local function resolve_ffmpeg()
    local exe_name = is_windows and "ffmpeg.exe" or "ffmpeg"

    -- 1) mpv.net 可执行文件所在目录
    --    ~~/  展开到 portable_config 目录
    --    ~~/../  再退一层就是 mpv.net 根目录（即 mpvnet.exe 所在）
    local config_dir = mp.command_native({"expand-path", "~~/"}) or ""
    local exe_dir = ""
    if config_dir ~= "" then
        -- 去掉尾部的 portable_config，得到上一层
        local parent, _ = utils.split_path(config_dir)
        exe_dir = parent or ""
        -- split_path 有时会保留尾部分隔符，规范一下
        if exe_dir:sub(-1) == "/" or exe_dir:sub(-1) == "\\" then
            exe_dir = exe_dir:sub(1, -2)
        end
    end

    local candidates = {}

    if exe_dir ~= "" then
        table.insert(candidates, join(exe_dir, exe_name))
    end
    if config_dir ~= "" then
        table.insert(candidates, join(config_dir, exe_name))
    end

    for _, p in ipairs(candidates) do
        if file_exists(p) then
            msg.log("info", "trim: using local ffmpeg -> " .. p)
            return p
        end
    end

    -- 兜底：交给系统 PATH
    msg.log("info", "trim: local ffmpeg not found, falling back to PATH")
    return exe_name
end

local ffmpeg_bin = resolve_ffmpeg()

------------------------------------------------------------
-- 主逻辑
------------------------------------------------------------
local isVideoFile = false
local stripMetadata = false
local initialized = false
local startPosition = 0.0
local endPosition = 0.0

local function initializeIfNeeded()
    if initialized then
        return
    end
    initialized = true

    --
    -- mpv Settings
    --

    -- "track-list" is consistent against video on/off cycle.
    local videoTrack = mp.get_property_native("track-list")[1] or {}
    isVideoFile = videoTrack["type"] == "video" and videoTrack["albumart"] == "false"

    -- Settings suitable for trimming
    mp.commandv("script-message", "osc-visibility", "always")
    mp.set_property("pause", "yes")
    if isVideoFile then
        mp.set_property("hr-seek", "no")
    end
    mp.set_property("options/keep-open", "always")
    mp.register_event("eof-reached", function()
        msg.log("info", "Playback Reached End of File")
        mp.set_property("pause", "yes")
        mp.commandv("seek", 100, "absolute-percent", "exact")
    end)

    --
    -- Key Bindings
    --

    -- Toggle stripMetadata
    mp.add_forced_key_binding("t", "toggle-strip-metadata", function()
        stripMetadata = not stripMetadata
        local message = ""
        if stripMetadata then
            message ="trim: Strip Metadata Enabled"
        else
            message ="trim: Strip Metadata Disabled"
        end
        mp.osd_message(message, 3)
    end)

    if isVideoFile then
        -- Seeking by Keyframe
        local function seekByKeyframes(amount)
            mp.commandv("seek", amount, "keyframes", "exact")
            mp.command("show-progress")
            updateTrimmingPositionsOSDASS()
        end
        mp.add_forced_key_binding("LEFT", "-0.1_keyframes", function()
            seekByKeyframes(-0.1)
        end, {repeatable = true})
        mp.add_forced_key_binding("RIGHT", "0.1_keyframes", function()
            seekByKeyframes(0.1)
        end, {repeatable = true})
        mp.add_forced_key_binding("UP", "10_keyframes", function()
            seekByKeyframes(10)
        end, {repeatable = true})
        mp.add_forced_key_binding("DOWN", "-10_keyframes", function()
            seekByKeyframes(-10)
        end, {repeatable = true})

        -- Precise Seeking by Seconds
        local function seekBySeconds(amount)
            mp.commandv("seek", amount, "relative", "exact")
            mp.command("show-progress")
            updateTrimmingPositionsOSDASS()
        end
        mp.add_forced_key_binding("shift+LEFT", "-0.1_seconds", function()
            seekBySeconds(-0.1)
        end, {repeatable = true})
        mp.add_forced_key_binding("shift+RIGHT", "0.1_seconds", function()
            seekBySeconds(0.1)
        end, {repeatable = true})
        mp.add_forced_key_binding("shift+UP", "0.5_seconds", function()
            seekBySeconds(0.5)
        end, {repeatable = true})
        mp.add_forced_key_binding("shift+DOWN", "-0.5_seconds", function()
            seekBySeconds(-0.5)
        end, {repeatable = true})

        -- Seek to Default Trim Positions
        if isVideoFile then
            seekByKeyframes(-0.1)
            seekByKeyframes(0.1)
        end
    else
        -- Seeking by Seconds
        local function seekBySeconds(amount)
            mp.commandv("seek", amount, "relative")
            mp.command("show-progress")
            updateTrimmingPositionsOSDASS()
        end
        mp.add_forced_key_binding("LEFT", "-1_seconds", function()
            seekBySeconds(-1)
        end, {repeatable = true})
        mp.add_forced_key_binding("RIGHT", "1_seconds", function()
            seekBySeconds(1)
        end, {repeatable = true})
        mp.add_forced_key_binding("UP", "5_seconds", function()
            seekBySeconds(5)
        end, {repeatable = true})
        mp.add_forced_key_binding("DOWN", "-5_seconds", function()
            seekBySeconds(-5)
        end, {repeatable = true})

        mp.add_forced_key_binding("shift+LEFT", "-10_seconds", function()
            seekBySeconds(-10)
        end, {repeatable = true})
        mp.add_forced_key_binding("shift+RIGHT", "10_seconds", function()
            seekBySeconds(10)
        end, {repeatable = true})
        mp.add_forced_key_binding("shift+UP", "30_seconds", function()
            seekBySeconds(30)
        end, {repeatable = true})
        mp.add_forced_key_binding("shift+DOWN", "-30_seconds", function()
            seekBySeconds(-30)
        end, {repeatable = true})
    end

    -- Seek to Trimming Positions
    mp.add_forced_key_binding("shift+h", "seek-to-start-position", function()
        mp.commandv("seek", startPosition, "absolute")
        mp.command("show-progress")
        updateTrimmingPositionsOSDASS()
    end)
    mp.add_forced_key_binding("shift+k", "seek-to-end-position", function()
        mp.commandv("seek", endPosition, "absolute")
        mp.command("show-progress")
        updateTrimmingPositionsOSDASS()
    end)

    -- Show OSD
    showOsdAss("Enabled trim.lua (h=start, k=end, e=export)")

    -- Set Default Trim Positions
    mp.add_timeout(0.5, function()
        -- If initialized by startPosition, trim should be startPosition to EOF.
        if startPosition ~= 0.0 then
            startPosition = mp.get_property_number("time-pos")
            endPosition = mp.get_property_native("duration")
            if startPosition == "none" then startPosition = 0.0 end

        -- If initialized by endPosition, trim should be 0.0 to endPosition.
        elseif endPosition ~= 0.0 then
            startPosition = 0.0
            if endPosition == "none" then endPosition = 0.0 end
        end

        updateTrimmingPositionsOSDASS()
    end)
end

local function getTrimmingPositionsText()
    local function formatSeconds(seconds)
        local formatted = string.format("%02d:%02d.%03d",
                                        math.floor(seconds / 60) % 60,
                                        math.floor(seconds) % 60,
                                        seconds * 1000 % 1000)
        if seconds > 3600 then
            formatted = string.format("%d:%s",
                                      math.floor(seconds / 3600),
                                      formatted)
        end
        return formatted
    end

    return "Trimming: " .. tostring(formatSeconds(startPosition, true)) ..
               " secs ~ " .. tostring(formatSeconds(endPosition, true)) ..
               " secs"
end

local function generateDestinationPath()
    local path = mp.get_property("path") or ""
    local filename = mp.get_property("filename/no-ext") or "encode"
    local extension = tostring(string.match(path, "%.([^.]+)$"))
    local destinationDirectory, _ = utils.split_path(path)
    local contents = utils.readdir(destinationDirectory)

    if not contents then
        return nil
    end

    local files = {}

    for _, f in ipairs(contents) do
        files[f] = true
    end

    local output = filename .. " $n." .. extension

    if not string.find(output, "$n") then
        return files[output] and nil or output
    end

    local i = 1

    while true do
        local potential_name = string.gsub(output, "$n", tostring(i))
        if not files[potential_name] then
            return destinationDirectory .. potential_name
        end
        i = i + 1
    end
end

function showOsdAss(message)
    msg.log("info", message)
    ass = assdraw.ass_new()
    ass:pos(10, 34)
    ass:append(message)
    mp.set_osd_ass(0, 0, ass.text)
end

function updateTrimmingPositionsOSDASS()
    mp.osd_message("", 1)
    showOsdAss(getTrimmingPositionsText())
end

function setStartPosition()
    initializeIfNeeded()

    if isVideoFile then
        -- Make sure current time-pos is a keyframes
        mp.commandv("seek", -0.01, "keyframes", "exact")
        mp.commandv("seek", 0.01, "keyframes", "exact")
    end

    startPosition = mp.get_property_number("time-pos")
    updateTrimmingPositionsOSDASS()
end

function setEndPosition()
    initializeIfNeeded()
    endPosition = mp.get_property_number("time-pos")
    updateTrimmingPositionsOSDASS()
end

function exportTrim()
    initializeIfNeeded()
    writeOut()
end

function writeOut()
    --
    -- Error Handlings
    --
    if startPosition == nil or startPosition == "none" or endPosition == nil or
        endPosition == "none" then
        message = "trim: Error - Start or End Position is unassigned."
        mp.osd_message(message, 3)
    end

    if startPosition == endPosition then
        message = "trim: Error - Start & End Position cannot be the same."
        mp.osd_message(message, 3)
        return
    end

    if startPosition > endPosition then
        message = "trim: Error - Start Position is exceeding the End Position."
        mp.osd_message(message, 3)
        return
    end

    if endPosition < startPosition then
        message = "trim: Error - End Position cannot be smaller then the Start Position."
        mp.osd_message(message, 3)
        return
    end

    -- Generate Destination Path
    local destinationPath = generateDestinationPath()

    if destinationPath == nil or destinationPath == "" then
        message = "trim: Failed to generate destination path."
        mp.osd_message(message, 3)
        return
    end

    -- Prepare values
    local trimDuration = endPosition - startPosition
    local sourcePath = mp.get_property_native("path")

    local message = getTrimmingPositionsText() .. "\nWriting out... "
    mp.set_osd_ass(0, 0, "")
    mp.osd_message(message, 10)

    -- Compose command
    local args = {
        ffmpeg_bin,

        "-hide_banner",
        "-loglevel", "verbose",

        "-ss", tostring(startPosition),
        "-i", tostring(sourcePath),
        "-t", tostring(trimDuration),

        "-map", "v:0?",
        "-map", "a:0?",
        "-c", "copy"
    }

    if stripMetadata then
        table.insert(args, "-err_detect")
        table.insert(args, "ignore_err")
        table.insert(args, "-ignore_chapters")
        table.insert(args, "1")
        table.insert(args, "-map_metadata")
        table.insert(args, "-1")
        table.insert(args, "-fflags")
        table.insert(args, "+bitexact")
        table.insert(args, "-flags:v")
        table.insert(args, "+bitexact")
        table.insert(args, "-flags:a")
        table.insert(args, "+bitexact")
    end

    table.insert(args, "-avoid_negative_ts")
    table.insert(args, "make_zero")
    table.insert(args, "-async")
    table.insert(args, "1")
    table.insert(args, destinationPath)

    -- Print command to console
    msg.log("info", "Executing ffmpeg command:")
    for _, val in pairs(args) do
        msg.log("info", val)
    end

    -- Execute command
    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true
    }, function(success, result, err)
        local status = result and result.status or nil
        local status_number = tonumber(status)
        local stderr_text = result and result.stderr or ""
        local error_text = err or (result and result.error_string) or nil
        local has_error_text = error_text ~= nil and error_text ~= ""
        local has_nonzero_status = status ~= nil and ((status_number ~= nil and status_number ~= 0) or (status_number == nil and tostring(status) ~= "0"))
        local should_fail = has_error_text or has_nonzero_status or ((not success) and status ~= 0 and status ~= "0")

        if should_fail then
            local detail = error_text
            if (detail == nil or detail == "") and status ~= nil then
                detail = "exit status " .. tostring(status)
            end
            message = message .. "Failed."
            if detail ~= nil and detail ~= "" then
                message = message .. " " .. detail
            end
            msg.log("error", message)
            if stderr_text ~= nil and stderr_text ~= "" then
                msg.log("error", stderr_text)
            end
            mp.osd_message(message, 10)
            return
        end

        msg.log("info", "Success!: '" .. destinationPath .. "'")
        local successMessage = "导出成功\n" .. destinationPath
        msg.log("info", successMessage)
        mp.osd_message(successMessage, 4)

        if not is_windows then
            mp.command_native_async({
                name = "subprocess",
                args = {
                    "sh", "-c",
[[osascript << EOL 2> /dev/null
display notification "Success ✅" with title "mpv: trim" sound name "Glass"
EOL]]
                },
                capture_stdout = false
            }, function(_, _, _)
            end)
        end
    end)
end

--
-- Static Key Bindings
--
mp.add_key_binding("h", "trim-set-start-position", setStartPosition)
mp.add_key_binding("k", "trim-set-end-position", setEndPosition)
mp.add_key_binding("e", "trim-write-out", exportTrim)
