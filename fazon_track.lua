--[[ Fazon Nexus Tracker for VLC: log what you watch to your fazon.nexus Track.
https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker

Off whenever VLC starts. To track what's playing: View → Fazon Track (the first time each VLC
session; after that, View → Fazon Track → Start tracking…). Name the sub-category (the title is
filled in) and pick Active or Passive immersion. Only one runs at a time: starting the other one
switches over. View → Fazon Track → Stop tracking turns it off; Status shows what's going on.

Only time spent playing counts (not paused or stopped), in real time. Time is sent whenever you
pause, stop, change video, stop tracking or quit VLC; anything that can't be sent (offline) is kept
and retried, also the next time you turn tracking on. When the playlist moves on, tracking carries
on under the new video's title.

The first time, it asks for your API key and keeps it in fazon_track_key.conf in VLC's config
folder (as a curl header, so it never shows up in the process list).
]]

local VERSION = "1.0.1"

-- Settings
local API = "https://api.fazon.nexus/v1/api/track" -- only change this for your own copy of the site
local CONTINUE_ON_NEXT_FILE = true -- keep tracking when the playlist moves on, as the new title
local DEFAULT_SUBCAT = ""          -- suggest this name instead of the title, e.g. "Anime"

local LABEL = { active = "Active immersion", passive = "Passive immersion" }
local WINDOWS = false -- set in activate(): VLC scans extensions without the package library
local json
local key_file, state_dir, pending_file

local track = nil      -- {category, name, uri, secs}
local play_since = nil -- vlc.misc.mdate() when playback (of the tracked video) last started
local log = {}         -- {week, category, name, secs}: time not yet sent
local dlg, name_input, key_input, note = nil, nil, nil, nil

------------------------------------------------------------------ helpers

-- Quote a path for the shell (cmd.exe on Windows).
local function q(s)
    if WINDOWS then return '"' .. tostring(s):gsub("/", "\\") .. '"' end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fmt_dur(secs)
    local m = math.floor(secs / 60 + 0.5)
    return string.format("%dh %02dm", math.floor(m / 60), m % 60)
end

local function osd(text)
    pcall(vlc.osd.message, "Track: " .. text, nil, "top-left", 4000000)
    vlc.msg.info("[Fazon Track] " .. text)
end

local function close_dialog()
    if dlg then dlg:delete() end
    dlg, name_input, key_input, note = nil, nil, nil, nil
end

-- A small window with a message (VLC shows no on-screen text for audio-only files).
local function message(text)
    close_dialog()
    dlg = vlc.dialog("Fazon Track")
    dlg:add_label(text, 1, 1, 1, 1)
    dlg:add_button("OK", close_dialog, 1, 2, 1, 1)
    dlg:show()
    vlc.msg.info("[Fazon Track] " .. text)
end

-- A problem with what was typed into the open dialog: say so in it, so it can be fixed there.
local function tell(text)
    if not note then return message(text) end
    note:set_text(text)
    vlc.msg.info("[Fazon Track] " .. text)
end

local function exists(path)
    local fh = io.open(path, "r")
    if fh then fh:close() end
    return fh ~= nil
end

-- Track weeks run from Sunday 03:00 UTC; a week's key is the Saturday before it starts.
local function week_of(t)
    local s = t - 3 * 3600
    local d = os.date("!*t", s)
    local sunday = s - (d.wday - 1) * 86400 - (d.hour * 3600 + d.min * 60 + d.sec)
    return os.date("!%Y-%m-%d", sunday - 86400), sunday + 3 * 3600 -- key, start time
end

