-- Deathnote Forever: warns when a listed player shows up.
-- Enemy faction only for now. Detection: enemy nameplates, mouseover, target.
-- The Forever client forbids addons from registering COMBAT_LOG_EVENT_UNFILTERED.
-- Sharing: own entries are synced to guild and group members running Deathnote Forever,
-- and sightings are reported to them. Entries received from others are never re-shared.
local ADDON = ...
local PREFIX = "|cffff3333Deathnote Forever|r: "
local COMM = "DNForever"
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
local MAX_REASON = 500
local REALERT = 60
local MAX_HISTORY = 50
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local CLASS_ICONS = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local FACTIONS = { "Alliance", "Horde" }
local FACTION_ICON = { Alliance = "Interface\\Icons\\INV_BannerPVP_02", Horde = "Interface\\Icons\\INV_BannerPVP_01" }
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local CLASS_FACTION = { PALADIN = "Alliance", SHAMAN = "Horde" }

local db, ui, lastSighting
local byKey, byGUID, lastAlert, reported, icons = {}, {}, {}, {}, {}

local function secret(v) return issecretvalue and issecretvalue(v) end
local function open(v) if not secret(v) then return v end end
-- Battlegrounds hide unit tokens, names and flags behind secret values.
local function Enemy(unit)
  if not unit or secret(unit) then return false end
  local isPlayer, friend = UnitIsPlayer(unit), UnitIsFriend("player", unit)
  if secret(isPlayer) or secret(friend) then return false end
  return isPlayer and not friend
end
local function key(name) return name and (strsplit("-", name)):lower() end
local function say(msg) print(PREFIX .. msg) end
local function RefreshUI()
  if ui and ui:IsShown() then ui.Refresh() end
end
-- Levels only go up; enemies far above us read -1 and are skipped.
local function Raise(e, l)
  l = tonumber(l)
  if l and l > (e.level or 0) then
    e.level = l
    return true
  end
end

-- Visible entries: own first, then those received from others unless hidden.
local function Rebuild()
  wipe(byKey)
  wipe(byGUID)
  for k, e in pairs(db.players) do byKey[k] = e end
  for author, list in pairs(db.shared) do
    for k, e in pairs(list.entries) do
      e.author = author
      if not byKey[k] and not db.hidden[author .. "|" .. k] then byKey[k] = e end
    end
  end
  for _, e in pairs(byKey) do if e.guid then byGUID[e.guid] = e end end
end

local function find(guid, name)
  guid, name = open(guid), open(name) -- secret in battlegrounds
  local e = guid and byGUID[guid]
  if e then return e end
  e = name and byKey[key(name)]
  if not e or (e.guid and guid and e.guid ~= guid) then return end
  if guid and not e.guid then e.guid = guid; byGUID[guid] = e end
  return e
end

local function Coords(e)
  return e.seenMap and ("%.1f %.1f"):format(e.seenX * 100, e.seenY * 100) or ""
end

-- Waypoint on the last sighting: TomTom if installed, else the built-in map pin.
local function Waypoint(e)
  if not (e and e.seenMap) then return say("no sighting with coordinates yet") end
  local title = "Deathnote Forever: " .. e.name
  if TomTom and TomTom.AddWaypoint then
    TomTom:AddWaypoint(e.seenMap, e.seenX, e.seenY, { title = title })
  elseif C_Map.SetUserWaypoint and C_Map.CanSetUserWaypointOnMap(e.seenMap) then
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(e.seenMap, e.seenX, e.seenY))
    if C_SuperTrack then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
  else
    return say(("cannot place a pin here, last seen at %s %s"):format(e.seenZone or "", Coords(e)))
  end
  say(("waypoint: %s %s (%s)"):format(e.seenZone or "", Coords(e), e.name))
end

-- Comms -----------------------------------------------------------------------

local queue, incoming, replied, warnedVersion = {}, {}, {}, false
local THROTTLED = { [3] = true, [8] = true } -- Enum.SendAddonMessageResult throttle codes

