return {
    mod_name = {
        en = "Ciallo~ Push Sound",
        ["zh-cn"] = "推击音效 Ciallo~",
        ["zh-tw"] = "推擊音效 Ciallo~",
    },
    mod_description = {
        en = "Plays Ciallo~ every time you push. Plays a local sound through Windows audio APIs: one fixed file, or a random one from a folder.",
        ["zh-cn"] = "每次推怪播放 Ciallo~。通过 Windows 音频 API 播放本地音效：可以是固定的一个文件，也可以从文件夹里随机播放。",
        ["zh-tw"] = "每次推怪播放 Ciallo~。透過 Windows 音訊 API 播放本機音效：可以是固定的一個檔案，也可以從資料夾裡隨機播放。",
    },
    sound_path = {
        en = "Sound file or folder (WAV recommended; MP3 supported)",
        ["zh-cn"] = "音效文件或文件夹（推荐 WAV，支持 MP3）",
        ["zh-tw"] = "音效檔案或資料夾（推薦 WAV，支援 MP3）",
    },
    sound_path_description = {
        en = "A file plays that file every push. A folder plays a random .wav/.mp3 from it, without repeats until every file has been played once (subfolders are not scanned). Leave it empty, or point it at a missing path, to use the sounds shipped with the mod.",
        ["zh-cn"] = "填文件：每次都播它。填文件夹：从里面随机播 .wav/.mp3，一轮之内不重复（不扫描子文件夹）。留空或路径无效时，使用 mod 自带的音效。",
        ["zh-tw"] = "填檔案：每次都播它。填資料夾：從裡面隨機播 .wav/.mp3，一輪之內不重複（不掃描子資料夾）。留空或路徑無效時，使用 mod 自帶的音效。",
    },
    volume = {
        en = "Volume",
        ["zh-cn"] = "音量",
        ["zh-tw"] = "音量",
    },
    volume_description = {
        en = "Volume of this mod's sound, 0-100%. Applies to both backends (WAV and MP3) and takes effect on the next sound. Only this mod's playback is scaled: the game's music and sound effects, and the Windows volume, are not affected.",
        ["zh-cn"] = "本 mod 音效的音量，0-100%。WAV 与 MP3 两条路径都生效，改动在下一次播放时生效。只缩放本 mod 播放的声音，不会影响游戏音乐、游戏音效或系统音量。",
        ["zh-tw"] = "本 mod 音效的音量，0-100%。WAV 與 MP3 兩條路徑都生效，改動於下一次播放時生效。只縮放本 mod 播放的聲音，不會影響遊戲音樂、遊戲音效或系統音量。",
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
