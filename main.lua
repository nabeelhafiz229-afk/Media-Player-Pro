require "import"
import "android.widget.*"
import "android.view.*"
import "android.provider.MediaStore"
import "java.io.File"
import "java.io.FileInputStream"
import "java.io.FileOutputStream"
import "android.media.MediaPlayer"
import "android.content.Intent"
import "android.net.Uri"
import "android.text.TextWatcher"
import "android.media.MediaScannerConnection"
import "android.os.Environment"
import "android.os.Handler"
import "android.content.Context"
import "android.os.Build"
import "android.os.StrictMode"
import "android.content.ContentUris"
import "java.lang.reflect.Array"
import "android.widget.VideoView"
import "android.content.DialogInterface"
import "android.media.audiofx.Equalizer"
import "android.media.audiofx.BassBoost"

local dlg = LuaDialog()
dlg.setTitle("Media Player Pro")

local allFiles = {}
local fileListView, fileCountLabel, sortSpinner, searchBox, ctx
local btnRewind, btnForward, btnPlayPause, audioSeekBar
local btnRecentlyPlayed, btnIncompletePlaying

local skipSeconds = 10
local playbackSpeed = 1.0
local playbackPitch = 1.0
local bassBoostLevel = 0
local eqPreset = 0

local bassBoostEffect = nil
local equalizerEffect = nil

local mediaPlayer = _G.globalMediaPlayer or nil
local currentPlayingFile = _G.globalCurrentPlayingFile or nil
local currentIndex = _G.globalCurrentIndex or -1
local pausedPosition = _G.globalPausedPosition or 0

local isLoopEnabled = false
local isShuffleEnabled = false
local isBackgroundPlayEnabled = false
local isFullScreen = false

local prefs = nil
local PREFS_NAME = "MediaPlayerProPrefs"

local currentFolder = ""
local currentMediaType = "audio"

local loadAndSortAudioFiles
local loadAndSortVideoFiles
local playAudioByIndex
local togglePlayAudio
local showMoreOptionsMenu
local saveCurrentState
local loadSavedState
local saveToHistory
local showRecentlyPlayedDialog
local showIncompleteDialog
local applyPlaybackSpeedAndPitch
local applyAudioEffects
local showFoldersDialog
local playVideoByIndex

local videoDlg = nil
local activeVideoMediaPlayer = nil
local videoIds = {}
local videoHandler = Handler()
local updateVideoProgress = nil

local audioHandler = Handler()
local updateAudioProgress = nil

local function dp2px(dp)
    return math.floor(dp * ctx.getResources().getDisplayMetrics().density + 0.5)
end

local function updateGlobalState()
    _G.globalMediaPlayer = mediaPlayer
    _G.globalCurrentPlayingFile = currentPlayingFile
    _G.globalCurrentIndex = currentIndex
    _G.globalPausedPosition = pausedPosition
end

local function saveVideoCurrentPosition()
    pcall(function()
        if videoIds.myVideoView and currentPlayingFile and currentMediaType == "video" then
            local pos = videoIds.myVideoView.getCurrentPosition()
            local dur = videoIds.myVideoView.getDuration()
            if pos > 0 and (dur <= 0 or pos < (dur - 1000)) then
                prefs.edit().putInt("pos_" .. currentPlayingFile, pos).commit()
            end
        end
    end)
end

applyAudioEffects = function(mp)
    if not mp then return end
    if bassBoostLevel == 0 and eqPreset == 0 then return end
    pcall(function()
        local sessionId = mp.getAudioSessionId()
        if sessionId > 0 then
            if bassBoostLevel > 0 then
                if bassBoostEffect then
                    pcall(function() bassBoostEffect.release() end)
                end
                bassBoostEffect = BassBoost(0, sessionId)
                bassBoostEffect.setEnabled(true)
                bassBoostEffect.setStrength(bassBoostLevel)
            end

            if eqPreset > 0 or (eqPreset == 0 and bassBoostLevel > 0) then
                if equalizerEffect then
                    pcall(function() equalizerEffect.release() end)
                end
                equalizerEffect = Equalizer(0, sessionId)
                equalizerEffect.setEnabled(true)
                if eqPreset >= 0 then
                    pcall(function() equalizerEffect.usePreset(eqPreset) end)
                end
            end
        end
    end)
end

applyPlaybackSpeedAndPitch = function(mp)
    if mp and Build.VERSION.SDK_INT >= 23 then
        pcall(function()
            local params = mp.getPlaybackParams()
            params.setSpeed(playbackSpeed)
            params.setPitch(playbackPitch)
            mp.setPlaybackParams(params)
        end)
    end
end

