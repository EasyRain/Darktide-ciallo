local mod = get_mod("ciallo")

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "sound_path",
                type = "text",
                default_value = "../mods/ciallo/assets/Ciallo~.wav",
                max_length = 512,
            },
            {
                setting_id = "volume",
                type = "numeric",
                default_value = 100,
                range = { 0, 100 },
                decimals_number = 0,
            },
            {
                setting_id = "voices",
                type = "numeric",
                default_value = 4,
                range = { 1, 8 },
                decimals_number = 0,
            },
            {
                setting_id = "test_sound",
                type = "button",
                button_text = "test_sound",
                function_name = "play_test_sound",
            },
            {
                setting_id = "debug_logging",
                type = "checkbox",
                default_value = false,
            },
        },
    },
}
