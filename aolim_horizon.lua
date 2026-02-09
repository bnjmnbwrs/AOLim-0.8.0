_addon.name    = 'aolim'
_addon.author  = 'Ben'
_addon.version = '0.8.0'
_addon.command = 'aolim'

require('common')
require('imguidef')

local settings = require('aolim_settings')

-- ============================================================
-- Global toggles / defaults
-- ============================================================
AOLIM_VISIBLE = (settings.window and settings.window.is_open) or false

-- UI typing (InputText) can crash on some servers/builds.
-- Keep OFF by default; users can enable on Horizon if stable.
AOLIM_UIINPUT = false

-- How to send /sea on this server:
--  'input'  -> /input /sea all NAME
--  'plain'  -> /sea all NAME
AOLIM_SEA_MODE = 'input'   -- Horizon-friendly default; change via /aolim seamode plain|input

-- Safety: if UI ever crashes for a user, they can hard-disable UI rendering.
AOLIM_SAFE_NO_UI = false

-- ============================================================
-- Safe chat output
-- ============================================================
function chat_print(msg)
    local line = '[aolim] ' .. tostring(msg)
    if AshitaCore and AshitaCore.GetChatManager then
        local cm = AshitaCore:GetChatManager()
        if cm then
            pcall(function() cm:AddChatMessage(200, line) end)
            return
        end
    end
    print(line)
end

-- ============================================================
-- Ashita event compatibility
-- ============================================================
local function register_event(eventName, uniqueName, callback)
    if ashita and ashita.events and type(ashita.events.register) == 'function' then
        return ashita.events.register(eventName, uniqueName, callback)
    end
    if ashita and type(ashita.register_event) == 'function' then
        return ashita.register_event(eventName, callback)
    end
    error('No supported Ashita event registration API found.')
end

-- ============================================================
-- Command queue (Ashita requires int overload on some builds)
-- ============================================================
local function queue_cmd(cmd)
    if not (AshitaCore and AshitaCore.GetChatManager) then return end
    local cm = AshitaCore:GetChatManager()
    if not cm then return end
    cm:QueueCommand(tostring(cmd), 1)
end

-- ============================================================
-- Helpers
-- ============================================================
local function now_s() return os.time() end
local function normalize_name(n) return (tostring(n or ''):gsub('%s+', '')) end

