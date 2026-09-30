--[[
  Media Day Keyer — Lightroom side.

  While Auto-Keying is on, two background loops run:
    watch   — every 2s, finds photos newly flagged as picks (P) — or newly given the blue label,
              depending on which Start command was used — and exports each one (full res, 8-bit
              sRGB TIFF, develop settings baked in) to <work>/inbox, then writes <file>.json next
              to it saying where the cut-outs go.
    process — runs the bundled engine (bin/mdkeyer) once per finished export: Photoshop Select
              Subject, split per person, PNGs (plus a layered PSD in "+ PSDs" mode) into
              "<catalog folder>/Media Day Cutouts".

  <work> is ~/Library/Application Support/Media Day Keyer. Which photos have already been sent
  is remembered per catalog in <work>/state, so a photo is keyed once. Use Re-key Selected
  Photos after changing an edit.
]]

local LrApplication     = import "LrApplication"
local LrDialogs         = import "LrDialogs"
local LrExportSession   = import "LrExportSession"
local LrFileUtils       = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils       = import "LrPathUtils"
local LrPrefs           = import "LrPrefs"
local LrProgressScope   = import "LrProgressScope"
local LrShell           = import "LrShell"
local LrTasks           = import "LrTasks"

local WORK    = LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), "Library/Application Support/Media Day Keyer")
local INBOX   = LrPathUtils.child(WORK, "inbox")
local STATE   = LrPathUtils.child(WORK, "state")
local FAILED  = LrPathUtils.child(WORK, "failed")
local RUNLOG  = LrPathUtils.child(WORK, "engine-output.log")
local ENGINE  = LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, "bin"), "mdkeyer")

-- what each Start command watches for
local TRIGGERS = {
    pick = { label = "picks",       already = "%d photo(s) in this catalog are already picked.",
             onlyNew = "Only new picks" },
    blue = { label = "blue labels", already = "%d photo(s) in this catalog already have a blue label.",
             onlyNew = "Only new blue labels" },
}

local prefs = LrPrefs.prefsForPlugin()
local Keyer = {}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function catalogInfo()
    local catalog = LrApplication.activeCatalog()
    local path = catalog:getPath()
    local name = LrPathUtils.removeExtension(LrPathUtils.leafName(path))
    local out = LrPathUtils.child(LrPathUtils.parent(path), "Media Day Cutouts")
    -- short stable id so two catalogs with the same name don't share state
    local h = 0
    for i = 1, #path do h = (h * 31 + path:byte(i)) % 1000000007 end
    local stateFile = LrPathUtils.child(STATE, name:gsub("[^%w%-_ ]", "_") .. "-" .. h .. ".txt")
    return catalog, out, stateFile
end

local function loadSeen(stateFile)
    local seen = {}
    local f = io.open(stateFile, "r")
    if f then
        for line in f:lines() do if line ~= "" then seen[line] = true end end
        f:close()
    end
    return seen
end

local function markSeen(stateFile, seen, uuid)
    if seen[uuid] then return end
    seen[uuid] = true
    local f = io.open(stateFile, "a")
    if f then f:write(uuid, "\n"); f:close() end
end