playVideoByIndex = function(target, startPosition)
    local index = -1
    local videoPath = nil

    if type(target) == "number" then
        if target < 1 or target > #allFiles then
            return
        end
        index = target
        local item = allFiles[index]
        if not item or item.type ~= "video" then
            return
        end
        videoPath = item.path
    elseif type(target) == "string" then
        videoPath = target
        for i, item in ipairs(allFiles) do
            if item.path == videoPath then
                index = i
                break
            end
        end
        if index == -1 then
            index = 1
        end
    end

    if not videoPath then
        return
    end

    local vidFile = File(videoPath)
    if not vidFile.exists() then
        return
    end

    currentIndex = index
    currentPlayingFile = videoPath
    currentMediaType = "video"
    saveToHistory(videoPath)
    updateGlobalState()

    if startPosition and startPosition > 0 then
        pausedPosition = startPosition
    else
        pausedPosition = prefs and prefs.getInt("pos_" .. videoPath, 0) or 0
    end

    if not videoDlg then
        videoDlg = LuaDialog(ctx)

        local videoLayout = {
            ScrollView,
            layout_width = "match_parent",
            layout_height = "match_parent",

            {
                LinearLayout,
                orientation = "vertical",
                layout_width = "match_parent",
                layout_height = "wrap_content",
                padding = "10dp",

                {
                    VideoView,
                    id = "myVideoView",
                    layout_width = "match_parent",
                    layout_height = "210dp",
                    layout_marginBottom = "6dp"
                },

                {
                    LinearLayout,
                    orientation = "vertical",
                    layout_width = "match_parent",
                    layout_height = "wrap_content",

                    {
                        LinearLayout,
                        orientation = "horizontal",
                        layout_width = "match_parent",
                        layout_marginBottom = "4dp",

                        {
                            Button,
                            text = "Prev",
                            layout_weight = 1,
                            layout_marginRight = "4dp",

                            onClick = function()
                                saveVideoCurrentPosition()
                                pcall(function()
                                    if videoIds.myVideoView then
                                        videoIds.myVideoView.stopPlayback()
                                    end
                                end)
                                if currentIndex > 1 then
                                    playVideoByIndex(currentIndex - 1, 0)
                                elseif #allFiles > 0 then
                                    playVideoByIndex(#allFiles, 0)
                                end
                            end
                        },

                        {
                            Button,
                            id = "btnVideoRewind",
                            text = "-" .. skipSeconds .. "s",
                            layout_weight = 1,
                            layout_marginRight = "4dp",

                            onClick = function()
                                local vv = videoIds.myVideoView
                                if vv then
                                    local pos = vv.getCurrentPosition()
                                    local newPos = pos - (skipSeconds * 1000)
                                    if newPos < 0 then
                                        newPos = 0
                                    end
                                    vv.seekTo(newPos)
                                    saveVideoCurrentPosition()
                                end
                            end
                        },

                        {
                            Button,
                            id = "btnVideoPlayPause",
                            text = "Pause",
                            layout_weight = 1,

                            onClick = function()
                                local vv = videoIds.myVideoView
                                if vv then
                                    if vv.isPlaying() then
                                        vv.pause()
                                        saveVideoCurrentPosition()
                                        if videoIds.btnVideoPlayPause then
                                            videoIds.btnVideoPlayPause.setText("Play")
                                        end
                                    else
                                        vv.start()
                                        if videoIds.btnVideoPlayPause then
                                            videoIds.btnVideoPlayPause.setText("Pause")
                                        end
                                    end
                                end
                            end
                        }
                    },

                    {
                        LinearLayout,
                        orientation = "horizontal",
                        layout_width = "match_parent",
                        layout_marginBottom = "4dp",

                        {
                            Button,
                            id = "btnVideoForward",
                            text = "+" .. skipSeconds .. "s",
                            layout_weight = 1,
                            layout_marginRight = "4dp",

                            onClick = function()
                                local vv = videoIds.myVideoView
                                if vv then
                                    local pos = vv.getCurrentPosition()
                                    local dur = vv.getDuration()
                                    local newPos = pos + (skipSeconds * 1000)
                                    if newPos > dur then
                                        newPos = dur
                                    end
                                    vv.seekTo(newPos)
                                    saveVideoCurrentPosition()
                                end
                            end
                        },

                        {
                            Button,
                            text = "Next",
                            layout_weight = 1,
                            layout_marginRight = "4dp",

                            onClick = function()
                                saveVideoCurrentPosition()
                                pcall(function()
                                    if videoIds.myVideoView then
                                        videoIds.myVideoView.stopPlayback()
                                    end
                                end)
                                if currentIndex < #allFiles then
                                    playVideoByIndex(currentIndex + 1, 0)
                                elseif #allFiles > 0 then
                                    playVideoByIndex(1, 0)
                                end
                            end
                        },

                        {
                            Button,
                            id = "btnFullScreen",
                            text = "Full Screen",
                            layout_weight = 1,
                            layout_marginRight = "4dp",

                            onClick = function()
                                local vv = videoIds.myVideoView
                                if vv then
                                    local params = vv.getLayoutParams()
                                    if not isFullScreen then
                                        params.height = dp2px(400)
                                        vv.setLayoutParams(params)
                                        isFullScreen = true
                                        if videoIds.btnFullScreen then
                                            videoIds.btnFullScreen.setText("Normal Screen")
                                        end
                                    else
                                        params.height = dp2px(210)
                                        vv.setLayoutParams(params)
                                        isFullScreen = false
                                        if videoIds.btnFullScreen then
                                            videoIds.btnFullScreen.setText("Full Screen")
                                        end
                                    end
                                end
                            end
                        },

                        {
                            Button,
                            id = "btnVideoMore",
                            text = "More",
                            layout_weight = 1,

                            onClick = function()
                                showMoreOptionsMenu()
                            end
                        }
                    },

                    {
                        LinearLayout,
                        orientation = "horizontal",
                        layout_width = "match_parent",
                        layout_marginBottom = "4dp",

                        {
                            SeekBar,
                            id = "videoSeekBar",
                            layout_width = "match_parent",
                            layout_height = "wrap_content",
                            layout_weight = 1
                        }
                    },

                    {
                        LinearLayout,
                        orientation = "horizontal",
                        layout_width = "match_parent",
                        layout_marginBottom = "4dp",

                        {
                            Button,
                            id = "btnVideoSettings",
                            text = "Settings",
                            layout_weight = 1,
                            layout_marginRight = "4dp",

                            onClick = function()
                                local setDlg = LuaDialog(ctx)
                                setDlg.setTitle("Video Settings")

                                local jumpTimeSpinner
                                local speedSpinner
                                local pitchSpinner
                                local bassSpinner

                                local setLayout = {
                                    LinearLayout,
                                    orientation = "vertical",
                                    padding = "15dp",

                                    {
                                        TextView,
                                        text = "Skip Time:",
                                        textSize = "14sp",
                                        layout_marginBottom = "5dp"
                                    },

                                    {
                                        Spinner,
                                        id = "vidJumpTimeSpinner",
                                        layout_width = "match_parent",
                                        layout_marginBottom = "10dp"
                                    },

                                    {
                                        TextView,
                                        text = "Playback Speed:",
                                        textSize = "14sp",
                                        layout_marginBottom = "5dp"
                                    },

                                    {
                                        Spinner,
                                        id = "vidSpeedSpinner",
                                        layout_width = "match_parent",
                                        layout_marginBottom = "10dp"
                                    },

                                    {
                                        TextView,
                                        text = "Audio Pitch:",
                                        textSize = "14sp",
                                        layout_marginBottom = "5dp"
                                    },

                                    {
                                        Spinner,
                                        id = "vidPitchSpinner",
                                        layout_width = "match_parent",
                                        layout_marginBottom = "10dp"
                                    },

                                    {
                                        TextView,
                                        text = "Bass & Sound Effect:",
                                        textSize = "14sp",
                                        layout_marginBottom = "5dp"
                                    },

                                    {
                                        Spinner,
                                        id = "vidBassSpinner",
                                        layout_width = "match_parent",
                                        layout_marginBottom = "10dp"
                                    },

                                    {
                                        Button,
                                        text = "Save & Close",
                                        layout_width = "match_parent",

                                        onClick = function()
                                            local selectedJumpPos = jumpTimeSpinner.getSelectedItemPosition()
                                            if selectedJumpPos == 0 then skipSeconds = 10
                                            elseif selectedJumpPos == 1 then skipSeconds = 20
                                            elseif selectedJumpPos == 2 then skipSeconds = 30
                                            elseif selectedJumpPos == 3 then skipSeconds = 60 end

                                            local selectedSpeedPos = speedSpinner.getSelectedItemPosition()
                                            if selectedSpeedPos == 0 then playbackSpeed = 0.5
                                            elseif selectedSpeedPos == 1 then playbackSpeed = 0.8
                                            elseif selectedSpeedPos == 2 then playbackSpeed = 1.0
                                            elseif selectedSpeedPos == 3 then playbackSpeed = 1.25
                                            elseif selectedSpeedPos == 4 then playbackSpeed = 1.5
                                            elseif selectedSpeedPos == 5 then playbackSpeed = 2.0 end

                                            local selectedPitchPos = pitchSpinner.getSelectedItemPosition()
                                            if selectedPitchPos == 0 then playbackPitch = 0.5
                                            elseif selectedPitchPos == 1 then playbackPitch = 0.8
                                            elseif selectedPitchPos == 2 then playbackPitch = 1.0
                                            elseif selectedPitchPos == 3 then playbackPitch = 1.25
                                            elseif selectedPitchPos == 4 then playbackPitch = 1.5
                                            elseif selectedPitchPos == 5 then playbackPitch = 2.0 end

                                            local selectedBassPos = bassSpinner.getSelectedItemPosition()
                                            if selectedBassPos == 0 then bassBoostLevel = 0; eqPreset = 0
                                            elseif selectedBassPos == 1 then bassBoostLevel = 500; eqPreset = 0
                                            elseif selectedBassPos == 2 then bassBoostLevel = 1000; eqPreset = 0
                                            elseif selectedBassPos == 3 then bassBoostLevel = 300; eqPreset = 1
                                            elseif selectedBassPos == 4 then bassBoostLevel = 300; eqPreset = 2
                                            elseif selectedBassPos == 5 then bassBoostLevel = 300; eqPreset = 3
                                            elseif selectedBassPos == 6 then bassBoostLevel = 200; eqPreset = 4
                                            elseif selectedBassPos == 7 then bassBoostLevel = 800; eqPreset = 5
                                            elseif selectedBassPos == 8 then bassBoostLevel = 1000; eqPreset = 6
                                            elseif selectedBassPos == 9 then bassBoostLevel = 0; eqPreset = 7 end

                                            if activeVideoMediaPlayer then
                                                applyPlaybackSpeedAndPitch(activeVideoMediaPlayer)
                                                applyAudioEffects(activeVideoMediaPlayer)
                                            end

                                            if videoIds.btnVideoRewind then
                                                videoIds.btnVideoRewind.setText("-" .. skipSeconds .. "s")
                                            end
                                            if videoIds.btnVideoForward then
                                                videoIds.btnVideoForward.setText("+" .. skipSeconds .. "s")
                                            end

                                            saveCurrentState()
                                            setDlg.dismiss()
                                        end
                                    }
                                }

                                local setViewIds = {}
                                setDlg.setView(loadlayout(setLayout, setViewIds))
                                jumpTimeSpinner = setViewIds.vidJumpTimeSpinner
                                speedSpinner = setViewIds.vidSpeedSpinner
                                pitchSpinner = setViewIds.vidPitchSpinner
                                bassSpinner = setViewIds.vidBassSpinner

                                jumpTimeSpinner.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_dropdown_item, {"10 Sec", "20 Sec", "30 Sec", "1 Min"}))
                                speedSpinner.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_dropdown_item, {"0.5x", "0.8x", "1.0x (Normal)", "1.25x", "1.5x", "2.0x"}))
                                pitchSpinner.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_dropdown_item, {"0.5x", "0.8x", "1.0x (Normal)", "1.25x", "1.5x", "2.0x"}))
                                bassSpinner.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_dropdown_item, {"Normal (No Effect)", "Bass Boost (Medium)", "Bass Boost (High)", "Rock", "Pop", "Jazz", "Classical", "Dance / Club", "Hip Hop / Rap", "Vocal Clear (Speech)"}))

                                if skipSeconds == 10 then jumpTimeSpinner.setSelection(0)
                                elseif skipSeconds == 20 then jumpTimeSpinner.setSelection(1)
                                elseif skipSeconds == 30 then jumpTimeSpinner.setSelection(2)
                                elseif skipSeconds == 60 then jumpTimeSpinner.setSelection(3) end

                                if playbackSpeed == 0.5 then speedSpinner.setSelection(0)
                                elseif playbackSpeed == 0.8 then speedSpinner.setSelection(1)
                                elseif playbackSpeed == 1.0 then speedSpinner.setSelection(2)
                                elseif playbackSpeed == 1.25 then speedSpinner.setSelection(3)
                                elseif playbackSpeed == 1.5 then speedSpinner.setSelection(4)
                                elseif playbackSpeed == 2.0 then speedSpinner.setSelection(5)
                                else speedSpinner.setSelection(2) end

                                if playbackPitch == 0.5 then pitchSpinner.setSelection(0)
                                elseif playbackPitch == 0.8 then pitchSpinner.setSelection(1)
                                elseif playbackPitch == 1.0 then pitchSpinner.setSelection(2)
                                elseif playbackPitch == 1.25 then pitchSpinner.setSelection(3)
                                elseif playbackPitch == 1.5 then pitchSpinner.setSelection(4)
                                elseif playbackPitch == 2.0 then pitchSpinner.setSelection(5)
                                else pitchSpinner.setSelection(2) end

                                if bassBoostLevel == 0 and eqPreset == 0 then bassSpinner.setSelection(0)
                                elseif bassBoostLevel == 500 and eqPreset == 0 then bassSpinner.setSelection(1)
                                elseif bassBoostLevel == 1000 and eqPreset == 0 then bassSpinner.setSelection(2)
                                elseif eqPreset == 1 then bassSpinner.setSelection(3)
                                elseif eqPreset == 2 then bassSpinner.setSelection(4)
                                elseif eqPreset == 3 then bassSpinner.setSelection(5)
                                elseif eqPreset == 4 then bassSpinner.setSelection(6)
                                elseif eqPreset == 5 then bassSpinner.setSelection(7)
                                elseif eqPreset == 6 then bassSpinner.setSelection(8)
                                elseif eqPreset == 7 then bassSpinner.setSelection(9)
                                else bassSpinner.setSelection(0) end

                                setDlg.show()
                            end
                        },

                        {
                            Button,
                            text = "Close",
                            layout_weight = 1,

                            onClick = function()
                                saveVideoCurrentPosition()
                                pcall(function()
                                    if videoIds.myVideoView then
                                        videoIds.myVideoView.stopPlayback()
                                    end
                                end)
                                pcall(function()
                                    videoHandler.removeCallbacks(updateVideoProgress)
                                end)
                                videoDlg.dismiss()
                                videoDlg = nil
                            end
                        }
                    }
                }
            }
        }

        videoDlg.setView(loadlayout(videoLayout, videoIds))

        if videoIds.videoSeekBar then
            videoIds.videoSeekBar.setOnSeekBarChangeListener(
                SeekBar.OnSeekBarChangeListener {
                    onProgressChanged = function(seekBar, progress, fromUser)
                        if fromUser and videoIds.myVideoView then
                            videoIds.myVideoView.seekTo(progress)
                            saveVideoCurrentPosition()
                        end
                    end,
                    onStartTrackingTouch = function(seekBar) end,
                    onStopTrackingTouch = function(seekBar) end
                }
            )
        end

        videoDlg.setOnDismissListener(
            DialogInterface.OnDismissListener {
                onDismiss = function(dialog)
                    saveVideoCurrentPosition()
                    pcall(function()
                        if videoIds.myVideoView then
                            videoIds.myVideoView.stopPlayback()
                        end
                    end)
                    pcall(function()
                        videoHandler.removeCallbacks(updateVideoProgress)
                    end)
                    videoDlg = nil
                end
            }
        )
        videoDlg.show()
    end

    videoDlg.setTitle(vidFile.getName())

    updateVideoProgress = function()
        pcall(function()
            if videoIds.myVideoView and videoIds.myVideoView.isPlaying() then
                local currentPos = videoIds.myVideoView.getCurrentPosition()
                if videoIds.videoSeekBar then
                    videoIds.videoSeekBar.setProgress(currentPos)
                end
                saveVideoCurrentPosition()
            end
        end)
        pcall(function()
            videoHandler.postDelayed(updateVideoProgress, 1000)
        end)
    end

    local videoView = videoIds.myVideoView
    if videoView then
        pcall(function()
            videoView.stopPlayback()
            videoView.suspend()
        end)
        pcall(function()
            videoView.setVideoPath(videoPath)
        end)
        videoView.requestFocus()
        videoView.setOnPreparedListener(
            MediaPlayer.OnPreparedListener {
                onPrepared = function(mp)
                    activeVideoMediaPlayer = mp
                    applyPlaybackSpeedAndPitch(mp)
                    applyAudioEffects(mp)

                    local duration = videoView.getDuration()
                    if videoIds.videoSeekBar then
                        videoIds.videoSeekBar.setMax(duration)
                        videoIds.videoSeekBar.setProgress(pausedPosition)
                    end

                    if pausedPosition > 0 then
                        videoView.seekTo(pausedPosition)
                    end

                    videoView.start()
                    if videoIds.btnVideoPlayPause then
                        videoIds.btnVideoPlayPause.setText("Pause")
                    end
                    pcall(function()
                        videoHandler.removeCallbacks(updateVideoProgress)
                        videoHandler.post(updateVideoProgress)
                    end)
                end
            }
        )

        videoView.setOnCompletionListener(
            MediaPlayer.OnCompletionListener {
                onCompletion = function(mp)
                    if prefs and currentPlayingFile then
                        prefs.edit().remove("pos_" .. currentPlayingFile).commit()
                        saveToHistory(currentPlayingFile)
                    end
                    pausedPosition = 0
                    if videoIds.btnVideoPlayPause then
                        videoIds.btnVideoPlayPause.setText("Play")
                    end
                    pcall(function()
                        videoHandler.removeCallbacks(updateVideoProgress)
                    end)
                end
            }
        )
    end

    pcall(function()
        videoDlg.show()
    end)
