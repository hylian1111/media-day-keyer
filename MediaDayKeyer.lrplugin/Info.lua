return {
    LrSdkVersion        = 10.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = "com.mackkalish.mediadaykeyer",
    LrPluginName        = "Media Day Keyer",
    LrPluginInfoUrl     = "https://github.com/hylian1111/media-day-keyer",
    LrInitPlugin        = "Init.lua",

    -- File > Plug-in Extras, so it's reachable from any module while tethering
    LrExportMenuItems = {
        { title = "Start Auto-Keying Picks",              file = "StartKeying.lua"        },
        { title = "Start Auto-Keying Picks + PSDs",       file = "StartKeyingPsd.lua"     },
        { title = "Start Auto-Keying Blue Labels",        file = "StartKeyingBlue.lua"    },
        { title = "Start Auto-Keying Blue Labels + PSDs", file = "StartKeyingBluePsd.lua" },
        { title = "Stop Auto-Keying",                     file = "StopKeying.lua"         },
        { title = "Re-key Selected Photos",               file = "RekeySelected.lua"      },
        { title = "Open Cutouts Folder",                  file = "OpenCutouts.lua"        },
        { title = "Show Log and Failed Photos",           file = "ShowLogs.lua"           },
    },

    VERSION = { major = 1, minor = 0, revision = 0 },
}
