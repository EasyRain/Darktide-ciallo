return {
    mod_name = {
        en = "Ciallo~ Push Sound",
        ["zh-cn"] = "推击音效 Ciallo~",
        ["zh-tw"] = "推擊音效 Ciallo~",
    },
    mod_description = {
        en = "Plays Ciallo~ every time you push (hold block, then press light attack). Rapid pushes overlap: each push starts a new layer instead of cutting the previous one. Plays a local audio file from disk through Windows audio APIs.",
        ["zh-cn"] = "每次推怪（按住右键格挡时点按左键）播放 Ciallo~。快速连推可叠加：每次推击开启新一层音效，不会掐断上一轮。通过 Windows 音频 API 播放本地音频文件。",
        ["zh-tw"] = "每次推怪（按住右鍵格擋時點按左鍵）播放 Ciallo~。快速連推可疊加：每次推擊開啟新一層音效，不會掐斷上一輪。透過 Windows 音訊 API 播放本機音訊檔。",
    },
    sound_path = {
        en = "Sound file path (WAV recommended; MP3 supported)",
        ["zh-cn"] = "音频文件路径（推荐 WAV，支持 MP3）",
        ["zh-tw"] = "音訊檔案路徑（推薦 WAV，支援 MP3）",
    },
    sound_path_description = {
        en = "Full path to the sound file (WAV recommended; MP3 supported). If the file is missing, a .wav/.mp3 variant of the same path is tried automatically.",
        ["zh-cn"] = "音频文件的完整路径（推荐 WAV，支持 MP3）。若文件不存在，会自动尝试同路径的 .wav/.mp3 变体。",
        ["zh-tw"] = "音訊檔的完整路徑（推薦 WAV，支援 MP3）。若檔案不存在，會自動嘗試同路徑的 .wav/.mp3 變體。",
    },
    volume = {
        en = "Volume (MP3 path only)",
        ["zh-cn"] = "音量（仅 MP3 路径生效）",
        ["zh-tw"] = "音量（僅 MP3 路徑生效）",
    },
    volume_description = {
        en = "MCI volume 0-100%. WAV playback uses the system volume.",
        ["zh-cn"] = "MCI 音量 0-100%。WAV 播放跟随系统音量。",
        ["zh-tw"] = "MCI 音量 0-100%。WAV 播放跟隨系統音量。",
    },
    voices = {
        en = "Overlapping layers (WAV)",
        ["zh-cn"] = "叠加层数（WAV）",
        ["zh-tw"] = "疊加層數（WAV）",
    },
    voices_description = {
        en = "How many sounds may play on top of each other. Rapid pushes start a new layer without cutting the previous ones; once all layers are busy, the oldest one is restarted.",
        ["zh-cn"] = "最多同时叠加播放的层数。快速连推会直接叠加新一层，不会掐断上一轮；层数用尽后最早的那层会被重播。",
        ["zh-tw"] = "最多同時疊加播放的層數。快速連推會直接疊加新一層，不會掐斷上一輪；層數用盡後最早的那層會被重播。",
    },
    test_sound = {
        en = "Test sound",
        ["zh-cn"] = "测试播放",
        ["zh-tw"] = "測試播放",
    },
    debug_logging = {
        en = "Debug logging",
        ["zh-cn"] = "调试日志",
        ["zh-tw"] = "除錯紀錄",
    },
}