local function jsonString(s)
    return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function countFiles(dir, suffix)
    local n = 0
    if LrFileUtils.exists(dir) then
        for f in LrFileUtils.files(dir) do
            if f:sub(-#suffix) == suffix then n = n + 1 end
        end
    end
    return n
end

local function newTagged(catalog, seen, trigger)
    local photos = catalog:getAllPhotos()
    local meta = catalog:batchGetRawMetadata(photos, { "pickStatus", "colorNameForLabel", "uuid", "fileFormat" })
    local found = {}
    for photo, m in pairs(meta) do
        local tagged = (trigger == "blue" and m.colorNameForLabel == "blue")
                    or (trigger == "pick" and m.pickStatus == 1)
        if tagged and m.fileFormat ~= "VIDEO" and not seen[m.uuid] then
            found[#found + 1] = photo
        end
    end
    return found
end

-- A plugin downloaded from the internet arrives quarantined, and macOS refuses to run the bundled
-- engine until that flag is cleared. The user chose to install this plugin, so clear it here
-- (same as running `xattr -dr com.apple.quarantine` on the plugin by hand).
local function prepareEngine()
    LrTasks.execute(string.format('/usr/bin/xattr -dr com.apple.quarantine "%s"', _PLUGIN.path))
    LrTasks.execute(string.format('/bin/chmod +x "%s"', ENGINE))
end

local EXPORT_SETTINGS = {
    LR_export_destinationType       = "specificFolder",
    LR_export_destinationPathPrefix = INBOX,
    LR_export_useSubfolder          = false,
    LR_collisionHandling            = "rename",
    LR_renamingTokensOn             = false,
    LR_extensionCase                = "lowercase",
    LR_format                       = "TIFF",
    LR_export_bitDepth              = 8,
    LR_export_colorSpace            = "sRGB",
    LR_tiff_compressionMethod       = "compressionMethod_None",
    LR_size_doConstrain             = false,
    LR_outputSharpeningOn           = false,
    LR_useWatermark                 = false,
    LR_minimizeEmbeddedMetadata     = false,
    LR_embeddedMetadataOption       = "all",
    LR_removeLocationMetadata       = false,
    LR_includeVideoFiles            = false,
    LR_reimportExportedPhoto        = false,
    LR_export_postProcessing        = "doNothing",
}

-- Export photos to the inbox and hand each one to the engine. Returns how many were queued.
local function queue(photos, outDir, stateFile, seen, withPsd)
    if #photos == 0 then return 0 end
    LrFileUtils.createAllDirectories(INBOX)
    local session = LrExportSession { photosToExport = photos, exportSettings = EXPORT_SETTINGS }
    local queued = 0
    for _, rendition in session:renditions() do
        local ok, pathOrMsg = rendition:waitForRender()
        local uuid = rendition.photo:getRawMetadata("uuid")
        if ok then
            local f = io.open(pathOrMsg .. ".json", "w")
            if f then
                f:write('{"out": ', jsonString(outDir), ', "psd": ', withPsd and "true" or "false", '}')
                f:close()
                queued = queued + 1
            end
        end
        -- mark even a failed render as sent, so one bad file can't loop forever
        markSeen(stateFile, seen, uuid)
    end
    return queued
end

-- ── the two loops ────────────────────────────────────────────────────────────

local function watchLoop(runId, catalog, outDir, stateFile, seen, status, withPsd, trigger)
    while prefs.runId == runId do
        local picks = newTagged(catalog, seen, trigger)
        if #picks > 0 then
            status.queued = status.queued + queue(picks, outDir, stateFile, seen, withPsd)
        end
        LrTasks.sleep(2)
    end
end

local function processLoop(runId, status)
    local cmd = string.format('"%s" next --work "%s" >> "%s" 2>&1', ENGINE, WORK, RUNLOG)
    while prefs.runId == runId do
        local waiting = countFiles(INBOX, ".json")
        if waiting > 0 then
            local failedBefore = countFiles(FAILED, ".error.txt")
            LrTasks.execute(cmd)
            if countFiles(FAILED, ".error.txt") > failedBefore then
                status.failed = status.failed + 1
            else
                status.done = status.done + 1
            end
        else
            LrTasks.sleep(2)
        end
    end
end

-- ── menu commands ────────────────────────────────────────────────────────────

-- trigger: "pick" (flagged with P) or "blue" (blue colour label)
function Keyer.start(withPsd, trigger)
    if prefs.runId then
        LrDialogs.message("Media Day Keyer is already on.",
            "Look for its progress bar in the top-left corner. Use File > Plug-in Extras > Stop Auto-Keying to turn it off.")
        return
    end
    if not LrFileUtils.exists(ENGINE) then
        LrDialogs.message("Media Day Keyer is missing its engine.",
            "Expected: " .. ENGINE .. "\n\nRe-download the plugin from the GitHub release page.", "critical")
        return
    end
    prepareEngine()
    LrFileUtils.createAllDirectories(STATE)
    local t = TRIGGERS[trigger]

    local catalog, outDir, stateFile = catalogInfo()
    local seen = loadSeen(stateFile)
    local existing = newTagged(catalog, seen, trigger)
    if #existing > 0 then
        local answer = LrDialogs.confirm(
            string.format(t.already, #existing),
            "Key them now too, or only ones you mark from here on?",
            "Key them too", "Cancel", t.onlyNew)
        if answer == "cancel" then return end
        if answer == "other" then
            for _, photo in ipairs(existing) do markSeen(stateFile, seen, photo:getRawMetadata("uuid")) end
        end
    end

    local runId = tostring(os.time()) .. tostring(math.random(100000))
    prefs.runId = runId
    prefs.withPsd = withPsd
    local status = { queued = 0, done = 0, failed = 0 }

    LrTasks.startAsyncTask(function() watchLoop(runId, catalog, outDir, stateFile, seen, status, withPsd, trigger) end,
                           "Media Day Keyer watch")
    LrTasks.startAsyncTask(function() processLoop(runId, status) end, "Media Day Keyer process")

    -- progress bar in the top-left corner doubles as the status display and the off switch
    LrFunctionContext.callWithContext("Media Day Keyer", function(context)
        local title = string.format("Media Day Keyer — keying %s (%s)", t.label, withPsd and "PNG + PSD" or "PNG")
        local progress = LrProgressScope { title = title, functionContext = context }
        progress:setCancelable(true)
        if progress.setIndeterminate then progress:setIndeterminate() end
        while prefs.runId == runId do
            if progress:isCanceled() then prefs.runId = nil; break end
            local waiting = countFiles(INBOX, ".json")
            local caption = string.format("%d keyed · %d in queue", status.done, waiting)
            if status.failed > 0 then caption = caption .. string.format(" · %d failed", status.failed) end
            progress:setCaption(caption)
            LrTasks.sleep(1)
        end
        progress:done()
    end)
end

function Keyer.stop()
    if not prefs.runId then
        LrDialogs.message("Media Day Keyer isn't running.")
        return
    end
    prefs.runId = nil
    LrDialogs.showBezel("Media Day Keyer off — anything already queued stays in the inbox for next time")
end

function Keyer.rekeySelected()
    local catalog, outDir, stateFile = catalogInfo()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then
        LrDialogs.message("Select the photos to re-key first.")
        return
    end
    if not prefs.runId then prepareEngine() end
    LrFileUtils.createAllDirectories(STATE)
    local seen = loadSeen(stateFile)
    -- re-keys follow whichever mode is on (PNG only when it's off)
    local n = queue(photos, outDir, stateFile, seen, prefs.runId ~= nil and prefs.withPsd == true)
    if prefs.runId then
        LrDialogs.showBezel(string.format("Re-keying %d photo(s)", n))
    else
        LrDialogs.message(string.format("Queued %d photo(s).", n),
            "They'll be keyed as soon as you turn on one of the Start Auto-Keying commands in File > Plug-in Extras.")
    end
end

function Keyer.openCutouts()
    local _, outDir = catalogInfo()
    if LrFileUtils.exists(outDir) then
        LrShell.revealInShell(outDir)
    else
        LrDialogs.message("No cut-outs yet for this catalog.", "They'll appear in: " .. outDir)
    end
end

function Keyer.openWorkFolder()
    LrFileUtils.createAllDirectories(WORK)
    LrShell.revealInShell(LrPathUtils.child(WORK, "keyer.log"))
end

return Keyer