end

saveCurrentState = function()
    if prefs then
        local editor = prefs.edit()

        if currentIndex > 0 and allFiles[currentIndex] and allFiles[currentIndex].type == "audio" then
            local path = allFiles[currentIndex].path

            editor.putString("saved_path", path)
            editor.putInt("saved_index", currentIndex)

            local currentPos = 0

            if mediaPlayer then
                pcall(function()
                    currentPos = mediaPlayer.getCurrentPosition()
                end)
            else
                currentPos = pausedPosition
            end

            editor.putInt("saved_position", currentPos)

            if currentPos > 0 then
                local dur = 0

                if mediaPlayer then
                    pcall(function()
                        dur = mediaPlayer.getDuration()
                    end)
                end

                if dur <= 0 or currentPos < (dur - 1000) then
                    editor.putInt("pos_" .. path, currentPos)
                else
                    editor.remove("pos_" .. path)
                end
            end
        else
            editor.putString("saved_path", "")
            editor.putInt("saved_index", -1)
            editor.putInt("saved_position", 0)
        end

        editor.putBoolean("settings_loop", isLoopEnabled)
        editor.putBoolean("settings_shuffle", isShuffleEnabled)
        editor.putBoolean("settings_background_play", isBackgroundPlayEnabled)
        editor.putFloat("settings_speed", playbackSpeed)
        editor.putFloat("settings_pitch", playbackPitch)
        editor.putInt("settings_bass", bassBoostLevel)
        editor.putInt("settings_preset", eqPreset)
        editor.commit()
    end
end