-- The site's sub-category names: 1-40 characters, no control characters.
local function clean_name(s)
    s = (s or ""):gsub("%c", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > 40 then break end
        out[n] = ch
    end
    return (table.concat(out):gsub(" $", ""))
end

local function default_name(item)
    if DEFAULT_SUBCAT ~= "" then return clean_name(DEFAULT_SUBCAT) end
    local m = item:metas() or {}
    local t = m.title
    if not t or t == "" or t == m.filename then
        -- No real title: the file name, with underscores as spaces (my_show_01 → my show 01).
        t = (m.filename or item:name() or ""):gsub("%.[^.]+$", ""):gsub("%.condensed$", ""):gsub("_", " ")
    end
    return clean_name(t)
end

------------------------------------------------------------------ HTTP (curl)

-- A string for a curl config file.
local function cq(s)
    if WINDOWS then s = tostring(s):gsub("\\", "/") end
    return '"' .. tostring(s):gsub('[\\"]', "\\%0") .. '"'
end

local HINT = {
    [401] = "\n(The API key is wrong or was revoked: View → Fazon Track → Set API key…)",
    [403] = "\n(This key is read-only: create a Read & write key on your profile, then View → Fazon Track → Set API key…)",
}

-- Everything but the key goes in a curl config file, so nothing needs quoting for the shell
-- except two paths (the same on Linux, macOS and Windows).
local function request(method, path, body, timeout)
    local req = state_dir .. "/request.conf"
    local lines = {
        "silent", "show-error",
        "max-time = " .. (timeout or 15),
        "request = " .. cq(method),
        "url = " .. cq(API .. path),
        'write-out = "\\n%{http_code}"',
    }
    if body then
        local body_file = state_dir .. "/request.json"
        local fh = io.open(body_file, "wb")
        if fh then fh:write(json.encode(body)); fh:close() end
        lines[#lines + 1] = 'header = "Content-Type: application/json"'
        lines[#lines + 1] = "data-binary = " .. cq("@" .. body_file)
    end
    local fh = io.open(req, "w")
    if not fh then return 0, nil, "can't write " .. req end
    fh:write(table.concat(lines, "\n") .. "\n")
    fh:close()
    local p = io.popen("curl -K " .. q(req) .. " -K " .. q(key_file) .. " 2>&1")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    os.remove(req)
    os.remove(state_dir .. "/request.json")
    local text, code = out:match("^(.*)\n(%d%d%d)%s*$")
    code = tonumber(code) or 0
    local data = text and text:sub(1, 1) == "{" and json.decode(text) or nil
    local err = (type(data) == "table" and data.error) or (text and text ~= "" and text)
        or (out ~= "" and out) or "no response (is curl installed?)"
    return code, data, tostring(err):gsub("%s+$", "") .. (HINT[code] or "")
end

-- Make sure the category has an active sub-category called name; returns its stored name, or
-- nil and an error.
local function ensure_subcat(category, name)
    local code, data, err = request("GET", "/subcats")
    if code ~= 200 then return nil, code .. ": " .. err end
    for _, s in ipairs(type(data) == "table" and data.subcats or {}) do
        if s.category == category and not s.archived and s.name:lower() == name:lower() then
            return s.name
        end
    end
    code, data, err = request("POST", "/subcats", { category = category, name = name })
    if code == 201 and type(data) == "table" then return data.name end
    if code == 409 and err:find("already") then return name end
    return nil, code .. ": " .. err
end

------------------------------------------------------------------ time not yet sent

local function save_log()
    local live = {}
    for _, e in ipairs(log) do if e.secs >= 18 then live[#live + 1] = e end end
    if #live == 0 then os.remove(pending_file); return end
    local fh = io.open(pending_file, "w")
    if fh then fh:write(json.encode(live)); fh:close() end
end

local function add_log(week, category, name, secs)
    for _, e in ipairs(log) do
        if e.week == week and e.category == category and e.name == name then
            e.secs = e.secs + secs
            return
        end
    end
    log[#log + 1] = { week = week, category = category, name = name, secs = secs }
end

-- Pick up time saved by earlier sessions.
local function load_saved()
    local p = io.popen((WINDOWS and "dir /b " or "ls ") .. q(state_dir) .. (WINDOWS and " 2>nul" or " 2>/dev/null"))
    for f in (p and p:read("*a") or ""):gmatch("[^\r\n]+") do
        if f:match("^pending%-.*%.json$") then
            local path = state_dir .. "/" .. f
            local fh = io.open(path, "r")
            local list = fh and json.decode(fh:read("*a")) or nil
            if fh then fh:close() end
            for _, e in ipairs(type(list) == "table" and list or {}) do
                if e.week and e.category and e.name and tonumber(e.secs) then
                    add_log(e.week, e.category, e.name, tonumber(e.secs))
                end
            end
            os.remove(path)
        end
    end
    if p then p:close() end
    save_log()
end

-- Move the time played since play_since into the log (split if a new week started meanwhile).
local function bank()
    if not track or not play_since then return end
    local now = vlc.misc.mdate()
    local secs = (now - play_since) / 1e6
    play_since = now
    if secs <= 0 then return end
    track.secs = track.secs + secs
    local t_end = os.time()
    local week, start = week_of(t_end)
    if t_end - secs < start then
        add_log((week_of(t_end - secs)), track.category, track.name, start - (t_end - secs))
        secs = t_end - start
    end
    add_log(week, track.category, track.name, secs)
    save_log()
end

-- Send the log in whole hundredths of an hour (36 s), one atomic request per week; the rest
-- waits for later. final rounds what's left to the nearest hundredth, as the site would.
local function send(final)
    local weeks, order = {}, {}
    for _, e in ipairs(log) do
        local h = math.floor(e.secs / 36 + (final and 0.5 or 0))
        if h > 0 then
            if not weeks[e.week] then weeks[e.week] = {}; order[#order + 1] = e.week end
            table.insert(weeks[e.week], { e = e, h = h })
        elseif final then
            e.secs = 0
        end
    end
    local problem
    for _, week in ipairs(order) do
        local entries = {}
        for i, b in ipairs(weeks[week]) do
            entries[i] = { category = b.e.category, subcat = b.e.name, add = string.format("%.2f", b.h / 100) }
        end
        local code, _, err = request("PATCH", "/weeks/" .. week .. "/hours", { entries = entries }, final and 5 or 15)
        if code == 200 then
            for _, b in ipairs(weeks[week]) do b.e.secs = math.max(0, b.e.secs - b.h * 36) end
            vlc.msg.info("[Fazon Track] sent " .. #entries .. " entries to week " .. week)
        elseif code == 400 and err:find("create it first") then
            -- The sub-category was archived or renamed on the site: recreate it, retry later.
            local b = weeks[week][(tonumber(err:match("entries%[(%d+)%]")) or 0) + 1]
            if b then ensure_subcat(b.e.category, b.e.name) end
        elseif code == 400 or code == 403 then
            for _, b in ipairs(weeks[week]) do b.e.secs = 0 end -- it would fail the same way forever
            problem = "Track rejected the time for week " .. week .. ":\n" .. err
        else
            vlc.msg.warn("[Fazon Track] couldn't reach Track (" .. code .. ": " .. err .. "), will retry")
        end
    end
    for i = #log, 1, -1 do if log[i].secs <= 0 then table.remove(log, i) end end
    save_log()
    if problem then message(problem) end
end

------------------------------------------------------------------ tracking

local function stop_tracking(quiet)
    if not track then return end
    bank()
    send(true)
    if not quiet then
        osd(string.format("stopped. %s → %s › %s", fmt_dur(track.secs), LABEL[track.category], track.name))
    end
    track, play_since = nil, nil
end

local function start_tracking(category)
    local item = vlc.input.item()
    local name = clean_name(name_input and name_input:get_text() or "")
    if not item then return message("Nothing is playing.") end
    if name == "" then return tell("Give it a sub-category name first.") end
    local stored, err = ensure_subcat(category, name)
    if not stored then return tell("Couldn't set up the sub-category:\n" .. err) end
    close_dialog()
    stop_tracking(true)
    track = { category = category, name = stored, uri = item:uri(), secs = 0 }
    play_since = vlc.playlist.status() == "playing" and vlc.misc.mdate() or nil
    osd("● " .. LABEL[category] .. " › " .. stored)
end

local function start_dialog()
    close_dialog()
    local item = vlc.input.item()
    if not item then return message("Play something first, then start tracking it.") end
    dlg = vlc.dialog("Fazon Track")
    dlg:add_label("Log what's playing to your Track. Sub-category (max 40 characters):", 1, 1, 3, 1)
    name_input = dlg:add_text_input(default_name(item), 1, 2, 3, 1)
    dlg:add_button("Active immersion", function() start_tracking("active") end, 1, 3, 1, 1)
    dlg:add_button("Passive immersion", function() start_tracking("passive") end, 2, 3, 1, 1)
    dlg:add_button("Cancel", close_dialog, 3, 3, 1, 1)
    note = dlg:add_label("", 1, 4, 3, 1)
    dlg:show()
end

local function status()
    bank()
    local unsent = 0
    for _, e in ipairs(log) do unsent = unsent + e.secs end
    local text = track
        and string.format("Tracking %s › %s\nThis session: %s%s", LABEL[track.category], track.name,
            fmt_dur(track.secs), play_since and "" or " (paused)")
        or "Not tracking."
    if unsent >= 18 then text = text .. "\nWaiting to be sent: " .. fmt_dur(unsent) end
    message(text .. "\n\nFazon Nexus Tracker " .. VERSION)
end

-- Playback started, paused or stopped, or the video changed.
local function changed()
    if not track then return end
    bank()
    local item = vlc.input.item()
    local playing = vlc.playlist.status() == "playing"
    local moved = item and item:uri() ~= track.uri
    if moved then
        if not CONTINUE_ON_NEXT_FILE then return stop_tracking() end
        local name = default_name(item)
        local stored, err = name, nil
        if name ~= track.name then stored, err = ensure_subcat(track.category, name) end
        if not stored then
            stop_tracking(true)
            return message("Stopped tracking: couldn't set up \"" .. name .. "\":\n" .. err)
        end
        if stored ~= track.name then
            osd("● " .. LABEL[track.category] .. " › " .. stored)
            track.secs = 0
        end
        track.name, track.uri = stored, item:uri()
    end
    play_since = playing and vlc.misc.mdate() or nil
    if moved or not playing then send(false) end
end

-- Start of a session: send anything saved earlier, then ask what to track.
local function begin()
    track, play_since, log = nil, nil, {}
    load_saved()
    send(false)
    start_dialog()
end

------------------------------------------------------------------ API key

local function save_key()
    local key = (key_input and key_input:get_text() or ""):gsub("%s", "")
    if not key:match("^fz_[%w_%-]+$") or #key ~= 46 then
        return tell("That doesn't look like an API key: it should be fz_ followed by 43 characters.")
    end
    local old = io.open(key_file, "r")
    local old_text = old and old:read("*a")
    if old then old:close() end
    if not WINDOWS then os.execute("umask 077 && : > " .. q(key_file)) end -- only you can read it
    local fh = io.open(key_file, "w")
    if not fh then return tell("Couldn't write " .. key_file) end
    fh:write("# Fazon Nexus Tracker: your API key, sent as a curl header\n")
    fh:write('header = "Authorization: Bearer ' .. key .. '"\n')
    fh:close()
    local code, _, err = request("GET", "/subcats")
    if code == 200 then
        close_dialog()
        return begin()
    end
    -- Keep the old key if the new one doesn't work.
    if old_text then
        fh = io.open(key_file, "w")
        if fh then fh:write(old_text); fh:close() end
    else
        os.remove(key_file)
    end
    tell(code == 401 and "fazon.nexus didn't accept that key. Check you copied all of it."
        or "Couldn't check the key with fazon.nexus:\n" .. code .. ": " .. err)
end

local function key_dialog()
    close_dialog()
    dlg = vlc.dialog("Fazon Track: API key")
    dlg:add_label("Paste a Read & write API key from your fazon.nexus profile (Developers section):", 1, 1, 2, 1)
    key_input = dlg:add_password("", 1, 2, 2, 1)
    dlg:add_button("Save", save_key, 1, 3, 1, 1)
    dlg:add_button("Cancel", close_dialog, 2, 3, 1, 1)
    note = dlg:add_label("", 1, 4, 2, 1)
    dlg:show()
end

------------------------------------------------------------------ VLC hooks

function descriptor()
    return {
        title = "Fazon Track",
        version = VERSION,
        author = "SomeRandomGuy64",
        url = "https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker",
        shortdesc = "Fazon Track",
        description = "Log what you watch to your fazon.nexus Track as active or passive immersion.",
        capabilities = { "menu", "input-listener", "playing-listener" },
    }
end

function activate()
    WINDOWS = (type(package) == "table" and package.config:sub(1, 1) == "\\") or os.getenv("OS") == "Windows_NT"
    json = require("dkjson")
    key_file = vlc.config.configdir() .. "/fazon_track_key.conf"
    state_dir = vlc.config.userdatadir() .. "/fazon_track"
    os.execute(WINDOWS and ("mkdir " .. q(state_dir) .. " 2>nul") or ("mkdir -p " .. q(state_dir)))
    math.randomseed(os.time())
    pending_file = string.format("%s/pending-%d-%d.json", state_dir, os.time(), math.random(1e6))
    if exists(key_file) then begin() else key_dialog() end
end

function deactivate()
    stop_tracking(true)
    if key_file and exists(key_file) then send(true) end
    close_dialog()
end

function close() close_dialog() end

function menu() return { "Start tracking…", "Stop tracking", "Status", "Set API key…" } end

function trigger_menu(id)
    if id == 1 then
        if exists(key_file) then start_dialog() else key_dialog() end
    elseif id == 2 then
        if track then stop_tracking() else message("Not tracking.") end
    elseif id == 3 then status()
    elseif id == 4 then key_dialog() end
end

function playing_changed() changed() end
function input_changed() changed() end
