-- Executed by core_modmanager when the mod database initialises (core/modmanager.lua, "execute
-- modScripts"). Registering the extension as "manual" makes loadManualUnloadExtensions() load it
-- right after, and keeps it loaded across level changes.
setExtensionUnloadMode("mccross_bridge", "manual")