local function split_args(s)
    local t = {}
    for w in tostring(s):gmatch('%S+') do t[#t + 1] = w end
    return t
end

local function seconds_ago(ts)
    ts = tonumber(ts or 0) or 0
    if ts <= 0 then return 'never' end
    local d = os.time() - ts
    if d < 0 then d = 0 end
    return tostring(d) .. 's ago'
end

local function safe_lower(s)
    return tostring(s or ''):lower()
end

-- Strip timestamp prefix like {17:50:06} and control chars
local function clean_chat_line(s)
    s = tostring(s or '')
    s = s:gsub('^%b{}%s*', '')
    s = s:gsub('[\001-\031]', '')
    return s
end

-- ============================================================
-- Persistence (aolim_data.lua next to this addon)
-- ============================================================
local function get_script_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    local dir = src:match('^(.*[\\/])') or '.\\'
    dir = dir:gsub('[\\/]+$', '')
    return dir
end

local addon_dir = get_script_dir()
local data_path = addon_dir .. '\\aolim_data.lua'

local function serialize_value(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = { '{\n' }
        local nextIndent = indent .. '    '
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
                key = k
            else
                key = '[' .. serialize_value(k, nextIndent) .. ']'
            end
            parts[#parts + 1] = string.format('%s%s = %s,\n', nextIndent, key, serialize_value(val, nextIndent))
        end
        parts[#parts + 1] = indent .. '}'
        return table.concat(parts)
    end
    return 'nil'
end

local function save_data(t)
    local f = io.open(data_path, 'w+')
    if not f then return false end
    f:write('return ' .. serialize_value(t) .. '\n')
    f:close()
    return true
end

local function load_data()
    local ok, chunk = pcall(loadfile, data_path)
    if not ok or not chunk then return nil end
    local ok2, t = pcall(chunk)
    if not ok2 then return nil end
    return t
end

-- ============================================================
-- State
-- ============================================================
local state = {
    buddies = {}, -- { name, online=true/false/nil, unread, last_checked, last_ping }

    ui = {
        selected_buddy = 0,
        status = 'Loaded. /aolim help',

        blink_on = false,
        next_blink_t = 0,
        blink_period = 0.6,

        remove_confirm_name = '',
        remove_confirm_until = 0.0,
        deferred_remove_idx = 0,

        tell_text = '',
    },

    presence = {
        watch_enabled = false,
        watch_interval = 30,
        per_buddy_cooldown = 15,
        global_cooldown = 2,
        next_watch_time = 0,
        global_last_ping = 0,
        rr = 0,

        -- pending /sea request
        pending_name = '',
        pending_idx = 0,
        pending_until = 0,

        last_note = '',
    },
}

-- ============================================================
-- Buddy ops
-- ============================================================
local function find_buddy(name)
    local n = normalize_name(name):lower()
    for i, b in ipairs(state.buddies) do
        if type(b) == 'table' and normalize_name(b.name):lower() == n then
            return i
        end
    end
    return nil
end

local function add_buddy(name)
    name = normalize_name(name)
    if name == '' then return false end
    if find_buddy(name) then return false end

    table.insert(state.buddies, {
        name = name,
        online = nil,
        unread = 0,
        last_checked = 0,
        last_ping = 0,
    })
    return true
end

local function del_buddy_by_index(idx)
    idx = tonumber(idx or 0) or 0
    if idx < 1 or idx > #state.buddies then return false end
    table.remove(state.buddies, idx)

    if state.ui.selected_buddy == idx then state.ui.selected_buddy = 0 end
    if state.ui.selected_buddy > idx then state.ui.selected_buddy = state.ui.selected_buddy - 1 end
    return true
end

-- ============================================================
-- Save / Load
-- ============================================================
local function save_all()
    save_data({
        window  = { is_open = (AOLIM_VISIBLE == true) },
        uiinput = (AOLIM_UIINPUT == true),
        seamode = tostring(AOLIM_SEA_MODE or 'input'),
        buddies = state.buddies,
        presence = state.presence,
    })
end

local function load_all()
    local d = load_data()
    if not d then return end

    if d.window then
        AOLIM_VISIBLE = (d.window.is_open == true)
    end
    AOLIM_UIINPUT = (d.uiinput == true)
    if type(d.seamode) == 'string' then
        local m = d.seamode:lower()
        if m == 'plain' or m == 'input' then AOLIM_SEA_MODE = m end
    end

    if type(d.presence) == 'table' then
        for k, v in pairs(d.presence) do
            state.presence[k] = v
        end
    end

    if type(d.buddies) == 'table' then
        state.buddies = d.buddies
        for _, b in ipairs(state.buddies) do
            if type(b) == 'table' then
                b.name = tostring(b.name or '')
                b.unread = tonumber(b.unread or 0) or 0
                b.last_checked = tonumber(b.last_checked or 0) or 0
                b.last_ping = tonumber(b.last_ping or 0) or 0
            end
        end
    end
end

-- ============================================================
-- Blink
-- ============================================================
local function update_blink()
    local t = os.clock()
    if t >= (state.ui.next_blink_t or 0) then
        state.ui.blink_on = not state.ui.blink_on
        state.ui.next_blink_t = t + (state.ui.blink_period or 0.6)
    end
end

-- ============================================================
-- Presence: send /sea
-- ============================================================
local function send_sea_for(name)
    name = normalize_name(name)
    if name == '' then return end
    if AOLIM_SEA_MODE == 'plain' then
        queue_cmd('/sea all ' .. name)
    else
        queue_cmd('/input /sea all ' .. name)
    end
end

local function ping_buddy_by_index(idx)
    local b = state.buddies[idx]
    if not b or not b.name or b.name == '' then return false end

    local t = now_s()

    -- one pending at a time
    if (tonumber(state.presence.pending_idx or 0) or 0) ~= 0 and t <= (state.presence.pending_until or 0) then
        return false
    end

    if (t - (state.presence.global_last_ping or 0)) < (state.presence.global_cooldown or 2) then
        return false
    end

    if (t - (b.last_ping or 0)) < (state.presence.per_buddy_cooldown or 15) then
        return false
    end

    b.last_ping = t
    state.presence.global_last_ping = t

    state.presence.pending_name = b.name
    state.presence.pending_idx = idx
    state.presence.pending_until = t + 12
    state.presence.last_note = 'pending...'

    send_sea_for(b.name)
    return true
end

local function presence_watch_tick()
    if not state.presence.watch_enabled then return end
    local t = now_s()
    if t < (state.presence.next_watch_time or 0) then return end
    state.presence.next_watch_time = t + (state.presence.watch_interval or 30)

    if #state.buddies == 0 then return end

    state.presence.rr = (state.presence.rr or 0) + 1
    if state.presence.rr > #state.buddies then state.presence.rr = 1 end

    ping_buddy_by_index(state.presence.rr)
end

-- ============================================================
-- TEXT PARSING
-- 1) Inbound tell (Horizon format you gave):
--      Puckmi>> : you'll want snk/invis
-- 2) /sea results (Horizon exact lines):
--      Search result: Only one person found in the entire world.
--      Search result: 0 people found in all known areas.
-- ============================================================
local function parse_incoming_text(e)
    local raw = ''
    if type(e) == 'table' then
        raw = e.message or e.text or e.modified_message or e.message_modified or e.data or ''
    else
        raw = e
    end

    local txt = clean_chat_line(raw)
    local low = safe_lower(txt)

    -- ----------------------------
    -- /sea result parsing FIRST
    -- ----------------------------
    if (tonumber(state.presence.pending_idx or 0) or 0) ~= 0 then
        -- We only accept results while pending window is active.
        local t = now_s()
        if t <= (state.presence.pending_until or 0) then
            if low:find('search%s*result%s*:', 1) then
                local online_hit  = (low:find('only one person found', 1, true) ~= nil)
                local offline_hit = (low:find('0 people found', 1, true) ~= nil) or (low:find('no one found', 1, true) ~= nil)

                if online_hit or offline_hit then
                    local idx = tonumber(state.presence.pending_idx or 0) or 0
                    if idx >= 1 and idx <= #state.buddies and state.buddies[idx] then
                        state.buddies[idx].online = online_hit and true or false
                        state.buddies[idx].last_checked = t
                    end

                    state.presence.last_note = online_hit and 'SEA: online' or 'SEA: offline'
                    state.presence.pending_name = ''
                    state.presence.pending_idx = 0
                    state.presence.pending_until = 0
                    return false
                end
            end
        end
    end

    -- ----------------------------
    -- inbound tell parsing
    -- ----------------------------
    local from, msg = txt:match('^%s*([^>]+)>>%s*:%s*(.+)$')
    if from and msg then
        from = normalize_name(from)
        local idx = find_buddy(from)
        if idx then
            state.buddies[idx].online = true
            state.buddies[idx].last_checked = now_s()
            if state.ui.selected_buddy ~= idx then
                state.buddies[idx].unread = (state.buddies[idx].unread or 0) + 1
            end
        end
    end

    return false
end

-- Register across likely text events:
register_event('text_in',        'aolim_text_in',        parse_incoming_text)
register_event('incoming_text',  'aolim_incoming_text',  parse_incoming_text)
register_event('text_out',       'aolim_text_out',       parse_incoming_text)
register_event('outgoing_text',  'aolim_outgoing_text',  parse_incoming_text)

-- ============================================================
-- Load / Unload
-- ============================================================
register_event('load', 'aolim_load', function()
    load_all()
    chat_print(state.ui.status)
    chat_print('SEA mode: ' .. tostring(AOLIM_SEA_MODE) .. ' (change: /aolim seamode plain|input)')
end)

register_event('unload', 'aolim_unload', function()
    save_all()
end)

-- ============================================================
-- COMMAND HANDLER
-- ============================================================
register_event('command', 'aolim_command', function(e_or_cmd, ntype)
    local raw = ''
    if type(e_or_cmd) == 'table' then raw = tostring(e_or_cmd.command or '') else raw = tostring(e_or_cmd or '') end
    raw = raw:gsub('^%s+', ''):gsub('%s+$', '')
    local lower = raw:lower()

    if not (lower:match('^/aolim') or lower:match('^aolim')) then
        return false
    end

    if type(e_or_cmd) == 'table' then
        e_or_cmd.blocked = true
    end

    local args = split_args(lower)
    local sub = args[2] or 'toggle'

    if sub == 'toggle' then
        AOLIM_VISIBLE = not AOLIM_VISIBLE
        save_all()
        return true
    elseif sub == 'open' then
        AOLIM_VISIBLE = true
        save_all()
        return true
    elseif sub == 'close' then
        AOLIM_VISIBLE = false
        save_all()
        return true
    end

    if sub == 'add' and args[3] then
        local name = tostring(args[3])
        if add_buddy(name) then
            chat_print('Added buddy: ' .. name)
            save_all()
        else
            chat_print('Add failed (blank/duplicate).')
        end
        return true
    end

    if (sub == 'del' or sub == 'remove') and args[3] then
        local idx = find_buddy(args[3])
        if idx then
            del_buddy_by_index(idx)
            chat_print('Removed buddy: ' .. tostring(args[3]))
            save_all()
        else
            chat_print('Buddy not found: ' .. tostring(args[3]))
        end
        return true
    end

    if sub == 'ping' then
        local idx = nil
        if args[3] then
            idx = find_buddy(args[3])
        else
            idx = tonumber(state.ui.selected_buddy or 0) or 0
            if idx < 1 then idx = nil end
        end

        if idx then
            ping_buddy_by_index(idx)
            chat_print('Ping queued: ' .. tostring(state.buddies[idx].name))
            save_all()
        else
            chat_print('Usage: /aolim ping <name> (or select a buddy)')
        end
        return true
    end

    if sub == 'watch' then
        local v = args[3] or ''
        if v == 'on' then
            state.presence.watch_enabled = true
            state.presence.next_watch_time = 0
            chat_print('Watch: ON')
            save_all()
            return true
        elseif v == 'off' then
            state.presence.watch_enabled = false
            chat_print('Watch: OFF')
            save_all()
            return true
        end
        chat_print('Usage: /aolim watch on|off')
        return true
    end

    if sub == 'interval' then
        local n = tonumber(args[3] or '')
        if n and n >= 5 then
            state.presence.watch_interval = n
            chat_print('Watch interval set to: ' .. tostring(n) .. 's')
            save_all()
        else
            chat_print('Usage: /aolim interval <sec> (min 5)')
        end
        return true
    end

    if sub == 'seamode' then
        local v = tostring(args[3] or ''):lower()
        if v == 'plain' or v == 'input' then
            AOLIM_SEA_MODE = v
            chat_print('SEA mode set: ' .. v)
            save_all()
            return true
        end
        chat_print('Usage: /aolim seamode plain|input')
        return true
    end

    if sub == 'uiinput' then
        local v = tostring(args[3] or ''):lower()
        if v == 'on' then
            AOLIM_UIINPUT = true
            chat_print('UI typing: ON')
            save_all()
            return true
        elseif v == 'off' then
            AOLIM_UIINPUT = false
            chat_print('UI typing: OFF')
            save_all()
            return true
        end
        chat_print('Usage: /aolim uiinput on|off')
        return true
    end

    if sub == 'help' then
        chat_print('Commands:')
        chat_print('/aolim              - toggle window')
        chat_print('/aolim open         - open window')
        chat_print('/aolim close        - close window')
        chat_print('/aolim add NAME     - add buddy')
        chat_print('/aolim del NAME     - remove buddy')
        chat_print('/aolim ping [name]  - /sea check online status')
        chat_print('/aolim watch on|off - auto /sea watch')
        chat_print('/aolim interval SEC - set watch interval')
        chat_print('/aolim seamode plain|input - how to issue /sea')
        chat_print('/aolim uiinput on|off - enable UI tell input (optional)')
        return true
    end

    chat_print('Unknown. Try: /aolim help')
    return true
end)

-- ============================================================
-- Deferred remove (safe)
-- ============================================================
local function flush_deferred_remove()
    local idx = tonumber(state.ui.deferred_remove_idx or 0) or 0
    if idx >= 1 and idx <= #state.buddies then
        local name = tostring(state.buddies[idx] and state.buddies[idx].name or '')
        del_buddy_by_index(idx)
        save_all()
        chat_print('Removed buddy: ' .. name)
    end
    state.ui.deferred_remove_idx = 0
end

-- ============================================================
-- UI
-- ============================================================
local function aolim_draw()
    if AOLIM_SAFE_NO_UI then return end
    if not AOLIM_VISIBLE then return end

    update_blink()
    presence_watch_tick()

    -- timeout pending -> unknown
    do
        local t = now_s()
        if (tonumber(state.presence.pending_idx or 0) or 0) ~= 0 and t > (state.presence.pending_until or 0) then
            local idx = tonumber(state.presence.pending_idx or 0) or 0
            if idx >= 1 and idx <= #state.buddies and state.buddies[idx] then
                state.buddies[idx].online = nil
                state.buddies[idx].last_checked = t
            end
            state.presence.pending_name = ''
            state.presence.pending_idx = 0
            state.presence.pending_until = 0
            state.presence.last_note = 'timeout -> unknown'
        end
    end

    imgui.Begin('AOLIM')

    imgui.Text(string.format(
        'SEA pending_idx=%d pending_name=%s  note=%s',
        tonumber(state.presence.pending_idx or 0) or 0,
        tostring(state.presence.pending_name or ''),
        tostring(state.presence.last_note or '')
    ))
    imgui.Text('Watch: ' .. (state.presence.watch_enabled and 'ON' or 'OFF') ..
              '  interval=' .. tostring(state.presence.watch_interval) ..
              's  seamode=' .. tostring(AOLIM_SEA_MODE))
    imgui.Separator()

    -- Left panel: buddies
    imgui.BeginChild('buddy_list', 220, 0, true)

    if #state.buddies == 0 then
        imgui.TextDisabled('No buddies added.')
        imgui.TextDisabled('Use /aolim add <name>')
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild('panel', 0, 0, false)
        imgui.TextWrapped('Select a buddy on the left.')
        imgui.EndChild()
        imgui.End()
        return
    end

    for i, b in ipairs(state.buddies) do
        if type(b) == 'table' then
            local name = tostring(b.name or 'Unknown')
            local unread = tonumber(b.unread or 0) or 0
            local pending = (state.presence.pending_idx == i)

            -- Dot color
            if pending then
                imgui.TextColored(0.95, 0.85, 0.20, 1.0, 'o') -- yellow
            elseif b.online == true then
                imgui.TextColored(0.20, 0.90, 0.20, 1.0, 'o') -- green
            elseif b.online == false then
                imgui.TextColored(0.60, 0.60, 0.60, 1.0, 'o') -- gray
            else
                imgui.TextColored(0.80, 0.80, 0.20, 1.0, '?') -- unknown
            end
            imgui.SameLine()

            local label = name
            if pending then label = label .. ' (checking...)' end
            if unread > 0 and state.ui.blink_on then label = label .. ' *' end
            if unread > 0 then label = '! ' .. label end

            if imgui.Selectable(label) then
                state.ui.selected_buddy = i
                b.unread = 0
            end

            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text('Last checked: ' .. seconds_ago(b.last_checked))
                if b.online == true then
                    imgui.Text('Status: Online')
                elseif b.online == false then
                    imgui.Text('Status: Offline')
                else
                    imgui.Text('Status: Unknown')
                end
                imgui.EndTooltip()
            end

            -- Right-click menu
            if imgui.BeginPopupContextItem('buddy_ctx_' .. tostring(i)) then
                if imgui.MenuItem('Invite to Party') then
                    queue_cmd('/pcmd add ' .. name)
                end
                if imgui.MenuItem('Ping (/sea)') then
                    ping_buddy_by_index(i)
                end
                if imgui.MenuItem('Remove Buddy (arm confirm)') then
                    state.ui.remove_confirm_name = name
                    state.ui.remove_confirm_until = os.clock() + 3.0
                    chat_print('Click Remove Buddy button to confirm: ' .. name)
                end
                imgui.EndPopup()
            end
        end
    end

    imgui.EndChild()
    flush_deferred_remove()

    -- Right panel: actions
    imgui.SameLine()
    imgui.BeginChild('panel', 0, 0, false)

    local sel = tonumber(state.ui.selected_buddy or 0) or 0
    if sel >= 1 and state.buddies[sel] and state.buddies[sel].name then
        local name = tostring(state.buddies[sel].name)

        imgui.Text('Buddy → ' .. name)
        imgui.Separator()

        if imgui.Button('Invite to Party') then
            queue_cmd('/pcmd add ' .. name)
        end
        imgui.SameLine()
        if imgui.Button('Ping (/sea)') then
            ping_buddy_by_index(sel)
        end

        imgui.Separator()

        -- Optional UI tell input (OFF by default)
        if AOLIM_UIINPUT then
            imgui.TextWrapped('UI typing enabled. If unstable, run: /aolim uiinput off')
            imgui.PushItemWidth(-1)
            local out = imgui.InputText('##tell_input', tostring(state.ui.tell_text or ''), 256)
            imgui.PopItemWidth()
            if type(out) == 'string' then state.ui.tell_text = out end

            if imgui.Button('Send Tell') and tostring(state.ui.tell_text or '') ~= '' then
                queue_cmd('/tell ' .. name .. ' ' .. tostring(state.ui.tell_text))
                state.ui.tell_text = ''
            end
            imgui.Separator()
        else
            imgui.TextWrapped('Tell sending via UI is optional and OFF by default.')
            imgui.TextWrapped('Use: /aolim uiinput on  (Horizon)')
            imgui.TextWrapped('Or send tells normally in-game.')
            imgui.Separator()
        end

        -- Remove confirm button
        local nowc = os.clock()
        local armed =
            (state.ui.remove_confirm_name == name) and
            (nowc <= state.ui.remove_confirm_until)

        local btn_label = armed and 'Confirm Remove (3s)' or 'Remove Buddy'
        if imgui.Button(btn_label) then
            if armed then
                state.ui.deferred_remove_idx = sel
                state.ui.selected_buddy = 0
                state.ui.remove_confirm_name = ''
                state.ui.remove_confirm_until = 0
            else
                state.ui.remove_confirm_name = name
                state.ui.remove_confirm_until = nowc + 3.0
                chat_print('Click again to confirm remove: ' .. name)
            end
        end

        if (state.ui.remove_confirm_name == name) and (nowc > state.ui.remove_confirm_until) then
            state.ui.remove_confirm_name = ''
            state.ui.remove_confirm_until = 0
        end
    else
        imgui.TextWrapped('Select a buddy on the left.')
        imgui.TextWrapped('Add buddy: /aolim add <name>')
    end

    imgui.EndChild()
    imgui.End()
end

-- Draw hooks (different builds fire different ones)
register_event('present',     'aolim_present',     aolim_draw)
register_event('render',      'aolim_render',      aolim_draw)
register_event('d3d_present', 'aolim_d3d_present', aolim_draw)
register_event('frame',       'aolim_frame',       aolim_draw)
