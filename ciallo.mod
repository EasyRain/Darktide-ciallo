-- ciallo.mod
-- Plays "Ciallo~" when your push actually goes out (hold block + light attack).
return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`ciallo` needs Darktide Mod Framework.")
        new_mod("ciallo", {
            mod_script       = "ciallo/scripts/mods/ciallo/ciallo",
            mod_data         = "ciallo/scripts/mods/ciallo/ciallo_data",
            mod_localization = "ciallo/scripts/mods/ciallo/ciallo_localization",
        })
    end,
    packages = {},
    version = "1.1.0",
}