saveToHistory = function(path)
    if not prefs then
        return
    end

    local historyStr = prefs.getString("history_paths", "")
    local list = {}

    for p in historyStr:gmatch("[^|]+") do
        if p ~= path and p ~= "" then
            table.insert(list, p)
        end
    end

    table.insert(list, 1, path)

    local newHistory = ""

    for i = 1, math.min(#list, 20) do
        newHistory = newHistory .. list[i] .. "|"
    end

    prefs.edit().putString("history_paths", newHistory).commit()
end

loadSavedState = function()
    if prefs then
        local savedPath = prefs.getString("saved_path", "")
        local savedIndex = prefs.getInt("saved_index", -1)
        local savedPos = prefs.getInt("saved_position", 0)

        isLoopEnabled = prefs.getBoolean("settings_loop", false)
        isShuffleEnabled = prefs.getBoolean("settings_shuffle", false)
        isBackgroundPlayEnabled = prefs.getBoolean("settings_background_play", false)
        playbackSpeed = prefs.getFloat("settings_speed", 1.0)
        playbackPitch = prefs.getFloat("settings_pitch", 1.0)
        bassBoostLevel = prefs.getInt("settings_bass", 0)
        eqPreset = prefs.getInt("settings_preset", 0)

        if savedPath ~= "" then
            currentPlayingFile = savedPath
            currentIndex = savedIndex
            pausedPosition = savedPos

            for i, item in ipairs(allFiles) do
                if item.path == savedPath then
                    currentIndex = i
                    break
                end
            end
        end
    end
end

local function collectFiles(d, list, mediaType, isRecursive)
    if not d or not d.exists() or not d.isDirectory() then
        return
    end
    local files = d.listFiles()
    if files then
        local fileCount = Array.getLength(files)
        for i = 0, fileCount - 1 do
            local file = files[i]
            if file.isDirectory() then
                if isRecursive and file.canRead() then
                    collectFiles(file, list, mediaType, true)
                end
            else
                local name = file.getName():lower()
                local match = false
                if mediaType == "audio" then
                    match = name:match("%.mp3$")
                    or name:match("%.wav$")
                    or name:match("%.m4a$")
                    or name:match("%.aac$")
                    or name:match("%.ogg$")
                    or name:match("%.flac$")
                elseif mediaType == "video" then
                    match = name:match("%.mp4$")
                    or name:match("%.mkv$")
                    or name:match("%.3gp$")
                    or name:match("%.avi$")
                    or name:match("%.mov$")
                    or name:match("%.webm$")
                    or name:match("%.m4v$")
                end
                if match then
                    local filePath = file.getAbsolutePath()
                    local fDate = ""
                    local fLastMod = 0
                    local fSize = 0
                    pcall(function()
                        fLastMod = file.lastModified()
                        if fLastMod and fLastMod > 0 then
                            fDate = os.date("%Y-%m-%d", math.floor(fLastMod / 1000))
                        else
                            fDate = "Unknown"
                        end
                        fSize = file.length()
                    end)
                    table.insert(
                        list,
                        {
                            name = file.getName(),
                            path = filePath,
                            date = fDate,
                            lastModified = fLastMod,
                            size = fSize,
                            type = mediaType
                        }
                    )
                end
            end
        end
    end
end

loadAndSortAudioFiles = function(specificFolder)
    allFiles = {}
    currentFolder = specificFolder or ""
    currentMediaType = "audio"

    if searchBox then
        if specificFolder and specificFolder ~= "" then
            searchBox.setHint("Search Audio Folder")
        else
            searchBox.setHint("Search Audios")
        end
    end

    local selectedSort = 0
    if sortSpinner then
        selectedSort = sortSpinner.getSelectedItemPosition()
    end

    pcall(function()
        local uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        local cursor = ctx.getContentResolver().query(uri, nil, nil, nil, nil)
        if cursor then
            local nameCol = cursor.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
            local dataCol = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)

            while cursor.moveToNext() do
                local path = cursor.getString(dataCol)
                if path then
                    local file = File(path)
                    if file.exists() then
                        local name = cursor.getString(nameCol) or file.getName()
                        local fLastMod = 0
                        local fSize = 0
                        local fDate = "Unknown"
                        pcall(function()
                            fLastMod = file.lastModified()
                            if fLastMod and fLastMod > 0 then
                                fDate = os.date("%Y-%m-%d", math.floor(fLastMod / 1000))
                            end
                            fSize = file.length()
                        end)

                        local include = true
                        if specificFolder and specificFolder ~= "" then
                            if not path:find(specificFolder, 1, true) then
                                include = false
                            end
                        end

                        if include then
                            table.insert(allFiles, {
                                name = name,
                                path = path,
                                date = fDate,
                                lastModified = fLastMod,
                                size = fSize,
                                type = "audio"
                            })
                        end
                    end
                end
            end
            cursor.close()
        end
    end)

    if #allFiles == 0 and (not specificFolder or specificFolder == "") then
        pcall(function()
            local rootDir = Environment.getExternalStorageDirectory()
            collectFiles(rootDir, allFiles, "audio", true)
        end)
    end

    if selectedSort == 0 or selectedSort == 6 then
        table.sort(allFiles, function(a, b) return a.lastModified > b.lastModified end)
    elseif selectedSort == 1 then
        table.sort(allFiles, function(a, b) return a.lastModified < b.lastModified end)
    elseif selectedSort == 2 then
        table.sort(allFiles, function(a, b) return a.size > b.size end)
    elseif selectedSort == 3 or selectedSort == 5 then
        table.sort(allFiles, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    elseif selectedSort == 4 then
        table.sort(allFiles, function(a, b) return tostring(a.name):lower() > tostring(b.name):lower() end)
    end

    local displayNames = {}

    if #allFiles == 0 then
        table.insert(displayNames, "No audio files found")
    else
        for _, item in ipairs(allFiles) do
            local displayName = item.name
            
            if selectedSort == 6 and item.date ~= "" then
                displayName = item.name .. " (Date: " .. item.date .. ")"
            end

            table.insert(displayNames, displayName)
        end
    end

    if fileCountLabel then
        fileCountLabel.setText("Total Audio Files: " .. #allFiles)
    end

    if fileListView then
        fileListView.setAdapter(
            ArrayAdapter(
                ctx,
                android.R.layout.simple_list_item_1,
                displayNames
            )
        )
    end

    loadSavedState()
end

loadAndSortVideoFiles = function(specificFolder)
    allFiles = {}
    currentFolder = specificFolder or ""
    currentMediaType = "video"

    if searchBox then
        if specificFolder and specificFolder ~= "" then
            searchBox.setHint("Search Video Folder")
        else
            searchBox.setHint("Search Videos")
        end
    end

    local selectedSort = 0
    if sortSpinner then
        selectedSort = sortSpinner.getSelectedItemPosition()
    end

    pcall(function()
        local uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        local cursor = ctx.getContentResolver().query(uri, nil, nil, nil, nil)
        if cursor then
            local nameCol = cursor.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
            local dataCol = cursor.getColumnIndex(MediaStore.Video.Media.DATA)

            while cursor.moveToNext() do
                local path = cursor.getString(dataCol)
                if path then
                    local file = File(path)
                    if file.exists() then
                        local name = cursor.getString(nameCol) or file.getName()
                        local fLastMod = 0
                        local fSize = 0
                        local fDate = "Unknown"
                        pcall(function()
                            fLastMod = file.lastModified()
                            if fLastMod and fLastMod > 0 then
                                fDate = os.date("%Y-%m-%d", math.floor(fLastMod / 1000))
                            end
                            fSize = file.length()
                        end)

                        local include = true
                        if specificFolder and specificFolder ~= "" then
                            if not path:find(specificFolder, 1, true) then
                                include = false
                            end
                        end

                        if include then
                            table.insert(allFiles, {
                                name = name,
                                path = path,
                                date = fDate,
                                lastModified = fLastMod,
                                size = fSize,
                                type = "video"
                            })
                        end
                    end
                end
            end
            cursor.close()
        end
    end)

    if #allFiles == 0 and (not specificFolder or specificFolder == "") then
        pcall(function()
            local rootDir = Environment.getExternalStorageDirectory()
            collectFiles(rootDir, allFiles, "video", true)
        end)
    end

    if selectedSort == 0 or selectedSort == 6 then
        table.sort(allFiles, function(a, b) return a.lastModified > b.lastModified end)
    elseif selectedSort == 1 then
        table.sort(allFiles, function(a, b) return a.lastModified < b.lastModified end)
    elseif selectedSort == 2 then
        table.sort(allFiles, function(a, b) return a.size > b.size end)
    elseif selectedSort == 3 or selectedSort == 5 then
        table.sort(allFiles, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    elseif selectedSort == 4 then
        table.sort(allFiles, function(a, b) return tostring(a.name):lower() > tostring(b.name):lower() end)
    end

    local displayNames = {}

    if #allFiles == 0 then
        table.insert(displayNames, "No video files found")
    else
        for _, item in ipairs(allFiles) do
            local displayName = item.name
            
            if selectedSort == 6 and item.date ~= "" then
                displayName = item.name .. " (Date: " .. item.date .. ")"
            end

            table.insert(displayNames, displayName)
        end
    end

    if fileCountLabel then
        fileCountLabel.setText("Total Video Files: " .. #allFiles)
    end

    if fileListView then
        fileListView.setAdapter(
            ArrayAdapter(
                ctx,
                android.R.layout.simple_list_item_1,
                displayNames
            )
        )
    end
end

showFoldersDialog = function()
    local folderDlg = LuaDialog(ctx)
    folderDlg.setTitle("Device Folders")

    local currentPath = Environment.getExternalStorageDirectory().getAbsolutePath()
    local folderListView

    local function getFolders(path)
        local folders = {}
        local dir = File(path)

        if not dir.exists() or not dir.isDirectory() then
            return folders
        end

        local files = dir.listFiles()

        if files then
            local fileCount = Array.getLength(files)

            for i = 0, fileCount - 1 do
                local file = files[i]

                if file.isDirectory() and file.canRead() then
                    table.insert(
                        folders,
                        {
                            name = file.getName(),
                            path = file.getAbsolutePath()
                        }
                    )
                end
            end
        end

        table.sort(
            folders,
            function(a, b)
                return tostring(a.name):lower() < tostring(b.name):lower()
            end
        )

        return folders
    end

    local function loadFolders(path)
        currentPath = path
        local folders = getFolders(path)
        local displayNames = {}

        if path ~= Environment.getExternalStorageDirectory().getAbsolutePath() then
            table.insert(displayNames, ".. (Back)")
        end

        for _, folder in ipairs(folders) do
            table.insert(displayNames, "Folder: " .. folder.name)
        end

        if #displayNames == 0 then
            table.insert(displayNames, "No folders found")
        end

        folderListView.setAdapter(
            ArrayAdapter(
                ctx,
                android.R.layout.simple_list_item_1,
                displayNames
            )
        )

        folderDlg.setTitle("Folders: " .. File(path).getName())
    end

    local folderLayout = {
        LinearLayout,
        orientation = "vertical",
        padding = "10dp",

        {
            TextView,
            id = "folderPathLabel",
            text = currentPath,
            textSize = "12sp",
            layout_width = "match_parent",
            layout_marginBottom = "8dp"
        },

        {
            ListView,
            id = "folderListView",
            layout_width = "match_parent",
            layout_height = "300dp",
            layout_marginBottom = "8dp"
        },

        {
            Button,
            text = "Close",
            layout_width = "match_parent",

            onClick = function()
                folderDlg.dismiss()
            end
        }
    }

    local folderIds = {}
    folderDlg.setView(loadlayout(folderLayout, folderIds))

    folderListView = folderIds.folderListView
    local folderPathLabel = folderIds.folderPathLabel

    folderListView.onItemClick = function(parent, view, position, id)
        local selectedName = parent.getItemAtPosition(position)

        if selectedName == "No folders found" then
            return
        end

        if selectedName == ".. (Back)" then
            local parentDir = File(currentPath).getParent()

            if parentDir then
                currentPath = parentDir
                folderPathLabel.setText(currentPath)
                loadFolders(currentPath)
            end

            return
        end

        local folderName = tostring(selectedName)
        folderName = folderName:gsub("^Folder: ", "")

        local folders = getFolders(currentPath)

        for _, folder in ipairs(folders) do
            if folder.name == folderName then
                folderDlg.dismiss()
                if currentMediaType == "video" then
                    loadAndSortVideoFiles(folder.path)
                else
                    loadAndSortAudioFiles(folder.path)
                end
                break
            end
        end
    end

    folderListView.onItemLongClick = function(parent, view, position, id)
        local selectedName = parent.getItemAtPosition(position)

        if selectedName == "No folders found" or selectedName == ".. (Back)" then
            return true
        end

        local folderName = tostring(selectedName)
        folderName = folderName:gsub("^Folder: ", "")

        local folders = getFolders(currentPath)

        for _, folder in ipairs(folders) do
            if folder.name == folderName then
                currentPath = folder.path
                folderPathLabel.setText(currentPath)
                loadFolders(currentPath)
                break
            end
        end

        return true
    end

    folderDlg.show()
    loadFolders(currentPath)
end

updateAudioProgress = function()
    pcall(function()
        if mediaPlayer and mediaPlayer.isPlaying() then
            local currentPos = mediaPlayer.getCurrentPosition()
            if audioSeekBar then
                audioSeekBar.setProgress(currentPos)
            end
        end
    end)
    pcall(function()
        audioHandler.postDelayed(updateAudioProgress, 1000)
    end)
end

playAudioByIndex = function(index, startPosition)
    if index < 1 or index > #allFiles then
        return
    end

    local item = allFiles[index]

    if not item
    or item.type == "video"
    or item.name == "No audio files found"
    or item.name == "No matching files" then
        return
    end

    if mediaPlayer then
        pcall(function()
            mediaPlayer.stop()
        end)
        pcall(function()
            mediaPlayer.release()
        end)
        mediaPlayer = nil
    end

    pcall(function()
        audioHandler.removeCallbacks(updateAudioProgress)
    end)

    currentIndex = index
    currentPlayingFile = item.path
    currentMediaType = "audio"
    pausedPosition = startPosition or 0

    saveCurrentState()

    if currentPlayingFile then
        mediaPlayer = MediaPlayer()
        mediaPlayer.setDataSource(currentPlayingFile)
        mediaPlayer.prepareAsync()

        mediaPlayer.setOnPreparedListener(
            MediaPlayer.OnPreparedListener {
                onPrepared = function(mp)
                    applyPlaybackSpeedAndPitch(mp)
                    applyAudioEffects(mp)

                    local duration = mp.getDuration()
                    if audioSeekBar then
                        audioSeekBar.setMax(duration)
                        audioSeekBar.setProgress(pausedPosition)
                    end

                    if pausedPosition > 0 then
                        mp.seekTo(pausedPosition)
                    end

                    mp.start()
                    updateGlobalState()

                    if btnPlayPause then
                        btnPlayPause.setText("Pause")
                    end

                    pcall(function()
                        audioHandler.removeCallbacks(updateAudioProgress)
                        audioHandler.post(updateAudioProgress)
                    end)
                end
            }
        )

        mediaPlayer.setOnCompletionListener(
            MediaPlayer.OnCompletionListener {
                onCompletion = function(mp)
                    if prefs and currentPlayingFile then
                        prefs.edit()
                            .remove("pos_" .. currentPlayingFile)
                            .commit()

                        saveToHistory(currentPlayingFile)
                    end

                    pausedPosition = 0
                    pcall(function()
                        audioHandler.removeCallbacks(updateAudioProgress)
                    end)

                    if isLoopEnabled then
                        playAudioByIndex(currentIndex, 0)
                    elseif isShuffleEnabled and #allFiles > 1 then
                        math.randomseed(os.time())
                        local nextIdx = math.random(1, #allFiles)

                        if nextIdx == currentIndex then
                            nextIdx = (currentIndex % #allFiles) + 1
                            if nextIdx > #allFiles then
                                nextIdx = 1
                            end
                        end

                        playAudioByIndex(nextIdx, 0)
                    else
                        if currentIndex < #allFiles then
                            playAudioByIndex(currentIndex + 1, 0)
                        elseif #allFiles > 0 then
                            playAudioByIndex(1, 0)
                        end
                    end

                    updateGlobalState()
                    saveCurrentState()
                end
            }
        )
    end
end

togglePlayAudio = function()
    if not currentPlayingFile then
        if #allFiles > 0 then
            playAudioByIndex(1, 0)
        end
        return
    end

    if mediaPlayer == nil then
        local targetIdx = currentIndex > 0 and currentIndex or 1

        for i, item in ipairs(allFiles) do
            if item.path == currentPlayingFile then
                targetIdx = i
                break
            end
        end

        playAudioByIndex(targetIdx, pausedPosition)
    else
        local isPlaying = false
        pcall(function()
            isPlaying = mediaPlayer.isPlaying()
        end)

        if isPlaying then
            pcall(function()
                pausedPosition = mediaPlayer.getCurrentPosition()
                mediaPlayer.pause()
            end)

            if btnPlayPause then
                btnPlayPause.setText("Play")
            end

            pcall(function()
                audioHandler.removeCallbacks(updateAudioProgress)
            end)

            updateGlobalState()
            saveCurrentState()
        else
            pcall(function()
                applyPlaybackSpeedAndPitch(mediaPlayer)
                applyAudioEffects(mediaPlayer)
                mediaPlayer.seekTo(pausedPosition)
                mediaPlayer.start()
            end)

            if btnPlayPause then
                btnPlayPause.setText("Pause")
            end

            pcall(function()
                audioHandler.removeCallbacks(updateAudioProgress)
                audioHandler.post(updateAudioProgress)
            end)

            updateGlobalState()
            saveCurrentState()
        end
    end
end

showRecentlyPlayedDialog = function()
    if not prefs then
        return
    end

    local historyStr = prefs.getString("history_paths", "")
    local histPaths = {}

    for p in historyStr:gmatch("[^|]+") do
        table.insert(histPaths, p)
    end

    if #histPaths == 0 then
        Toast.makeText(ctx, "No recently played media found", Toast.LENGTH_SHORT).show()
        return
    end

    local histDlg = LuaDialog(ctx)
    histDlg.setTitle("Recently Played Media")

    local histItems = {}
    local histDisplayNames = {}

    for _, path in ipairs(histPaths) do
        local f = File(path)

        if f.exists() then
            local name = f.getName()
            local isVid = path:lower():match("%.mp4$") or path:lower():match("%.mkv$") or path:lower():match("%.3gp$") or path:lower():match("%.avi$") or path:lower():match("%.mov$") or path:lower():match("%.webm$") or path:lower():match("%.m4v$")
            local displayName = isVid and (name .. " (Video)") or name

            table.insert(histItems, {name = name, path = path, isVideo = isVid})
            table.insert(histDisplayNames, displayName)
        end
    end

    if #histDisplayNames == 0 then
        table.insert(histDisplayNames, "No history files found")
    end

    local histLayout = {
        LinearLayout,
        orientation = "vertical",
        padding = "10dp",

        {
            ListView,
            id = "histListView",
            layout_width = "match_parent",
            layout_height = "250dp",
            layout_marginBottom = "10dp"
        },

        {
            Button,
            text = "Close",
            layout_width = "match_parent",

            onClick = function()
                histDlg.dismiss()
            end
        }
    }

    local histIds = {}
    histDlg.setView(loadlayout(histLayout, histIds))

    local histListView = histIds.histListView
    histListView.setAdapter(
        ArrayAdapter(
            ctx,
            android.R.layout.simple_list_item_1,
            histDisplayNames
        )
    )

    histListView.onItemClick = function(parent, view, position, id)
        local selectedName = parent.getItemAtPosition(position)

        if selectedName == "No history files found" then
            return
        end

        for _, item in ipairs(histItems) do
            local displayName = item.isVideo and (item.name .. " (Video)") or item.name
            if displayName == selectedName then
                local f = File(item.path)
                if f.exists() then
                    if item.isVideo then
                        histDlg.dismiss()
                        playVideoByIndex(f.getAbsolutePath(), 0)
                    else
                        for i, mainItem in ipairs(allFiles) do
                            if mainItem.path == item.path then
                                histDlg.dismiss()
                                playAudioByIndex(i, 0)
                                break
                            end
                        end
                    end
                end
                break
            end
        end
    end

    histDlg.show()
end

showIncompleteDialog = function()
    if not prefs then
        return
    end

    local incItems = {}
    local incDisplayNames = {}

    for _, mainItem in ipairs(allFiles) do
        local savedPos = prefs.getInt("pos_" .. mainItem.path, 0)

        if savedPos > 0 then
            local f = File(mainItem.path)

            if f.exists() then
                local labelText = mainItem.name
                if mainItem.type == "audio" then
                    local minSec = math.floor(savedPos / 1000)
                    labelText = mainItem.name .. " (" .. minSec .. "s)"
                else
                    local minSec = math.floor(savedPos / 1000)
                    labelText = mainItem.name .. " (Video - " .. minSec .. "s)"
                end

                table.insert(
                    incItems,
                    {
                        name = mainItem.name,
                        path = mainItem.path,
                        pos = savedPos,
                        type = mainItem.type
                    }
                )

                table.insert(incDisplayNames, labelText)
            else
                prefs.edit().remove("pos_" .. mainItem.path).commit()
            end
        end
    end

    if #incDisplayNames == 0 then
        Toast.makeText(ctx, "No current playing media found", Toast.LENGTH_SHORT).show()
        return
    end

    local incDlg = LuaDialog(ctx)
    incDlg.setTitle("Current Playing (Incomplete)")

    local incLayout = {
        LinearLayout,
        orientation = "vertical",
        padding = "10dp",

        {
            ListView,
            id = "incListView",
            layout_width = "match_parent",
            layout_height = "250dp",
            layout_marginBottom = "10dp"
        },

        {
            Button,
            text = "Close",
            layout_width = "match_parent",

            onClick = function()
                incDlg.dismiss()
            end
        }
    }

    local incIds = {}
    incDlg.setView(loadlayout(incLayout, incIds))

    local incListView = incIds.incListView
    incListView.setAdapter(
        ArrayAdapter(
            ctx,
            android.R.layout.simple_list_item_1,
            incDisplayNames
        )
    )

    incListView.onItemClick = function(parent, view, position, id)
        local itemData = incItems[position + 1]

        if itemData then
            if itemData.type == "video" then
                incDlg.dismiss()
                playVideoByIndex(itemData.path, itemData.pos)
            else
                for i, mainItem in ipairs(allFiles) do
                    if mainItem.path == itemData.path then
                        incDlg.dismiss()
                        playAudioByIndex(i, itemData.pos)
                        break
                    end
                end
            end
        end
    end

    incDlg.show()
end

showMoreOptionsMenu = function()
    if currentIndex < 1 or currentIndex > #allFiles then
        return
    end

    local currentItem = allFiles[currentIndex]

    if not currentItem
    or currentItem.name == "No audio files found"
    or currentItem.name == "No video files found"
    or currentItem.name == "No matching files"
    or currentItem.name == "No matching videos" then
        return
    end

    local optDlg = LuaDialog(ctx)
    optDlg.setTitle("Options: " .. tostring(currentItem.name))

    local optLayout = {
        LinearLayout,
        orientation = "vertical",
        padding = "15dp",

        {
            Button,
            text = (currentItem.type == "video") and "Play Video" or "Play Audio",
            layout_width = "match_parent",
            layout_marginBottom = "8dp",

            onClick = function()
                optDlg.dismiss()
                if currentItem.type == "video" then
                    local videoFile = File(currentItem.path)
                    if videoFile.exists() then
                        playVideoByIndex(currentIndex, 0)
                    end
                else
                    togglePlayAudio()
                end
            end
        },

        {
            Button,
            text = "File Info",
            layout_width = "match_parent",
            layout_marginBottom = "8dp",

            onClick = function()
                optDlg.dismiss()
                local infoDlg = LuaDialog(ctx)
                infoDlg.setTitle("File Information")

                local file = File(currentItem.path)
                local fileSize = file.length()
                local sizeMB = string.format("%.2f MB", fileSize / (1024 * 1024))
                
                local lastMod = file.lastModified()
                local dateStr = "Unknown"
                if lastMod and lastMod > 0 then
                    dateStr = os.date("%Y-%m-%d %H:%M:%S", math.floor(lastMod / 1000))
                end

                local durationStr = "Unknown"
                if currentItem.type == "audio" then
                    pcall(function()
                        if mediaPlayer and currentPlayingFile == currentItem.path then
                            local dur = mediaPlayer.getDuration()
                            if dur > 0 then
                                local secs = math.floor(dur / 1000)
                                local mins = math.floor(secs / 60)
                                secs = secs % 60
                                durationStr = string.format("%d:%02d minutes", mins, secs)
                            end
                        end
                    end)
                    if durationStr == "Unknown" then
                        pcall(function()
                            local tempMp = MediaPlayer()
                            tempMp.setDataSource(currentItem.path)
                            tempMp.prepare()
                            local dur = tempMp.getDuration()
                            tempMp.release()
                            if dur > 0 then
                                local secs = math.floor(dur / 1000)
                                local mins = math.floor(secs / 60)
                                secs = secs % 60
                                durationStr = string.format("%d:%02d minutes", mins, secs)
                            end
                        end)
                    end
                elseif currentItem.type == "video" then
                    pcall(function()
                        local tempMv = android.media.MediaMetadataRetriever()
                        tempMv.setDataSource(currentItem.path)
                        local timeString = tempMv.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                        tempMv.release()
                        if timeString then
                            local dur = tonumber(timeString)
                            if dur and dur > 0 then
                                local secs = math.floor(dur / 1000)
                                local mins = math.floor(secs / 60)
                                secs = secs % 60
                                durationStr = string.format("%d:%02d minutes", mins, secs)
                            end
                        end
                    end)
                end

                local infoText = "File Name:\n" .. tostring(currentItem.name) .. "\n\n" ..
                                 "File Path:\n" .. tostring(currentItem.path) .. "\n\n" ..
                                 "File Size:\n" .. sizeMB .. "\n\n" ..
                                 "Duration:\n" .. durationStr .. "\n\n" ..
                                 "Download / Modified Date:\n" .. dateStr .. "\n\n" ..
                                 "File Type:\n" .. string.upper(currentItem.type)

                local infoLayout = {
                    LinearLayout,
                    orientation = "vertical",
                    padding = "15dp",

                    {
                        ScrollView,
                        layout_width = "match_parent",
                        layout_height = "250dp",

                        {
                            TextView,
                            text = infoText,
                            textSize = "14sp"
                        }
                    },

                    {
                        Button,
                        text = "Close",
                        layout_width = "match_parent",
                        layout_marginTop = "10dp",

                        onClick = function()
                            infoDlg.dismiss()
                        end
                    }
                }

                local dummyIds = {}
                infoDlg.setView(loadlayout(infoLayout, dummyIds))
                infoDlg.show()
            end
        },

        {
            Button,
            text = "Rename File",
            layout_width = "match_parent",
            layout_marginBottom = "8dp",

            onClick = function()
                optDlg.dismiss()
                local renameDlg = LuaDialog(ctx)
                renameDlg.setTitle("Rename File")

                local renameIds = {}
                local renameLayout = {
                    LinearLayout,
                    orientation = "vertical",
                    padding = "15dp",

                    {
                        TextView,
                        text = "Enter new file name:",
                        textSize = "14sp",
                        layout_marginBottom = "8dp"
                    },

                    {
                        EditText,
                        id = "renameInputBox",
                        layout_width = "match_parent",
                        layout_marginBottom = "10dp"
                    },

                    {
                        Button,
                        text = "Save",
                        layout_width = "match_parent",

                        onClick = function()
                            local renameInputBox = renameIds.renameInputBox
                            local newName = tostring(renameInputBox.getText())

                            if newName ~= "" and newName ~= currentItem.name then
                                local oldFile = File(currentItem.path)
                                local parentDir = oldFile.getParent()
                                local newFile = File(parentDir, newName)

                                if oldFile.renameTo(newFile) then
                                    local newPath = newFile.getAbsolutePath()

                                    pcall(function()
                                        MediaScannerConnection.scanFile(
                                            ctx,
                                            {oldFile.getAbsolutePath(), newPath},
                                            nil,
                                            nil
                                        )
                                    end)

                                    currentItem.name = newName
                                    currentItem.path = newPath

                                    if currentPlayingFile and currentPlayingFile == oldFile.getAbsolutePath() then
                                        currentPlayingFile = newPath
                                    end

                                    if currentItem.type == "video" then
                                        loadAndSortVideoFiles(currentFolder)
                                    else
                                        loadAndSortAudioFiles(currentFolder)
                                    end
                                    saveCurrentState()
                                    updateGlobalState()
                                end
                            end

                            renameDlg.dismiss()
                        end
                    }
                }

                renameDlg.setView(loadlayout(renameLayout, renameIds))
                if renameIds.renameInputBox then
                    renameIds.renameInputBox.setText(tostring(currentItem.name))
                end

                renameDlg.show()
            end
        },

        {
            Button,
            text = "Delete File",
            layout_width = "match_parent",
            layout_marginBottom = "8dp",

            onClick = function()
                optDlg.dismiss()
                local delDlg = LuaDialog(ctx)
                delDlg.setTitle("Confirm Delete")

                local delLayout = {
                    LinearLayout,
                    orientation = "vertical",
                    padding = "15dp",

                    {
                        TextView,
                        text = "Do you want to delete this file?\n" .. tostring(currentItem.name),
                        textSize = "14sp",
                        layout_marginBottom = "15dp"
                    },

                    {
                        LinearLayout,
                        orientation = "horizontal",
                        layout_width = "match_parent",

                        {
                            Button,
                            text = "Yes",
                            layout_weight = 1,
                            layout_marginRight = "5dp",

                            onClick = function()
                                delDlg.dismiss()
                                local file = File(currentItem.path)

                                if file.exists() then
                                    file.delete()

                                    if currentItem.type == "audio" then
                                        if mediaPlayer then
                                            pcall(function()
                                                mediaPlayer.stop()
                                            end)
                                            pcall(function()
                                                mediaPlayer.release()
                                            end)
                                            mediaPlayer = nil
                                        end

                                        currentPlayingFile = nil
                                        currentIndex = -1
                                        pausedPosition = 0
                                        updateGlobalState()
                                        saveCurrentState()
                                        loadAndSortAudioFiles(currentFolder)
                                    else
                                        if videoDlg then
                                            pcall(function()
                                                if videoIds.myVideoView then
                                                    videoIds.myVideoView.stopPlayback()
                                                end
                                            end)
                                            pcall(function()
                                                videoHandler.removeCallbacks(updateVideoProgress)
                                            end)
                                            videoDlg.dismiss()
                                            videoDlg = nil
                                        end
                                        loadAndSortVideoFiles(currentFolder)
                                    end
                                end
                            end
                        },

                        {
                            Button,
                            text = "No",
                            layout_weight = 1,
                            layout_marginLeft = "5dp",

                            onClick = function()
                                delDlg.dismiss()
                            end
                        }
                    }
                }

                local dummyIds = {}
                delDlg.setView(loadlayout(delLayout, dummyIds))
                delDlg.show()
            end
        },

        {
            Button,
            text = "Share File",
            layout_width = "match_parent",
            layout_marginBottom = "8dp",

            onClick = function()
                optDlg.dismiss()
                local file = File(currentItem.path)

                if not file.exists() then
                    Toast.makeText(ctx, "File not found for sharing!", Toast.LENGTH_SHORT).show()
                    return
                end

                local filePath = file.getAbsolutePath()
                local mimeType = (currentItem.type == "video") and "video/*" or "audio/*"

                MediaScannerConnection.scanFile(
                    ctx,
                    {filePath},
                    {mimeType},
                    function(path, uri)
                        if uri then
                            local shareIntent = Intent(Intent.ACTION_SEND)
                            shareIntent.setType(mimeType)
                            shareIntent.putExtra(Intent.EXTRA_STREAM, uri)
                            shareIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

                            local chooser = Intent.createChooser(shareIntent, "Share File")
                            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

                            pcall(function()
                                dlg.dismiss()
                            end)

                            task(
                                200,
                                function()
                                    pcall(function()
                                        ctx.startActivity(chooser)
                                    end)
                                end
                            )
                        else
                            Toast.makeText(ctx, "Unable to prepare file for sharing!", Toast.LENGTH_SHORT).show()
                        end
                    end
                )
            end
        },

        {
            Button,
            text = "Cancel",
            layout_width = "match_parent",

            onClick = function()
                optDlg.dismiss()
            end
        }
    }

    local dummyIds = {}
    optDlg.setView(loadlayout(optLayout, dummyIds))
    optDlg.show()
end

local layout = {
    LinearLayout,
    orientation = "vertical",
    layout_width = "match_parent",
    layout_height = "match_parent",
    padding = "8dp",

    {
        TextView,
        text = "Media Player Pro\nDeveloper: Prince Nabeel",
        textSize = "16sp",
        textColor = "0xFF0000FF",
        layout_marginBottom = "2dp"
    },

    {
        TextView,
        id = "fileCountLabel",
        text = "Total Files: 0",
        textSize = "11sp",
        layout_marginBottom = "2dp"
    },

    {
        EditText,
        id = "searchBox",
        hint = "Search audio...",
        layout_width = "match_parent",
        layout_marginBottom = "2dp"
    },

    {
        Spinner,
        id = "sortSpinner",
        layout_width = "match_parent",
        layout_marginBottom = "2dp"
    },

    {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "match_parent",
        layout_marginBottom = "4dp",

        {
            Button,
            id = "btnRecentlyPlayed",
            text = "Recently Played",
            layout_weight = 1,
            layout_marginRight = "4dp",

            onClick = function()
                showRecentlyPlayedDialog()
            end
        },

        {
            Button,
            id = "btnIncompletePlaying",
            text = "Current Playing",
            layout_weight = 1,

            onClick = function()
                showIncompleteDialog()
            end
        }
    },

    {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "match_parent",
        layout_marginBottom = "4dp",

        {
            Button,
            text = "Folders",
            layout_weight = 1,
            layout_marginRight = "4dp",

            onClick = function()
                showFoldersDialog()
            end
        },

        {
            Button,
            text = "All Audios",
            layout_weight = 1,
            layout_marginRight = "4dp",

            onClick = function()
                currentFolder = ""
                loadAndSortAudioFiles()
            end
        },

        {
            Button,
            text = "All Videos",
            layout_weight = 1,

            onClick = function()
                currentFolder = ""
                loadAndSortVideoFiles()
            end
        }
    },

    {
        ListView,
        id = "fileListView",
        layout_width = "match_parent",
        layout_height = "120dp",
        layout_marginBottom = "6dp"
    },

    {
        LinearLayout,
        orientation = "vertical",
        layout_width = "match_parent",
        layout_height = "wrap_content",

        {
            LinearLayout,
            orientation = "horizontal",
            layout_width = "match_parent",
            layout_marginBottom = "4dp",

            {
                Button,
                text = "Prev",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    if currentMediaType ~= "audio" then
                        return
                    end

                    if currentIndex > 1 then
                        playAudioByIndex(currentIndex - 1, 0)
                    elseif #allFiles > 0 then
                        playAudioByIndex(#allFiles, 0)
                    end
                end
            },

            {
                Button,
                text = "Play",
                id = "btnPlayPause",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    if currentMediaType == "audio" then
                        togglePlayAudio()
                    end
                end
            },

            {
                Button,
                text = "More",
                layout_weight = 1,

                onClick = function()
                    if currentMediaType == "audio" then
                        showMoreOptionsMenu()
                    end
                end
            }
        },

        {
            LinearLayout,
            orientation = "horizontal",
            layout_width = "match_parent",
            layout_marginBottom = "4dp",
            gravity = "center_vertical",

            {
                Button,
                id = "btnRewind",
                text = "-10s",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    if currentMediaType ~= "audio" then
                        return
                    end

                    if mediaPlayer then
                        local currentPos = 0
                        pcall(function()
                            currentPos = mediaPlayer.getCurrentPosition()
                        end)
                        local newPos = currentPos - (skipSeconds * 1000)

                        if newPos < 0 then
                            newPos = 0
                        end

                        pcall(function()
                            mediaPlayer.seekTo(newPos)
                        end)
                        pausedPosition = newPos
                        updateGlobalState()
                        saveCurrentState()
                    end
                end
            },

            {
                Button,
                id = "btnForward",
                text = "+10s",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    if currentMediaType ~= "audio" then
                        return
                    end

                    if mediaPlayer then
                        local currentPos = 0
                        local duration = 0
                        pcall(function()
                            currentPos = mediaPlayer.getCurrentPosition()
                            duration = mediaPlayer.getDuration()
                        end)
                        local newPos = currentPos + (skipSeconds * 1000)

                        if newPos > duration then
                            newPos = duration
                        end

                        pcall(function()
                            mediaPlayer.seekTo(newPos)
                        end)
                        pausedPosition = newPos
                        updateGlobalState()
                        saveCurrentState()
                    end
                end
            },

            {
                Button,
                text = "Next",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    if currentMediaType ~= "audio" then
                        return
                    end

                    if currentIndex > 0 and currentIndex < #allFiles then
                        playAudioByIndex(currentIndex + 1, 0)
                    elseif #allFiles > 0 then
                        playAudioByIndex(1, 0)
                    end
                end
            },

            {
                SeekBar,
                id = "audioSeekBar",
                layout_width = "match_parent",
                layout_height = "wrap_content",
                layout_weight = 1
            }
        },

        {
            LinearLayout,
            orientation = "horizontal",
            layout_width = "match_parent",
            layout_marginBottom = "4dp",

            {
                Button,
                text = "Refresh",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    if currentMediaType == "video" then
                        loadAndSortVideoFiles(currentFolder)
                    else
                        loadAndSortAudioFiles(currentFolder)
                    end
                end
            },

            {
                Button,
                id = "btnSettings",
                text = "Settings",
                layout_weight = 1,
                layout_marginRight = "4dp",

                onClick = function()
                    local setDlg = LuaDialog(ctx)
                    setDlg.setTitle("Settings")

                    local jumpTimeSpinner
                    local speedSpinner
                    local pitchSpinner
                    local bassSpinner
                    local chkLoop
                    local chkShuffle
                    local chkBackgroundPlay

                    local setLayout = {
                        LinearLayout,
                        orientation = "vertical",
                        padding = "15dp",

                        {
                            TextView,
                            text = "Skip Time:",
                            textSize = "14sp",
                            layout_marginBottom = "5dp"
                        },

                        {
                            Spinner,
                            id = "jumpTimeSpinner",
                            layout_width = "match_parent",
                            layout_marginBottom = "10dp"
                        },

                        {
                            TextView,
                            text = "Playback Speed:",
                            textSize = "14sp",
                            layout_marginBottom = "5dp"
                        },

                        {
                            Spinner,
                            id = "speedSpinner",
                            layout_width = "match_parent",
                            layout_marginBottom = "10dp"
                        },

                        {
                            TextView,
                            text = "Audio Pitch:",
                            textSize = "14sp",
                            layout_marginBottom = "5dp"
                        },

                        {
                            Spinner,
                            id = "pitchSpinner",
                            layout_width = "match_parent",
                            layout_marginBottom = "10dp"
                        },

                        {
                            TextView,
                            text = "Bass & Sound Effect:",
                            textSize = "14sp",
                            layout_marginBottom = "5dp"
                        },

                        {
                            Spinner,
                            id = "bassSpinner",
                            layout_width = "match_parent",
                            layout_marginBottom = "10dp"
                        },

                        {
                            CheckBox,
                            id = "chkLoop",
                            text = "Loop Audio (Repeat)",
                            layout_width = "match_parent",
                            layout_marginBottom = "8dp"
                        },

                        {
                            CheckBox,
                            id = "chkShuffle",
                            text = "Shuffle Audio",
                            layout_width = "match_parent",
                            layout_marginBottom = "8dp"
                        },

                        {
                            CheckBox,
                            id = "chkBackgroundPlay",
                            text = "Background Play (Keep Playing on Close)",
                            layout_width = "match_parent",
                            layout_marginBottom = "10dp"
                        },

                        {
                            Button,
                            text = "About Extension",
                            layout_width = "match_parent",
                            layout_marginBottom = "10dp",

                            onClick = function()
                                local aboutDlg = LuaDialog(ctx)
                                aboutDlg.setTitle("About Media Player Pro")

                                local aboutLayout = {
                                    LinearLayout,
                                    orientation = "vertical",
                                    padding = "15dp",

                                    {
                                        TextView,
                                        text = "Media Player Pro is a powerful and feature-rich media player extension designed for Android. It allows you to manage, play, and organize all your device audio and video files effortlessly with complete folder support, search functionality, variable playback speed, and robust file management tools.\n\nDeveloper: Prince Nabeel",
                                        textSize = "14sp",
                                        layout_marginBottom = "10dp"
                                    },

                                    {
                                        TextView,
                                        text = "Key Features:\n* Comprehensive Audio & Video Loading via MediaStore\n* Full Folder Navigation & Specific Folder Filtering\n* Advanced Audio Controls (Skip, Speed, Pitch, Bass, Loop, Shuffle)\n* Recently Played & Incomplete Track History\n* Built-in File Renaming, Deleting, and Sharing Options",
                                        textSize = "13sp",
                                        layout_marginBottom = "15dp"
                                    },

                                    {
                                        Button,
                                        text = "Feedback on WhatsApp",
                                        layout_width = "match_parent",
                                        layout_marginBottom = "8dp",

                                        onClick = function()
                                            pcall(function()
                                                local intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/923234375740"))
                                                ctx.startActivity(intent)
                                            end)
                                        end
                                    },

                                    {
                                        Button,
                                        text = "Close",
                                        layout_width = "match_parent",

                                        onClick = function()
                                            aboutDlg.dismiss()
                                        end
                                    }
                                }

                                local aboutIds = {}
                                aboutDlg.setView(loadlayout(aboutLayout, aboutIds))
                                aboutDlg.show()
                            end
                        },

                        {
                            Button,
                            text = "Save & Close",
                            layout_width = "match_parent",

                            onClick = function()
                                local selectedJumpPos = jumpTimeSpinner.getSelectedItemPosition()

                                if selectedJumpPos == 0 then
                                    skipSeconds = 10
                                elseif selectedJumpPos == 1 then
                                    skipSeconds = 20
                                elseif selectedJumpPos == 2 then
                                    skipSeconds = 30
                                elseif selectedJumpPos == 3 then
                                    skipSeconds = 60
                                end

                                local selectedSpeedPos = speedSpinner.getSelectedItemPosition()

                                if selectedSpeedPos == 0 then
                                    playbackSpeed = 0.5
                                elseif selectedSpeedPos == 1 then
                                    playbackSpeed = 0.8
                                elseif selectedSpeedPos == 2 then
                                    playbackSpeed = 1.0
                                elseif selectedSpeedPos == 3 then
                                    playbackSpeed = 1.25
                                elseif selectedSpeedPos == 4 then
                                    playbackSpeed = 1.5
                                elseif selectedSpeedPos == 5 then
                                    playbackSpeed = 2.0
                                end

                                local selectedPitchPos = pitchSpinner.getSelectedItemPosition()

                                if selectedPitchPos == 0 then
                                    playbackPitch = 0.5
                                elseif selectedPitchPos == 1 then
                                    playbackPitch = 0.8
                                elseif selectedPitchPos == 2 then
                                    playbackPitch = 1.0
                                elseif selectedPitchPos == 3 then
                                    playbackPitch = 1.25
                                elseif selectedPitchPos == 4 then
                                    playbackPitch = 1.5
                                elseif selectedPitchPos == 5 then
                                    playbackPitch = 2.0
                                end

                                local selectedBassPos = bassSpinner.getSelectedItemPosition()

                                if selectedBassPos == 0 then
                                    bassBoostLevel = 0
                                    eqPreset = 0
                                elseif selectedBassPos == 1 then
                                    bassBoostLevel = 500
                                    eqPreset = 0
                                elseif selectedBassPos == 2 then
                                    bassBoostLevel = 1000
                                    eqPreset = 0
                                elseif selectedBassPos == 3 then
                                    bassBoostLevel = 300
                                    eqPreset = 1
                                elseif selectedBassPos == 4 then
                                    bassBoostLevel = 300
                                    eqPreset = 2
                                elseif selectedBassPos == 5 then
                                    bassBoostLevel = 300
                                    eqPreset = 3
                                elseif selectedBassPos == 6 then
                                    bassBoostLevel = 200
                                    eqPreset = 4
                                elseif selectedBassPos == 7 then
                                    bassBoostLevel = 800
                                    eqPreset = 5
                                elseif selectedBassPos == 8 then
                                    bassBoostLevel = 1000
                                    eqPreset = 6
                                elseif selectedBassPos == 9 then
                                    bassBoostLevel = 0
                                    eqPreset = 7
                                end

                                if mediaPlayer then
                                    applyPlaybackSpeedAndPitch(mediaPlayer)
                                    applyAudioEffects(mediaPlayer)
                                end

                                btnRewind.setText("-" .. skipSeconds .. "s")
                                btnForward.setText("+" .. skipSeconds .. "s")

                                isLoopEnabled = chkLoop.isChecked()
                                isShuffleEnabled = chkShuffle.isChecked()
                                isBackgroundPlayEnabled = chkBackgroundPlay.isChecked()

                                saveCurrentState()
                                setDlg.dismiss()
                            end
                        }
                    }

                    local setIds = {}
                    setDlg.setView(loadlayout(setLayout, setIds))

                    jumpTimeSpinner = setIds.jumpTimeSpinner
                    speedSpinner = setIds.speedSpinner
                    pitchSpinner = setIds.pitchSpinner
                    bassSpinner = setIds.bassSpinner
                    chkLoop = setIds.chkLoop
                    chkShuffle = setIds.chkShuffle
                    chkBackgroundPlay = setIds.chkBackgroundPlay

                    local jumpTimes = {"10 Sec", "20 Sec", "30 Sec", "1 Min"}
                    jumpTimeSpinner.setAdapter(
                        ArrayAdapter(
                            ctx,
                            android.R.layout.simple_spinner_dropdown_item,
                            jumpTimes
                        )
                    )

                    local speedOptions = {"0.5x", "0.8x", "1.0x (Normal)", "1.25x", "1.5x", "2.0x"}
                    speedSpinner.setAdapter(
                        ArrayAdapter(
                            ctx,
                            android.R.layout.simple_spinner_dropdown_item,
                            speedOptions
                        )
                    )

                    pitchSpinner.setAdapter(
                        ArrayAdapter(
                            ctx,
                            android.R.layout.simple_spinner_dropdown_item,
                            speedOptions
                        )
                    )

                    local bassOptions = {
                        "Normal (No Effect)", 
                        "Bass Boost (Medium)", 
                        "Bass Boost (High)", 
                        "Rock", 
                        "Pop", 
                        "Jazz", 
                        "Classical", 
                        "Dance / Club", 
                        "Hip Hop / Rap", 
                        "Vocal Clear (Speech)"
                    }
                    bassSpinner.setAdapter(
                        ArrayAdapter(
                            ctx,
                            android.R.layout.simple_spinner_dropdown_item,
                            bassOptions
                        )
                    )

                    if skipSeconds == 10 then
                        jumpTimeSpinner.setSelection(0)
                    elseif skipSeconds == 20 then
                        jumpTimeSpinner.setSelection(1)
                    elseif skipSeconds == 30 then
                        jumpTimeSpinner.setSelection(2)
                    elseif skipSeconds == 60 then
                        jumpTimeSpinner.setSelection(3)
                    end

                    if playbackSpeed == 0.5 then
                        speedSpinner.setSelection(0)
                    elseif playbackSpeed == 0.8 then
                        speedSpinner.setSelection(1)
                    elseif playbackSpeed == 1.0 then
                        speedSpinner.setSelection(2)
                    elseif playbackSpeed == 1.25 then
                        speedSpinner.setSelection(3)
                    elseif playbackSpeed == 1.5 then
                        speedSpinner.setSelection(4)
                    elseif playbackSpeed == 2.0 then
                        speedSpinner.setSelection(5)
                    else
                        speedSpinner.setSelection(2)
                    end

                    if playbackPitch == 0.5 then
                        pitchSpinner.setSelection(0)
                    elseif playbackPitch == 0.8 then
                        pitchSpinner.setSelection(1)
                    elseif playbackPitch == 1.0 then
                        pitchSpinner.setSelection(2)
                    elseif playbackPitch == 1.25 then
                        pitchSpinner.setSelection(3)
                    elseif playbackPitch == 1.5 then
                        pitchSpinner.setSelection(4)
                    elseif playbackPitch == 2.0 then
                        pitchSpinner.setSelection(5)
                    else
                        pitchSpinner.setSelection(2)
                    end

                    if bassBoostLevel == 0 and eqPreset == 0 then
                        bassSpinner.setSelection(0)
                    elseif bassBoostLevel == 500 and eqPreset == 0 then
                        bassSpinner.setSelection(1)
                    elseif bassBoostLevel == 1000 and eqPreset == 0 then
                        bassSpinner.setSelection(2)
                    elseif eqPreset == 1 then
                        bassSpinner.setSelection(3)
                    elseif eqPreset == 2 then
                        bassSpinner.setSelection(4)
                    elseif eqPreset == 3 then
                        bassSpinner.setSelection(5)
                    elseif eqPreset == 4 then
                        bassSpinner.setSelection(6)
                    elseif eqPreset == 5 then
                        bassSpinner.setSelection(7)
                    elseif eqPreset == 6 then
                        bassSpinner.setSelection(8)
                    elseif eqPreset == 7 then
                        bassSpinner.setSelection(9)
                    else
                        bassSpinner.setSelection(0)
                    end

                    chkLoop.setChecked(isLoopEnabled)
                    chkShuffle.setChecked(isShuffleEnabled)
                    chkBackgroundPlay.setChecked(isBackgroundPlayEnabled)

                    setDlg.show()
                end
            },

            {
                Button,
                text = "Close",
                layout_weight = 1,

                onClick = function()
                    saveCurrentState()

                    if mediaPlayer and not isBackgroundPlayEnabled then
                        pcall(function()
                            mediaPlayer.stop()
                        end)
                        pcall(function()
                            mediaPlayer.release()
                        end)
                        mediaPlayer = nil
                        updateGlobalState()
                    end

                    dlg.dismiss()
                end
            }
        }
    }
}

local viewIds = {}
local view = loadlayout(layout, viewIds)
dlg.setView(view)

ctx = view.getContext()
prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

fileListView = viewIds.fileListView
fileCountLabel = viewIds.fileCountLabel
sortSpinner = viewIds.sortSpinner
searchBox = viewIds.searchBox
btnRewind = viewIds.btnRewind
btnForward = viewIds.btnForward
btnPlayPause = viewIds.btnPlayPause
audioSeekBar = viewIds.audioSeekBar
btnRecentlyPlayed = viewIds.btnRecentlyPlayed
btnIncompletePlaying = viewIds.btnIncompletePlaying

if audioSeekBar then
    audioSeekBar.setOnSeekBarChangeListener(
        SeekBar.OnSeekBarChangeListener {
            onProgressChanged = function(seekBar, progress, fromUser)
                if fromUser and mediaPlayer then
                    mediaPlayer.seekTo(progress)
                    pausedPosition = progress
                    updateGlobalState()
                    saveCurrentState()
                end
            end,
            onStartTrackingTouch = function(seekBar) end,
            onStopTrackingTouch = function(seekBar) end
        }
    )
end

pcall(function()
    if mediaPlayer and mediaPlayer.isPlaying() then
        if btnPlayPause then
            btnPlayPause.setText("Pause")
        end
        pcall(function()
            audioHandler.removeCallbacks(updateAudioProgress)
            audioHandler.post(updateAudioProgress)
        end)
    end
end)

local sortOptions = {"Newest", "Oldest", "Largest", "A to Z", "Z to A", "Name", "Date"}
sortSpinner.setAdapter(
    ArrayAdapter(
        ctx,
        android.R.layout.simple_spinner_dropdown_item,
        sortOptions
    )
)

local isSpinnerInitialized = false

sortSpinner.onItemSelectedListener = Spinner.OnItemSelectedListener {
    onItemSelected = function(parent, view, position, id, id2)
        if not isSpinnerInitialized then
            isSpinnerInitialized = true
            return
        end

        if currentMediaType == "audio" then
            loadAndSortAudioFiles(currentFolder)
        elseif currentMediaType == "video" then
            loadAndSortVideoFiles(currentFolder)
        end
    end,

    onNothingSelected = function(parent)
    end
}

task(
    150,
    function()
        loadAndSortAudioFiles()
        loadSavedState()
    end
)

fileListView.onItemClick = function(parent, view, position, id)
    local selectedName = parent.getItemAtPosition(position)

    if selectedName == "No audio files found"
    or selectedName == "No video files found"
    or selectedName == "No matching files"
    or selectedName == "No matching videos" then
        return
    end

    if currentMediaType == "video" then
        local cleanName = tostring(selectedName)
        cleanName = cleanName:gsub(" %(Date: .*%)$", "")
        
        for i, item in ipairs(allFiles) do
            if item.name == cleanName then
                playVideoByIndex(i, 0)
                break
            end
        end
        return
    end

    local cleanName = tostring(selectedName)
    cleanName = cleanName:gsub(" %(Date: .*%)$", "")

    for i, item in ipairs(allFiles) do
        if item.name == cleanName then
            playAudioByIndex(i, 0)
            break
        end
    end
end

if searchBox then
    searchBox.addTextChangedListener(
        TextWatcher {
            onTextChanged = function(s, start, before, count)
                local query = tostring(s):lower()
                local filteredNames = {}

                for _, item in ipairs(allFiles) do
                    if item.name:lower():find(query) then
                        table.insert(filteredNames, item.name)
                    end
                end

                if #filteredNames == 0 then
                    if currentMediaType == "video" then
                        filteredNames = {"No matching videos"}
                    else
                        filteredNames = {"No matching files"}
                    end
                end

                fileListView.setAdapter(
                    ArrayAdapter(
                        ctx,
                        android.R.layout.simple_list_item_1,
                        filteredNames
                    )
                )
            end
        }
    )
end

fileListView.onItemLongClick = function(parent, view, position, id)
    local selectedName = parent.getItemAtPosition(position)

    if selectedName == "No audio files found"
    or selectedName == "No video files found"
    or selectedName == "No matching files"
    or selectedName == "No matching videos" then
        return true
    end

    local cleanName = tostring(selectedName)
    cleanName = cleanName:gsub(" %(Date: .*%)$", "")

    for i, item in ipairs(allFiles) do
        if item.name == cleanName then
            currentIndex = i
            break
        end
    end

    showMoreOptionsMenu()
    return true
end

dlg.show()