local function Send(msg, channel, target) queue[#queue + 1] = { msg, channel, target } end

local function Pump()
  local m = queue[1]
  if not m then return end
  local r = C_ChatInfo.SendAddonMessage(COMM, m[1], m[2], m[3])
  if THROTTLED[r] then return end -- retry on the next tick
  table.remove(queue, 1)
end

-- Byte length cut that never splits a UTF-8 character.
local function cut(s, n)
  if #s <= n then return s end
  while n > 0 and s:byte(n + 1) >= 0x80 and s:byte(n + 1) < 0xC0 do n = n - 1 end
  return s:sub(1, n)
end

local function clean(s, n) return cut((tostring(s or ""):gsub("[\t|]", "")), n) end

local function chunks(s, n)
  local out = {}
  while #s > 0 do
    local c = cut(s, n)
    out[#out + 1] = c
    s = s:sub(#c + 1)
  end
  return out
end

local function Newer(a, b) -- is version a newer than b
  local x, y = { strsplit(".", a) }, { strsplit(".", b) }
  for i = 1, math.max(#x, #y) do
    local p, q = tonumber(x[i]) or 0, tonumber(y[i]) or 0
    if p ~= q then return p > q end
  end
  return false
end

local function GroupChannel()
  return IsInRaid() and "RAID" or IsInGroup() and "PARTY" or nil
end

-- B(egin) serial count wantReply version
-- E(ntry) serial name parts faction class guid, then R(eason) serial key index chunk per part
-- Z (end) serial. Messages are capped at 255 bytes, so long reasons go in chunks.
local function SendList(channel, target, wantReply)
  db.serial = (db.serial or 0) + 1
  local s = db.serial
  local list = {}
  for _, e in pairs(db.players) do list[#list + 1] = e end
  Send(("B\t%d\t%d\t%d\t%s"):format(s, #list, wantReply and 1 or 0, VERSION), channel, target)
  for _, e in ipairs(list) do
    local name = clean(e.name, 40)
    local parts = chunks(clean(e.reason, MAX_REASON * 2), 180)
    Send(table.concat({ "E", s, name, #parts, clean(e.faction, 10), clean(e.class, 20), clean(e.guid, 40),
      clean(e.classFile, 20), e.level or "" }, "\t"), channel, target)
    for i, part in ipairs(parts) do Send(table.concat({ "R", s, key(name), i, part }, "\t"), channel, target) end
  end
  Send("Z\t" .. s, channel, target)
end

local function Broadcast(wantReply)
  if IsInGuild() then SendList("GUILD", nil, wantReply) end
  local g = GroupChannel()
  if g then SendList(g, nil, wantReply) end
end

local scheduled
local function ScheduleBroadcast()
  if scheduled then return end
  scheduled = true
  C_Timer.After(2, function() scheduled = false; Broadcast(false) end)
end

local function SendSighting(e)
  local msg = table.concat({ "S", clean(e.name, 40), clean(e.reason, 100), clean(e.seenZone, 40),
    e.seenMap or "", e.seenMap and ("%.4f"):format(e.seenX) or "", e.seenMap and ("%.4f"):format(e.seenY) or "", e.level or "" }, "\t")
  if IsInGuild() then Send(msg, "GUILD") end
  local g = GroupChannel()
  if g then Send(msg, g) end
end

-- Only guild and group members may write into our lists (whispers included).
-- Returns which tab their entries go to: "guild" or "party".
local function Trusted(sender)
  local short = Ambiguate(sender, "none")
  for i = 1, GetNumGuildMembers() do
    local n = GetGuildRosterInfo(i)
    if n and Ambiguate(n, "none") == short then return "guild" end
  end
  if UnitInParty(short) or UnitInRaid(short) then return "party" end
end

local function SourceOf(author, list) return list.source or Trusted(author) or "party" end

-- Alerts ----------------------------------------------------------------------

-- Party, not raid, even inside a raid: only party chat draws a bubble over our head.
-- A real party too, since "PARTY" in a battleground or LFG group lands in instance chat.
local function Announce(msg)
  if db.announce and IsInGroup(LE_PARTY_CATEGORY_HOME or 1) then SendChatMessage(msg, "PARTY") end
end
local function Notify(msg, sound)
  RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo.RAID_WARNING)
  PlaySound(sound, "Master")
end

-- Time and place of a sighting. Our own position: the enemy's is not readable,
-- but nameplates only show within ~20 yd.
local function Stamp(e)
  e.seen, e.seenZone = time(), GetRealZoneText()
  local map = C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  if x and x > 0 then e.seenMap, e.seenX, e.seenY = map, x, y else e.seenMap, e.seenX, e.seenY = nil end
end

-- Sighting history, oldest first. Repeated sightings in one zone within 10 minutes are one record.
local function Log(e, by)
  local h = e.history or {}
  e.history = h
  local last = h[#h]
  if last and last.by == by and last.seenZone == e.seenZone and e.seen - last.seen < 600 then h[#h] = nil end
  h[#h + 1] = { seen = e.seen, seenZone = e.seenZone, seenMap = e.seenMap, seenX = e.seenX, seenY = e.seenY, by = by }
  if #h > MAX_HISTORY then table.remove(h, 1) end
end

local function Alert(e, how)
  local k, now = key(e.name), GetTime()
  if now - (lastAlert[k] or -REALERT) < REALERT then return end
  lastAlert[k] = now
  Stamp(e)
  Log(e)
  local msg = ("DEATHNOTE: %s (%s)"):format(e.name, e.reason)
  Notify(msg, SOUNDKIT.RAID_WARNING)
  say(msg .. (e.author and (" |cff888888from " .. e.author .. "|r") or "") .. " |cff888888[" .. how .. "]|r")
  if how ~= "test" then
    -- One report per target per group: random delay, skipped if a group member reported first.
    -- ponytail: guild members outside the group miss our report when a group member wins.
    C_Timer.After(math.random() * 2, function()
      if GetTime() - (reported[k] or -REALERT) < REALERT then return end
      SendSighting(e)
      Announce(("{rt8} Deathnote Forever: %s spotted nearby"):format(e.name))
    end)
  end
  RefreshUI()
end

local function OnSighting(author, f, channel)
  local name = f[2]
  if not name or name == "" then return end
  local k = key(name)
  if channel == "PARTY" or channel == "RAID" then reported[k] = GetTime() end
  if GetTime() - (lastAlert[k] or -REALERT) < REALERT then return end -- we have just seen them ourselves
  local e = byKey[k]
  if not e then
    for a in pairs(db.shared) do if db.hidden[a .. "|" .. k] then return end end
    e = { name = name, reason = f[3] ~= "" and f[3] or "no reason" }
  end
  local map, x, y = tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
  e.seen, e.seenZone = time(), f[4]
  if map and x and y then e.seenMap, e.seenX, e.seenY = map, x, y else e.seenMap, e.seenX, e.seenY = nil end
  Raise(e, f[8])
  Log(e, author)
  lastSighting = e
  local msg = ("%s spotted %s (%s) in %s %s"):format(author, e.name, e.reason, e.seenZone or "?", Coords(e))
  say(msg .. (e.seenMap and " - /deathnote way" or ""))
  -- On screen only when it is in our zone; elsewhere the chat line is enough.
  if e.seenZone == GetRealZoneText() then Notify(msg, SOUNDKIT.TELL_MESSAGE) end
  RefreshUI()
end

-- Recent fights ----------------------------------------------------------------
-- Suggestions for the list: enemy players who attacked us or took part in our death.

local MAX_RECENT, FIGHT_GAP = 30, 300
local RACE_FACTION = { Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
  Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde" }
local lastFight = {}

local function Fought(name, guid, killed, faction, class, classFile, level)
  local _, kind = IsInInstance()
  if not name or name == "" or kind == "pvp" or kind == "arena" then return end
  name = Ambiguate(name, "none")
  local k = key(name)
  -- Everyone in the death recap hit us, so killer and assists alike count as killing us.
  local listed = find(guid, name)
  if listed then
    if killed then listed.deaths = (listed.deaths or 0) + 1 end
    Raise(listed, level)
    return RefreshUI()
  end
  local e = db.recent[k]
  if not killed and e and GetTime() - (lastFight[k] or -FIGHT_GAP) < FIGHT_GAP then return end
  lastFight[k] = GetTime()
  e = e or { suggest = true, name = name, kills = 0, fights = 0 }
  if killed then e.kills = e.kills + 1 else e.fights = e.fights + 1 end
  e.guid, e.faction = guid or e.guid, faction or e.faction
  e.class, e.classFile = class or e.class, classFile or e.classFile
  Raise(e, level)
  Stamp(e)
  db.recent[k] = e
  local n, oldest = 0, nil
  for kk, x in pairs(db.recent) do
    n = n + 1
    if not oldest or x.seen < db.recent[oldest].seen then oldest = kk end
  end
  if n > MAX_RECENT then db.recent[oldest] = nil end
  RefreshUI()
end

local function OnUnitTarget(unit)
  if not Enemy(unit) or not (unit == "target" or unit:find("^nameplate")) or not UnitAffectingCombat("player") then return end
  if not open(UnitIsUnit(unit .. "target", "player")) then return end
  local faction = open(UnitFactionGroup(unit))
  if faction == UnitFactionGroup("player") then return end -- duel
  local class, classFile = UnitClass(unit)
  Fought(open(GetUnitName(unit, true)), open(UnitGUID(unit)), false, faction, open(class), open(classFile),
    open(UnitLevel(unit)))
end

-- The combat log is closed on Forever, but the death recap lists who hit us.
local function ReadRecap()
  local ok, has = pcall(C_DeathRecap.HasRecapEvents)
  if not (ok and has) then return false end
  local ok2, events = pcall(C_DeathRecap.GetRecapEvents)
  local done = {}
  for _, ev in ipairs(ok2 and events or {}) do
    local guid = open(ev.sourceGUID)
    if type(guid) == "string" and guid:find("^Player%-") and not done[guid] then
      done[guid] = true
      local class, classFile, _, race, _, name = GetPlayerInfoByGUID(guid)
      local faction = race and RACE_FACTION[race]
      if faction ~= UnitFactionGroup("player") then
        Fought(name or open(ev.sourceName), guid, true, faction, class, classFile)
      end
    end
  end
  return true
end

local function OnDeath()
  if not C_DeathRecap then return end
  local tries = 0
  local function Try()
    tries = tries + 1
    if not ReadRecap() and tries < 4 then C_Timer.After(0.5 * tries, Try) end
  end
  C_Timer.After(0.3, Try)
end

-- Nameplates and tooltips -----------------------------------------------------

-- Own entries added by name get their faction and class once the player is seen.
local function Learn(e, unit)
  if e.author or (e.faction and e.classFile) then return end
  e.faction = e.faction or open(UnitFactionGroup(unit))
  if not e.classFile then
    local class, classFile = UnitClass(unit)
    e.class, e.classFile = open(class), open(classFile)
  end
  ScheduleBroadcast()
  RefreshUI()
end

local function CheckUnit(unit, how)
  if not Enemy(unit) then return end
  local name = open(GetUnitName(unit, true))
  local e = find(UnitGUID(unit), name)
  -- The death recap never tells us a level, so Recent entries learn it here.
  local r = name and db.recent[key(name)]
  if r and Raise(r, open(UnitLevel(unit))) then RefreshUI() end
  if e then
    Learn(e, unit)
    Raise(e, open(UnitLevel(unit)))
    Alert(e, how)
  end
  return e
end

-- /dnf debug: the decisions below, on the chat frame and in the saved variables.
-- Kept in the saved variables too, so a whole run can be read from the file after a /reload.
local function Debug(msg, quiet)
  if not db.debug then return end
  if not quiet then say("|cff888888dbg " .. msg .. "|r") end
  local log = db.log or {}
  db.log = log
  log[#log + 1] = date("%H:%M:%S ") .. msg
  if #log > 500 then table.remove(log, 1) end
end

-- No combat log and health is a secret value here, but UNIT_DIED carries the GUID of whoever
-- just died. So a kill is a listed player dying while we were on them.
-- ponytail: someone else landing the last hit on our target counts as ours; no way to tell.
local ENGAGED, KILL_GAP = 20, 15
local engaged, killed = {}, {}

local function Kill(e, guid)
  local k = key(e.name)
  if GetTime() - (killed[k] or -KILL_GAP) < KILL_GAP then return end
  killed[k], engaged[guid] = GetTime(), nil
  e.slain = (e.slain or 0) + 1
  say(("you killed %s (%d)"):format(e.name, e.slain))
  Announce(("{rt8} Deathnote Forever: %s killed (%d)"):format(e.name, e.slain))
  RefreshUI()
end

local function OnUnitDied(guid)
  guid = open(guid)
  if type(guid) ~= "string" or not guid:find("^Player%-") then return end
  local fought = engaged[guid] and GetTime() - engaged[guid] < ENGAGED
  local e = fought and byGUID[guid]
  Debug(("died %s, fought %s, listed %s"):format(guid, tostring(fought and true or false), tostring(e ~= nil)))
  if e then Kill(e, guid) end
end

-- Who we are on right now, so UNIT_DIED can be pinned on them.
local function CheckKill()
  if not UnitAffectingCombat("player") or UnitIsDeadOrGhost("player") then return end
  local guid = open(UnitGUID("target"))
  if not guid or not Enemy("target") then return end
  local e = find(guid, GetUnitName("target", true))
  if not e then return end
  if not engaged[guid] then Debug("engaged " .. e.name, true) end
  engaged[guid] = GetTime()
end

local function PlateAdded(unit, quiet)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then return end
  local e
  if quiet then
    e = Enemy(unit) and find(UnitGUID(unit), GetUnitName(unit, true)) or nil
    if e then
      Learn(e, unit)
      Raise(e, open(UnitLevel(unit)))
    end
  else
    e = CheckUnit(unit, "nameplate")
  end
  local icon = icons[plate]
  if e and not icon then
    icon = plate:CreateTexture(nil, "OVERLAY")
    icon:SetTexture(SKULL)
    icon:SetSize(32, 32)
    icon:SetPoint("BOTTOM", plate, "TOP", 0, 0)
    icons[plate] = icon
  end
  if icon then icon:SetShown(e ~= nil) end
end

-- Re-apply skulls to plates already on screen, without alerts.
local function RefreshPlates()
  for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
    if plate.namePlateUnitToken then PlateAdded(plate.namePlateUnitToken, true) end
  end
end

local function PlateRemoved(unit)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if plate and icons[plate] then icons[plate]:Hide() end
end

local function TooltipUnit(tooltip)
  local _, unit = tooltip:GetUnit()
  if not Enemy(unit) then return end
  local e = find(UnitGUID(unit), GetUnitName(unit, true))
  if e then
    tooltip:AddLine("Deathnote: " .. e.reason .. (e.author and (" (from " .. e.author .. ")") or ""), 1, 0.2, 0.2)
  end
end

local function ApplyCVars()
  if InCombatLockdown() then return end
  SetCVar("nameplateMaxDistance", 100)
  SetCVar("nameplateShowEnemies", 1)
end

-- List changes ----------------------------------------------------------------

local function Changed(own)
  Rebuild()
  RefreshPlates()
  RefreshUI()
  if own then ScheduleBroadcast() end
end

local function OnComm(msg, sender, channel)
  local author, source = Ambiguate(sender, "none"), Trusted(sender)
  -- UnitName returns only the first name on Forever, where names can have a surname.
  if author == GetUnitName("player", true) or not source then return end
  local f = { strsplit("\t", msg) }
  for i = 2, #f do f[i] = clean(f[i], 250) end -- no escape codes from other clients
  local t, inc = f[1], incoming[author]
  if t == "B" then
    -- The same list can arrive over both GUILD and PARTY; keep collecting into one batch.
    if not (inc and inc.serial == f[2]) then
      incoming[author] = { serial = f[2], n = tonumber(f[3]), entries = {} }
    end
    if f[5] and not warnedVersion and Newer(f[5], VERSION) then
      warnedVersion = true
      say(("%s has a newer Deathnote Forever (%s, you have %s), ask them for it"):format(author, f[5], VERSION))
    end
    if f[4] == "1" and GetTime() - (replied[author] or -30) > 30 then
      replied[author] = GetTime()
      SendList("WHISPER", sender, false)
    end
  elseif t == "E" then
    if inc and inc.serial == f[2] and f[3] and f[3] ~= "" then
      inc.entries[key(f[3])] = { name = f[3], nparts = tonumber(f[4]) or 0, parts = {},
        faction = f[5] ~= "" and f[5] or nil, class = f[6] ~= "" and f[6] or nil, guid = f[7] ~= "" and f[7] or nil,
        classFile = f[8] ~= "" and f[8] or nil, level = tonumber(f[9]) }
    end
  elseif t == "R" then
    local e = inc and inc.serial == f[2] and inc.entries[f[3] or ""]
    local i = tonumber(f[4])
    if e and i then e.parts[i] = f[5] end
  elseif t == "Z" then
    if not (inc and inc.serial == f[2]) then return end
    incoming[author] = nil
    local count = 0
    for _, e in pairs(inc.entries) do
      count = count + 1
      for i = 1, e.nparts do
        if not e.parts[i] then return end -- lost messages: wait for the next sync
      end
      e.reason = e.nparts > 0 and table.concat(e.parts) or "no reason"
      e.parts, e.nparts = nil, nil
    end
    if count ~= inc.n then return end
    local old = db.shared[author]
    for k, e in pairs(inc.entries) do
      local o = old and old.entries[k]
      if o then
        e.seen, e.seenZone, e.seenMap, e.seenX, e.seenY = o.seen, o.seenZone, o.seenMap, o.seenX, o.seenY
        e.history, e.slain, e.deaths = o.history, o.slain, o.deaths
        Raise(e, o.level)
      end
    end
    db.shared[author] = count > 0 and { updated = time(), entries = inc.entries, source = source } or nil
    Changed(false)
  elseif t == "S" then
    OnSighting(author, f, channel)
  end
end

-- Add or update an own entry. With unit, name/guid/faction/class come from that unit.
local function Put(name, reason, unit)
  if unit and UnitIsFriend("player", unit) then return say("enemy faction players only for now") end
  if unit then name = GetUnitName(unit, true) end
  local k = key(name)
  local e = db.players[k] or { name = name, added = time() }
  e.reason = (reason and reason ~= "") and reason or "no reason"
  if unit then
    e.name, e.guid, e.faction = name, UnitGUID(unit), UnitFactionGroup(unit)
    e.class, e.classFile = UnitClass(unit)
    Raise(e, open(UnitLevel(unit)))
  end
  db.players[k] = e
  say(("saved %s (%s)"):format(e.name, e.reason))
  Changed(true)
end

local function Remove(name)
  local e = name and db.players[key(name)]
  if not e then return say("not on your list: " .. tostring(name)) end
  db.players[key(name)] = nil
  say("removed " .. e.name)
  Changed(true)
end

local function Adopt(e)
  local k = key(e.name)
  Put(e.name, ("%s in %s"):format(e.kills > 0 and "killed me" or "attacked me", e.seenZone or "?"))
  local p = db.players[k]
  p.guid, p.faction, p.class, p.classFile = e.guid, e.faction, e.class, e.classFile
  p.seen, p.seenZone, p.seenMap, p.seenX, p.seenY = e.seen, e.seenZone, e.seenMap, e.seenX, e.seenY
  Raise(p, e.level)
  Log(p)
  db.recent[k] = nil
  Changed(true)
end

local function HideShared(e)
  db.hidden[e.author .. "|" .. key(e.name)] = true
  say(("hidden %s (from %s)"):format(e.name, e.author))
  Changed(false)
end

-- Panel -----------------------------------------------------------------------

local ISSUES_URL = "https://github.com/JakubGrzegowski/Deathnote/issues"
local TABS = { { "mine", "Mine", "My entries" }, { "party", "Party", "From my party" },
  { "guild", "Guild", "From my guild" }, { "all", "All" }, { "recent", "Recent" } }

local function SetClass(e, classFile)
  e.classFile = classFile
  e.class = classFile and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile] or classFile) or nil
end

local function FitsFaction(classFile, faction)
  return not (faction and CLASS_FACTION[classFile] and CLASS_FACTION[classFile] ~= faction)
end

local function ChooseFaction(e, faction)
  e.faction = faction
  if e.classFile and not FitsFaction(e.classFile, faction) then SetClass(e, nil) end
  Changed(true)
end

local function ChooseClass(e, classFile)
  SetClass(e, classFile)
  Changed(true)
end

local function SetIcon(tex, file, coords)
  tex:SetTexture(file or UNKNOWN_ICON)
  if coords then tex:SetTexCoord(unpack(coords)) else tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
end

-- Options are { value, label, icon, coords }; value false means unknown.
local function FactionOptions()
  local o = { { value = false, label = "Unknown" } }
  for _, f in ipairs(FACTIONS) do o[#o + 1] = { value = f, label = f, icon = FACTION_ICON[f] } end
  return o
end

local function ClassOptions(faction)
  local o = { { value = false, label = "Unknown" } }
  for _, c in ipairs(CLASSES) do
    if FitsFaction(c, faction) then
      local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[c] or c
      local color = RAID_CLASS_COLORS[c]
      local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[c]
      o[#o + 1] = { value = c, label = color and color.colorStr and ("|c" .. color.colorStr .. name .. "|r") or name,
        icon = coords and CLASS_ICONS, coords = coords }
    end
  end
  return o
end

-- Drop-down list under the clicked icon; a click anywhere else closes it.
local picker
local function HidePicker()
  if picker then
    picker:Hide()
    picker.catcher:Hide()
  end
end

local function ShowPicker(anchor, options, current, onPick)
  if not picker then
    picker = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    picker:SetFrameStrata("FULLSCREEN_DIALOG")
    picker:SetClampedToScreen(true)
    picker:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    picker:SetBackdropColor(0, 0, 0, 0.95)
    picker.catcher = CreateFrame("Button", nil, UIParent)
    picker.catcher:SetAllPoints(UIParent)
    picker.catcher:SetFrameStrata("FULLSCREEN")
    picker.catcher:RegisterForClicks("AnyUp")
    picker.catcher:SetScript("OnClick", HidePicker)
    picker.rows = {}
  end
  for i, o in ipairs(options) do
    local b = picker.rows[i]
    if not b then
      b = CreateFrame("Button", nil, picker)
      b:SetSize(140, 18)
      b:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 18)
      b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      b.icon = b:CreateTexture(nil, "ARTWORK")
      b.icon:SetSize(16, 16)
      b.icon:SetPoint("LEFT")
      b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      b.text:SetPoint("LEFT", 22, 0)
      b.check = b:CreateTexture(nil, "OVERLAY")
      b.check:SetSize(14, 14)
      b.check:SetPoint("RIGHT")
      b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
      picker.rows[i] = b
    end
    SetIcon(b.icon, o.icon, o.coords)
    b.text:SetText(o.label)
    b.check:SetShown(o.value == (current or false))
    b:SetScript("OnClick", function()
      HidePicker()
      onPick(o.value or nil)
    end)
    b:Show()
  end
  for i = #options + 1, #picker.rows do picker.rows[i]:Hide() end
  picker:SetSize(156, 16 + #options * 18)
  picker:ClearAllPoints()
  picker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  picker.catcher:Show()
  picker:Show()
end

local function SuggestReason(e)
  local function n(c) return c > 1 and (" (" .. c .. "x)") or "" end
  return e.kills > 0 and ("killed you" .. n(e.kills)) or ("attacked you" .. n(e.fights))
end

local SORTS = {
  name = function(e) return e.name:lower() end,
  level = function(e) return e.level or 0 end,
  slain = function(e) return e.slain or 0 end,
  deaths = function(e) return e.deaths or e.kills or 0 end,
  reason = function(e) return (e.reason or ""):lower() end,
  zone = function(e) return (e.seenZone or ""):lower() end,
  seen = function(e) return e.seen or 0 end,
}

local function Before(a, b)
  local f = SORTS[db.sortBy] or SORTS.seen
  local x, y = f(a), f(b)
  if x == y then return a.name:lower() < b.name:lower() end
  if db.sortDesc then return x > y end
  return x < y
end

local DESC = { seen = true, level = true, slain = true, deaths = true }
local function Tally(n) return (n and n > 0) and tostring(n) or "" end

local function Ago(t)
  if not t then return "never" end
  local s = time() - t
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  if s < 86400 then return math.floor(s / 3600) .. "h ago" end
  return math.floor(s / 86400) .. "d ago"
end

local function Entries(tab)
  local list = {}
  if tab == "recent" then
    for k, e in pairs(db.recent) do
      if not db.players[k] then
        e.reason = SuggestReason(e)
        list[#list + 1] = e
      end
    end
    table.sort(list, Before)
    return list
  elseif tab == "mine" then
    for _, e in pairs(db.players) do list[#list + 1] = e end
  else
    for author, l in pairs(db.shared) do
      if SourceOf(author, l) == tab then
        for k, e in pairs(l.entries) do
          if not db.players[k] and not db.hidden[author .. "|" .. k] then list[#list + 1] = e end
        end
      end
    end
  end
  table.sort(list, Before)
  return list
end

-- The All tab: every other tab in its own section, each under a header row.
local function TabRows(tab)
  if tab ~= "all" then return Entries(tab) end
  local out = {}
  for _, t in ipairs(TABS) do
    local list = t[3] and Entries(t[1]) or {}
    if #list > 0 then
      out[#out + 1] = { header = t[3] }
      for _, e in ipairs(list) do out[#out + 1] = e end
    end
  end
  return out
end

StaticPopupDialogs.DEATHNOTEFOREVER_ISSUES = {
  text = "Report a bug or suggest a feature on GitHub.\nCopy the link (Ctrl+C) and open it in your browser:",
  button1 = OKAY,
  hasEditBox = true,
  editBoxWidth = 300,
  OnShow = function(self)
    local box = self.editBox or self.EditBox
    box:SetText(ISSUES_URL)
    box:HighlightText()
    box:SetFocus()
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

local GOLD = { 0.82, 0.65, 0.32 }

local function BuildUI()
  local W, H, ROWH, NAV, DETAIL = 1040, 470, 20, 128, 280
  ui = CreateFrame("Frame", "DeathnoteForeverFrame", UIParent, "BasicFrameTemplateWithInset")
  ui:SetSize(W, H)
  ui:SetPoint("CENTER")
  ui:SetFrameStrata("DIALOG")
  ui:SetMovable(true)
  ui:SetClampedToScreen(true)
  ui:EnableMouse(true)
  ui:RegisterForDrag("LeftButton")
  ui:SetScript("OnDragStart", ui.StartMoving)
  ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
  tinsert(UISpecialFrames, "DeathnoteForeverFrame")
  local title = ui.TitleText or ui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("Deathnote Forever v" .. VERSION)

  -- Dark panels separated by thin gold rules.
  local function Panel(x1, y1, x2, y2)
    local p = CreateFrame("Frame", nil, ui)
    p:SetPoint("TOPLEFT", x1, y1)
    p:SetPoint("BOTTOMRIGHT", x2, y2)
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.4)
    return p
  end
  local function Rule(parent, y)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetHeight(1)
    t:SetPoint("TOPLEFT", 8, y)
    t:SetPoint("TOPRIGHT", -8, y)
    t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.5)
    return t
  end
  local function Heading(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    return fs
  end
  local function Label(text, x, y)
    local fs = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
  end

  Label("Name", 20, -32)
  local nameBox = CreateFrame("EditBox", nil, ui, "InputBoxTemplate")
  nameBox:SetSize(130, 20)
  nameBox:SetPoint("TOPLEFT", 22, -46)
  nameBox:SetAutoFocus(false)
  -- An empty box adds the current target, so show whose name would be taken.
  local hint = nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", 2, 0)
  hint:SetPoint("RIGHT", -2, 0)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(false)
  local function ShowHint()
    local target = UnitIsPlayer("target") and open(GetUnitName("target", true))
    hint:SetText(target and ("your target: " .. target) or "name or target")
    hint:SetShown(nameBox:GetText() == "")
  end
  nameBox:SetScript("OnTextChanged", ShowHint)

  Label("Reason", 166, -32)
  local reasonBox = CreateFrame("EditBox", nil, ui, "InputBoxTemplate")
  reasonBox:SetSize(220, 20)
  reasonBox:SetPoint("TOPLEFT", 168, -46)
  reasonBox:SetAutoFocus(false)
  reasonBox:SetMaxLetters(MAX_REASON)

  local function DoAdd()
    ui.tab = "mine"
    local name = strtrim(nameBox:GetText())
    if name ~= "" then
      Put(name, strtrim(reasonBox:GetText()))
    elseif UnitIsPlayer("target") then
      Put(nil, strtrim(reasonBox:GetText()), "target")
    else
      return say("type a name or target a player")
    end
    nameBox:SetText("")
    reasonBox:SetText("")
    nameBox:ClearFocus()
    reasonBox:ClearFocus()
  end
  nameBox:SetScript("OnEnterPressed", DoAdd)
  reasonBox:SetScript("OnEnterPressed", DoAdd)
  nameBox:SetScript("OnTabPressed", function() reasonBox:SetFocus() end)
  reasonBox:SetScript("OnTabPressed", function() nameBox:SetFocus() end)

  local addBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  addBtn:SetSize(80, 22)
  addBtn:SetPoint("TOPLEFT", 398, -45)
  addBtn:SetText("Add")
  addBtn:SetScript("OnClick", DoAdd)
  addBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Leave the name empty to add the player you have targeted")
    GameTooltip:Show()
  end)
  addBtn:SetScript("OnLeave", GameTooltip_Hide)

  -- Three panels: tabs down the left, the list in the middle, the selected player on the right.
  local nav = Panel(12, -74, 12 + NAV - W, 40)
  local list = Panel(12 + NAV + 8, -74, -(DETAIL + 20), 40)
  local detail = Panel(W - DETAIL - 12, -74, -12, 40)
  local panel = Panel(12 + NAV + 8, -74, -12, 40)

  ui.tab = "mine"
  local function NavButton(i, label, onClick)
    local b = CreateFrame("Button", nil, nav)
    b:SetSize(NAV - 12, 22)
    b:SetPoint("TOPLEFT", 6, -8 - (i - 1) * 24)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.25)
    b.sel:Hide()
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetText(label)
    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.count:SetPoint("RIGHT", -8, 0)
    b:SetScript("OnClick", onClick)
    return b
  end
  local tabs = {}
  for i, t in ipairs(TABS) do
    tabs[i] = NavButton(i, t[2], function()
      ui.tab = t[1]
      ui.Refresh()
    end)
  end
  Rule(nav, -12 - #TABS * 24)
  local settingsBtn = NavButton(#TABS + 1.5, "Settings", function()
    ui.tab = "settings"
    ui.Refresh()
  end)

  local announce = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  announce:SetPoint("TOPLEFT", 8, -8)
  announce:SetScript("OnClick", function(self) db.announce = self:GetChecked() and true or false end)
  local announceText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  announceText:SetPoint("LEFT", announce, "RIGHT", 4, 0)
  announceText:SetText("Announce sightings and kills in party chat")

  -- Column headers: a click sorts by that column, a second click reverses it.
  local COLUMNS = { { "name", "Name", 42, 110 }, { "level", "Lvl", 158, 26, "CENTER" },
    { "slain", "Kills", 190, 30, "CENTER" }, { "deaths", "Deaths", 226, 34, "CENTER" },
    { "reason", "Reason", 270, 190 }, { "seen", "Seen", 466, 50 } }
  local headers = {}
  for i, c in ipairs(COLUMNS) do
    local b = CreateFrame("Button", nil, list)
    b:SetSize(c[4], 16)
    b:SetPoint("TOPLEFT", c[3] + 4, -6)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint(c[5] or "LEFT")
    b.text:SetText(c[2])
    b.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    b.arrow = b:CreateTexture(nil, "OVERLAY")
    b.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    b.arrow:SetSize(9, 8)
    b.arrow:SetPoint("LEFT", b.text, "RIGHT", 3, 0)
    b:SetScript("OnClick", function()
      if db.sortBy == c[1] then
        db.sortDesc = not db.sortDesc
      else
        db.sortBy, db.sortDesc = c[1], DESC[c[1]] or false
      end
      ui.Refresh()
    end)
    headers[i] = b
  end
  Rule(list, -24)

  local sf = CreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 4, -28)
  sf:SetPoint("BOTTOMRIGHT", -26, 4)
  local content = CreateFrame("Frame", nil, sf)
  local ROWW = W - DETAIL - 20 - (12 + NAV + 8) - 30
  content:SetSize(ROWW, 1)
  sf:SetScrollChild(content)

  local rows = {}
  local function Cell(row, x, width, font, justify)
    local fs = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("LEFT", x, 0)
    fs:SetWidth(width)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  local function NewRow(i)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(ROWW, ROWH)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROWH)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.18)
    row.sel:Hide()
    -- A class coloured strip on the left edge of every row.
    row.strip = row:CreateTexture(nil, "ARTWORK")
    row.strip:SetSize(2, ROWH - 4)
    row.strip:SetPoint("LEFT", 0, 0)

    -- Faction and class icons; on own entries a click opens a list to choose from.
    local function IconButton(x, label, show, current, options, choose)
      local b = CreateFrame("Button", nil, row)
      b:SetSize(16, 16)
      b:SetPoint("LEFT", x, 0)
      b.tex = b:CreateTexture(nil, "ARTWORK")
      b.tex:SetAllPoints()
      b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
      b:SetScript("OnClick", function(self)
        local e = row.e
        if e.author or e.suggest then return end
        GameTooltip:Hide()
        ShowPicker(self, options(e), current(e), function(v) choose(e, v) end)
      end)
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(label .. ": " .. (show(row.e) or "unknown"))
        if not (row.e.author or row.e.suggest) then GameTooltip:AddLine("Click to choose", 0.4, 0.8, 0.4) end
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", GameTooltip_Hide)
      return b
    end
    local function Faction(e) return e.faction end
    row.faction = IconButton(6, "Faction", Faction, Faction, FactionOptions, ChooseFaction)
    row.class = IconButton(24, "Class", function(e) return e.class end, function(e) return e.classFile end,
      function(e) return ClassOptions(e.faction) end, ChooseClass)
    row.name = Cell(row, 42, 110)
    row.level = Cell(row, 158, 26, nil, "CENTER")
    row.slain = Cell(row, 190, 30, nil, "CENTER")
    row.deaths = Cell(row, 226, 34, nil, "CENTER")

    -- Own reasons are edited in place: Enter or clicking away saves, Escape reverts.
    local reason = CreateFrame("EditBox", nil, row)
    reason:SetSize(190, ROWH)
    reason:SetPoint("LEFT", 270, 0)
    reason:SetAutoFocus(false)
    reason:SetMaxLetters(MAX_REASON)
    reason:SetFontObject("GameFontHighlightSmall")
    -- The box takes the mouse over the reason, so it shows the row tooltip (full reason) itself.
    reason:SetScript("OnEnter", function() row:GetScript("OnEnter")(row) end)
    reason:SetScript("OnLeave", GameTooltip_Hide)
    local underline = reason:CreateTexture(nil, "BACKGROUND")
    underline:SetColorTexture(1, 0.82, 0, 0.7)
    underline:SetHeight(1)
    underline:SetPoint("BOTTOMLEFT", 0, 2)
    underline:SetPoint("BOTTOMRIGHT", 0, 2)
    underline:Hide()
    reason:SetScript("OnEditFocusGained", function(self)
      self.entry = row.e
      underline:Show()
    end)
    reason:SetScript("OnEditFocusLost", function(self)
      underline:Hide()
      local e, text = self.entry, strtrim(self:GetText())
      self.entry = nil
      if e then
        text = text ~= "" and text or "no reason"
        local changed = text ~= e.reason
        e.reason = text
        Changed(changed)
      end
    end)
    reason:SetScript("OnEnterPressed", reason.ClearFocus)
    reason:SetScript("OnEscapePressed", function(self)
      self:SetText(self.entry and self.entry.reason or "")
      self:ClearFocus()
    end)
    row.reason = reason
    row.when = Cell(row, 466, 50, "GameFontDisableSmall")

    local del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    del:SetSize(20, 18)
    del:SetPoint("RIGHT", -2, 0)
    del:SetText("X")
    del:SetScript("OnClick", function()
      local e = row.e
      if e.suggest then
        db.recent[key(e.name)] = nil
        RefreshUI()
      elseif e.author then HideShared(e) else Remove(e.name) end
    end)
    row.add = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.add:SetSize(20, 18)
    row.add:SetPoint("RIGHT", del, "LEFT", -2, 0)
    row.add:SetText("+")
    row.add:SetScript("OnClick", function() Adopt(row.e) end)
    row.title = Cell(row, 4, 300, "GameFontNormal")
    row.parts = { row.faction, row.class, row.name, row.level, row.slain, row.deaths, row.reason, row.when,
      row.strip, del }
    row:SetScript("OnClick", function(self)
      ui.sel = self.e
      ui.Refresh()
    end)

    row:SetScript("OnEnter", function(self)
      local e = self.e
      GameTooltip:SetOwner(self, "ANCHOR_LEFT") -- the profile panel sits on the right
      GameTooltip:AddLine(e.name)
      GameTooltip:AddLine(e.reason, 1, 0.2, 0.2, true)
      GameTooltip:AddLine((e.level and ("Level " .. e.level .. " ") or "") .. (e.faction or "faction unknown")
        .. (e.class and (" " .. e.class) or ""), 0.8, 0.8, 0.8)
      if e.slain then GameTooltip:AddLine(("Killed by you %d time(s)"):format(e.slain), 0.4, 1, 0.4) end
      local deaths = e.deaths or e.kills
      if deaths and deaths > 0 then GameTooltip:AddLine(("Killed you %d time(s)"):format(deaths), 1, 0.4, 0.4) end
      if e.author then GameTooltip:AddLine("Written by " .. e.author, 0.6, 0.6, 1) end
      if e.suggest then
        GameTooltip:AddLine("Last fight " .. date("%Y-%m-%d %H:%M", e.seen) .. " " .. (e.seenZone or ""), 0.6, 0.6, 0.6)
        GameTooltip:AddLine("+ adds to your list, X dismisses", 0.4, 0.8, 0.4)
        GameTooltip:Show()
        return
      end
      if e.added then GameTooltip:AddLine("Added " .. date("%Y-%m-%d %H:%M", e.added), 0.6, 0.6, 0.6) end
      if e.seen then
        GameTooltip:AddLine("Last seen " .. date("%Y-%m-%d %H:%M", e.seen) .. " " .. (e.seenZone or "") .. " " .. Coords(e), 0.6, 0.6, 0.6)
      end
      if e.author then
        GameTooltip:AddLine("X hides this entry for you only", 0.4, 0.8, 0.4)
      else
        GameTooltip:AddLine("Click the reason to edit it", 0.4, 0.8, 0.4)
      end
      GameTooltip:AddLine("Click the row to open the profile", 0.4, 0.8, 0.4)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    rows[i] = row
    return row
  end

  -- The right hand panel: who is selected, the two tallies and every sighting of them.
  local dName = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  dName:SetPoint("TOPLEFT", 12, -12)
  dName:SetWidth(DETAIL - 24)
  dName:SetJustifyH("LEFT")
  dName:SetWordWrap(false)
  local dSub = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dSub:SetPoint("TOPLEFT", 12, -36)
  dSub:SetWidth(DETAIL - 24)
  dSub:SetJustifyH("LEFT")
  dSub:SetTextColor(0.8, 0.8, 0.8)

  local TILES = { "KILLS", "DEATHS", "LAST SEEN" }
  local tiles = {}
  for i, cap in ipairs(TILES) do
    local t = CreateFrame("Frame", nil, detail)
    t:SetSize(84, 40)
    t:SetPoint("TOPLEFT", 10 + (i - 1) * 88, -56)
    local bg = t:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)
    local label = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOP", 0, -5)
    label:SetText(cap)
    label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    t.value = t:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t.value:SetPoint("TOP", label, "BOTTOM", 0, -3)
    tiles[i] = t
  end

  local dReason = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dReason:SetPoint("TOPLEFT", 12, -104)
  dReason:SetWidth(DETAIL - 24)
  dReason:SetHeight(40)
  dReason:SetJustifyH("LEFT")
  dReason:SetJustifyV("TOP")
  local dMeta = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  dMeta:SetPoint("TOPLEFT", 12, -148)
  dMeta:SetWidth(DETAIL - 24)
  dMeta:SetJustifyH("LEFT")

  local dRule = Rule(detail, -184)
  local dHead = Heading(detail, "Sightings, newest first", 12, -196)
  local dsf = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
  dsf:SetPoint("TOPLEFT", 8, -212)
  dsf:SetPoint("BOTTOMRIGHT", -26, 8)
  local dContent = CreateFrame("Frame", nil, dsf)
  dContent:SetSize(DETAIL - 40, 1)
  dsf:SetScrollChild(dContent)
  local dEmpty = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  dEmpty:SetPoint("CENTER")
  dEmpty:SetText("Click a player on the list")
  local dParts = { dName, dSub, dReason, dMeta, dRule, dHead, dsf, tiles[1], tiles[2], tiles[3] }
  local dRows = {}

  local function ShowDetail(e)
    for _, part in ipairs(dParts) do part:SetShown(e ~= nil) end
    dEmpty:SetShown(e == nil)
    if not e then return end
    local color = e.classFile and RAID_CLASS_COLORS[e.classFile]
    dName:SetText((color and color.colorStr and ("|c" .. color.colorStr) or "|cffffffff") .. e.name .. "|r")
    dSub:SetText(("Level %s %s %s"):format(e.level or "?", e.faction or "faction unknown",
      e.class or "class unknown"))
    tiles[1].value:SetText(e.slain or 0)
    tiles[2].value:SetText(e.deaths or e.kills or 0)
    tiles[3].value:SetText(Ago(e.seen))
    dReason:SetText("|cffff5555" .. (e.reason or "") .. "|r")
    local meta = {}
    if e.author then meta[#meta + 1] = "Written by " .. e.author end
    if e.added then meta[#meta + 1] = "Added " .. date("%Y-%m-%d", e.added) end
    if e.seenZone then meta[#meta + 1] = "Last seen in " .. e.seenZone end
    dMeta:SetText(table.concat(meta, "\n"))
    local h = e.history or {}
    for i = 1, #h do
      local r = h[#h + 1 - i]
      local row = dRows[i]
      if not row then
        row = CreateFrame("Button", nil, dContent)
        row:SetSize(DETAIL - 40, 16)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 16)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", -4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnClick", function(self) Waypoint(self.w) end)
        row:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_LEFT")
          GameTooltip:AddLine(self.w.seenZone or "?")
          GameTooltip:AddLine(Coords(self.w), 0.8, 0.8, 0.8)
          GameTooltip:AddLine("Click to set a waypoint", 0.4, 0.8, 0.4)
          GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        dRows[i] = row
      end
      row.w = { name = e.name, seenZone = r.seenZone, seenMap = r.seenMap, seenX = r.seenX, seenY = r.seenY }
      row.text:SetText(("%s  %s%s"):format(date("%m-%d %H:%M", r.seen), r.seenZone or "?",
        r.by and ("  |cff8888ff" .. r.by .. "|r") or ""))
      row:Show()
    end
    for i = #h + 1, #dRows do dRows[i]:Hide() end
    dContent:SetHeight(math.max(1, #h * 16))
    dHead:SetText(#h > 0 and "Sightings, newest first" or "Not seen yet")
  end

  local count = ui:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  count:SetPoint("BOTTOMLEFT", 20, 18)

  local unhide = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  unhide:SetSize(110, 22)
  unhide:SetPoint("BOTTOMLEFT", 140, 12)
  unhide:SetScript("OnClick", function()
    wipe(db.hidden)
    Changed(false)
  end)

  local testBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  testBtn:SetSize(90, 22)
  testBtn:SetPoint("BOTTOMRIGHT", -14, 12)
  testBtn:SetText("Test alert")
  testBtn:SetScript("OnClick", function()
    lastAlert.test = nil
    Alert({ name = "Test", reason = "alert test" }, "test")
  end)

  local issuesBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  issuesBtn:SetSize(110, 22)
  issuesBtn:SetPoint("RIGHT", testBtn, "LEFT", -6, 0)
  issuesBtn:SetText("Report a bug")
  issuesBtn:SetScript("OnClick", function() StaticPopup_Show("DEATHNOTEFOREVER_ISSUES") end)

  ui:HookScript("OnHide", HidePicker)

  function ui.Refresh()
    local total = 0
    for i, t in ipairs(TABS) do
      local n = t[1] == "all" and total or #Entries(t[1])
      total = total + (t[3] and n or 0)
      tabs[i].count:SetText(n)
      tabs[i].sel:SetShown(ui.tab == t[1])
    end
    local settings = ui.tab == "settings"
    settingsBtn.sel:SetShown(settings)
    list:SetShown(not settings)
    detail:SetShown(not settings)
    panel:SetShown(settings)
    count:SetShown(not settings)
    for i, c in ipairs(COLUMNS) do
      local h = headers[i]
      h.arrow:SetShown(db.sortBy == c[1])
      if db.sortDesc then h.arrow:SetTexCoord(0, 0.5625, 0, 1) else h.arrow:SetTexCoord(0, 0.5625, 1, 0) end
    end
    if settings then
      announce:SetChecked(db.announce)
      unhide:Hide()
      return
    end
    local rowList, shown = TabRows(ui.tab), 0
    for i, e in ipairs(rowList) do
      local row = rows[i] or NewRow(i)
      local header = e.header ~= nil
      row.e = not header and e or nil
      row.title:SetShown(header)
      row:EnableMouse(not header)
      for _, part in ipairs(row.parts) do part:SetShown(not header) end
      row.add:SetShown(not header and e.suggest == true)
      row.sel:SetShown(not header and ui.sel == e)
      if header then
        row.title:SetText(e.header)
      else
        shown = shown + 1
        SetIcon(row.faction.tex, FACTION_ICON[e.faction])
        local coords = e.classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.classFile]
        SetIcon(row.class.tex, coords and CLASS_ICONS, coords)
        local color = e.classFile and RAID_CLASS_COLORS[e.classFile]
        row.strip:SetColorTexture(color and color.r or 0.6, color and color.g or 0.6, color and color.b or 0.6, 0.9)
        row.name:SetText((color and color.colorStr and ("|c" .. color.colorStr) or "|cffffffff") .. e.name .. "|r")
        if not row.reason:HasFocus() then
          row.reason:SetText(e.author and ("|cff8888ff" .. e.author .. ":|r " .. e.reason) or e.reason)
          row.reason:SetCursorPosition(0) -- an edit box scrolls to the cursor, so start at the front
        end
        row.reason:EnableMouse(not (e.author or e.suggest))
        row.level:SetText(e.level or "")
        row.slain:SetText(Tally(e.slain))
        row.deaths:SetText(Tally(e.deaths or e.kills))
        row.when:SetText(Ago(e.seen))
      end
      row:Show()
    end
    for i = #rowList + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #rowList * ROWH))
    count:SetText(shown .. " on this tab")
    ShowHint()
    local hidden = 0
    for _ in pairs(db.hidden) do hidden = hidden + 1 end
    unhide:SetText("Unhide (" .. hidden .. ")")
    unhide:SetShown(hidden > 0)
    ShowDetail(ui.sel)
  end
  ui:SetScript("OnShow", ui.Refresh)
end

local function ToggleUI()
  if not ui then BuildUI(); ui.Refresh(); return end
  ui:SetShown(not ui:IsShown())
end

-- Minimap button: click toggles the panel, drag moves it around the minimap edge.
local function MinimapButton()
  local b = CreateFrame("Button", "DeathnoteForeverMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(SKULL)
  icon:SetSize(18, 18)
  icon:SetPoint("TOPLEFT", 7, -6)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  local function Place()
    local a, r = math.rad(db.minimapAngle or 200), Minimap:GetWidth() / 2 + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
  end
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnClick", ToggleUI)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local s = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      db.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
      Place()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Deathnote Forever v" .. VERSION)
    GameTooltip:AddLine("Click: open the list", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  Place()
end

SLASH_DEATHNOTEFOREVER1 = "/deathnote"
SLASH_DEATHNOTEFOREVER2 = "/dnf"
SlashCmdList.DEATHNOTEFOREVER = function(msg)
  local cmd, rest = msg:match("^(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "add" then
    if UnitIsPlayer("target") then return Put(nil, rest, "target") end
    local name, reason = rest:match("^(%S+)%s*(.*)$")
    if not name then return say("target a player or give a name: /deathnote add Name reason") end
    Put(name, reason)
  elseif cmd == "del" then
    Remove(rest ~= "" and rest or (UnitIsPlayer("target") and GetUnitName("target", true)) or nil)
  elseif cmd == "debug" then
    db.debug = not db.debug
    db.log = db.debug and {} or nil
    say("debug " .. (db.debug and "on, logging to the saved variables" or "off"))
  elseif cmd == "way" then
    Waypoint(lastSighting)
  else
    ToggleUI()
  end
end

local wasInGroup
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("ADDON_ACTION_FORBIDDEN")
f:RegisterEvent("ADDON_ACTION_BLOCKED")
f:SetScript("OnEvent", function(self, event, arg, arg2, arg3, arg4)
  if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
    if arg == ADDON then say(event .. ": " .. tostring(arg2) .. (InCombatLockdown() and " (in combat)" or "")) end
  elseif event == "ADDON_LOADED" then
    if arg ~= ADDON then return end
    DeathnoteForeverDB = DeathnoteForeverDB or {}
    db = DeathnoteForeverDB
    db.hideFriendly = nil
    db.players = db.players or {}
    db.shared = db.shared or {}
    db.hidden = db.hidden or {}
    db.recent = db.recent or {}
    if db.announce == nil then db.announce = true end
    if not db.sortBy then db.sortBy, db.sortDesc = "seen", true end
    local lists = { db.players }
    for _, l in pairs(db.shared) do lists[#lists + 1] = l.entries end
    for _, l in ipairs(lists) do
      for _, e in pairs(l) do if e.seen and not e.history then Log(e) end end -- sightings before 2.2.0
    end
    Rebuild()
    MinimapButton()
    C_ChatInfo.RegisterAddonMessagePrefix(COMM)
    C_Timer.NewTicker(0.3, function() Pump(); CheckKill() end)
    if TooltipDataProcessor then
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, TooltipUnit)
    else
      GameTooltip:HookScript("OnTooltipSetUnit", TooltipUnit)
    end
    for _, ev in ipairs({ "PLAYER_LOGIN", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
      "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED", "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE",
      "UNIT_TARGET", "PLAYER_DEAD", "UNIT_DIED" }) do
      self:RegisterEvent(ev)
    end
  elseif event == "PLAYER_LOGIN" then
    db.shared[GetUnitName("player", true)] = nil -- own list echoed back before 2.1.0
    Rebuild()
    ApplyCVars()
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    wasInGroup = IsInGroup()
    -- Wait for the guild roster before trusting replies.
    C_Timer.After(10, function() Broadcast(true) end)
  elseif event == "GROUP_ROSTER_UPDATE" then
    local now = IsInGroup()
    if now and not wasInGroup then
      C_Timer.After(3, function()
        local g = GroupChannel()
        if g then SendList(g, nil, true) end
      end)
    end
    wasInGroup = now
  elseif event == "CHAT_MSG_ADDON" then
    if arg == COMM then OnComm(arg2, arg4, arg3) end
  elseif event == "NAME_PLATE_UNIT_ADDED" then PlateAdded(arg)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then PlateRemoved(arg)
  elseif event == "UPDATE_MOUSEOVER_UNIT" then CheckUnit("mouseover", "mouseover")
  elseif event == "PLAYER_TARGET_CHANGED" then
    CheckUnit("target", "target")
    RefreshUI() -- the add box shows the target's name
  elseif event == "UNIT_TARGET" then OnUnitTarget(arg)
  elseif event == "UNIT_DIED" then OnUnitDied(arg)
  elseif event == "PLAYER_DEAD" then OnDeath()
  end
end)
