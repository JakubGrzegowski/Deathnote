-- Deathnote: warns when a listed player shows up.
-- Enemy faction only for now. Detection: enemy nameplates, mouseover, target.
-- The Forever client forbids addons from registering COMBAT_LOG_EVENT_UNFILTERED.
-- Sharing: own entries are synced to guild and group members running Deathnote,
-- and sightings are reported to them. Entries received from others are never re-shared.
local ADDON = ...
local PREFIX = "|cffff3333Deathnote|r: "
local COMM = "Deathnote"
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
local MAX_REASON = 500
local REALERT = 60
local SHARED_TTL = 30 * 24 * 3600
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"

local db, ui, lastSighting
local byKey, byGUID, lastAlert, icons = {}, {}, {}, {}

local function key(name) return name and (strsplit("-", name)):lower() end
local function say(msg) print(PREFIX .. msg) end
local function RefreshUI() if ui and ui:IsShown() then ui.Refresh() end end

-- Visible entries: own first, then those received from others unless hidden.
local function Rebuild()
  wipe(byKey)
  wipe(byGUID)
  for k, e in pairs(db.players) do byKey[k] = e end
  for author, list in pairs(db.shared) do
    for k, e in pairs(list.entries) do
      if not byKey[k] and not db.hidden[author .. "|" .. k] then
        e.author = author
        byKey[k] = e
      end
    end
  end
  for _, e in pairs(byKey) do if e.guid then byGUID[e.guid] = e end end
end

local function find(guid, name)
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
  local title = "Death Note: " .. e.name
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
    Send(table.concat({ "E", s, name, #parts, clean(e.faction, 10), clean(e.class, 20), clean(e.guid, 40) }, "\t"),
      channel, target)
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
    e.seenMap or "", e.seenMap and ("%.4f"):format(e.seenX) or "", e.seenMap and ("%.4f"):format(e.seenY) or "" }, "\t")
  if IsInGuild() then Send(msg, "GUILD") end
  local g = GroupChannel()
  if g then Send(msg, g) end
end

-- Only guild and group members may write into our lists (whispers included).
local function Trusted(sender)
  local short = Ambiguate(sender, "none")
  if UnitInParty(short) or UnitInRaid(short) then return true end
  for i = 1, GetNumGuildMembers() do
    local n = GetGuildRosterInfo(i)
    if n and Ambiguate(n, "none") == short then return true end
  end
end

-- Alerts ----------------------------------------------------------------------

local function Notify(msg, sound)
  RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo.RAID_WARNING)
  PlaySound(sound, "Master")
end

local function Alert(e, how)
  local k, now = key(e.name), GetTime()
  if now - (lastAlert[k] or -REALERT) < REALERT then return end
  lastAlert[k] = now
  e.seen, e.seenZone = time(), GetRealZoneText()
  -- Our own position: the enemy's is not readable, but nameplates only show within ~20 yd.
  local map = C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  if x and x > 0 then e.seenMap, e.seenX, e.seenY = map, x, y else e.seenMap, e.seenX, e.seenY = nil end
  local msg = ("PERSONA NON GRATA: %s (%s)"):format(e.name, e.reason)
  Notify(msg, SOUNDKIT.RAID_WARNING)
  say(msg .. (e.author and (" |cff888888from " .. e.author .. "|r") or "") .. " |cff888888[" .. how .. "]|r")
  if how ~= "test" then SendSighting(e) end
  RefreshUI()
end

local function OnSighting(author, f)
  local name = f[2]
  if not name or name == "" then return end
  local k = key(name)
  local e = byKey[k]
  if not e then
    for a in pairs(db.shared) do if db.hidden[a .. "|" .. k] then return end end
    e = { name = name, reason = f[3] ~= "" and f[3] or "no reason" }
  end
  local map, x, y = tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
  e.seen, e.seenZone = time(), f[4]
  if map and x and y then e.seenMap, e.seenX, e.seenY = map, x, y else e.seenMap, e.seenX, e.seenY = nil end
  lastSighting = e
  local msg = ("%s spotted %s (%s) in %s %s"):format(author, e.name, e.reason, e.seenZone or "?", Coords(e))
  say(msg .. (e.seenMap and " - /deathnote way" or ""))
  -- On screen only when it is in our zone; elsewhere the chat line is enough.
  if e.seenZone == GetRealZoneText() then Notify(msg, SOUNDKIT.TELL_MESSAGE) end
  RefreshUI()
end

-- Nameplates and tooltips -----------------------------------------------------

local function CheckUnit(unit, how)
  if not UnitIsPlayer(unit) or UnitIsFriend("player", unit) then return end
  local e = find(UnitGUID(unit), GetUnitName(unit, true))
  if e then Alert(e, how) end
  return e
end

local function PlateAdded(unit, quiet)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then return end
  local e
  if quiet then
    e = UnitIsPlayer(unit) and not UnitIsFriend("player", unit) and find(UnitGUID(unit), GetUnitName(unit, true)) or nil
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
  -- Instances hand tooltips secret unit tokens that addons may not pass to Unit* APIs.
  if issecretvalue and issecretvalue(unit) then return end
  if not (unit and UnitIsPlayer(unit)) or UnitIsFriend("player", unit) then return end
  local e = find(UnitGUID(unit), GetUnitName(unit, true))
  if e then
    tooltip:AddLine("Persona non grata: " .. e.reason .. (e.author and (" (from " .. e.author .. ")") or ""), 1, 0.2, 0.2)
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

local function OnComm(msg, sender)
  local author = Ambiguate(sender, "none")
  if author == UnitName("player") or not Trusted(sender) then return end
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
      say(("%s has a newer Deathnote (%s, you have %s), ask them for it"):format(author, f[5], VERSION))
    end
    if f[4] == "1" and GetTime() - (replied[author] or -30) > 30 then
      replied[author] = GetTime()
      SendList("WHISPER", sender, false)
    end
  elseif t == "E" then
    if inc and inc.serial == f[2] and f[3] and f[3] ~= "" then
      inc.entries[key(f[3])] = { name = f[3], nparts = tonumber(f[4]) or 0, parts = {},
        faction = f[5] ~= "" and f[5] or nil, class = f[6] ~= "" and f[6] or nil, guid = f[7] ~= "" and f[7] or nil }
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
      if o then e.seen, e.seenZone, e.seenMap, e.seenX, e.seenY = o.seen, o.seenZone, o.seenMap, o.seenX, o.seenY end
    end
    db.shared[author] = count > 0 and { updated = time(), entries = inc.entries } or nil
    Changed(false)
  elseif t == "S" then
    OnSighting(author, f)
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

local function HideShared(e)
  db.hidden[e.author .. "|" .. key(e.name)] = true
  say(("hidden %s (from %s)"):format(e.name, e.author))
  Changed(false)
end

-- Panel -----------------------------------------------------------------------

local FACTION_COLOR = { Alliance = "|cff3fa9ff", Horde = "|cffff4040" }

local function BuildUI()
  local W, ROWH = 500, 20
  ui = CreateFrame("Frame", "DeathnoteFrame", UIParent, "BasicFrameTemplateWithInset")
  ui:SetSize(W, 420)
  ui:SetPoint("CENTER")
  ui:SetFrameStrata("DIALOG")
  ui:SetMovable(true)
  ui:SetClampedToScreen(true)
  ui:EnableMouse(true)
  ui:RegisterForDrag("LeftButton")
  ui:SetScript("OnDragStart", ui.StartMoving)
  ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
  tinsert(UISpecialFrames, "DeathnoteFrame")
  local title = ui.TitleText or ui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("Death Note v" .. VERSION)

  local function Label(text, x, y)
    local fs = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
  end

  Label("Name (empty = your target)", 20, -32)
  local nameBox = CreateFrame("EditBox", nil, ui, "InputBoxTemplate")
  nameBox:SetSize(130, 20)
  nameBox:SetPoint("TOPLEFT", 22, -46)
  nameBox:SetAutoFocus(false)

  Label("Reason", 166, -32)
  local reasonBox = CreateFrame("EditBox", nil, ui, "InputBoxTemplate")
  reasonBox:SetSize(220, 20)
  reasonBox:SetPoint("TOPLEFT", 168, -46)
  reasonBox:SetAutoFocus(false)
  reasonBox:SetMaxLetters(MAX_REASON)

  local function DoAdd()
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

  local sf = CreateFrame("ScrollFrame", nil, ui, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -78)
  sf:SetPoint("BOTTOMRIGHT", -32, 40)
  local content = CreateFrame("Frame", nil, sf)
  content:SetSize(W - 44, 1)
  sf:SetScrollChild(content)

  local rows = {}
  local function Cell(row, x, width, font)
    local fs = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("LEFT", x, 0)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  local function NewRow(i)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(W - 44, ROWH)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROWH)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.name = Cell(row, 4, 110)

    -- Own reasons are edited in place: Enter or clicking away saves, Escape reverts.
    local reason = CreateFrame("EditBox", nil, row)
    reason:SetSize(186, ROWH)
    reason:SetPoint("LEFT", 118, 0)
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

    local pin = CreateFrame("Button", nil, row)
    pin:SetSize(16, 16)
    pin:SetPoint("LEFT", 310, 0)
    pin:SetNormalTexture("Interface\\Icons\\INV_Misc_Map_01")
    pin:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    pin:SetScript("OnClick", function() Waypoint(row.e) end)
    pin:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Set a waypoint to the last sighting")
      GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", GameTooltip_Hide)
    row.pin = pin
    row.seen = Cell(row, 330, 92, "GameFontDisableSmall")

    local del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    del:SetSize(22, 18)
    del:SetPoint("RIGHT", -2, 0)
    del:SetText("X")
    del:SetScript("OnClick", function()
      if row.e.author then HideShared(row.e) else Remove(row.e.name) end
    end)

    row:SetScript("OnEnter", function(self)
      local e = self.e
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(e.name)
      GameTooltip:AddLine(e.reason, 1, 0.2, 0.2, true)
      GameTooltip:AddLine((e.faction or "faction unknown") .. (e.class and (" " .. e.class) or ""), 0.8, 0.8, 0.8)
      if e.author then GameTooltip:AddLine("Written by " .. e.author, 0.6, 0.6, 1) end
      if e.added then GameTooltip:AddLine("Added " .. date("%Y-%m-%d %H:%M", e.added), 0.6, 0.6, 0.6) end
      if e.seen then
        GameTooltip:AddLine("Last seen " .. date("%Y-%m-%d %H:%M", e.seen) .. " " .. (e.seenZone or "") .. " " .. Coords(e), 0.6, 0.6, 0.6)
      end
      if e.author then
        GameTooltip:AddLine("X hides this entry for you only", 0.4, 0.8, 0.4)
      else
        GameTooltip:AddLine("Click the reason to edit it", 0.4, 0.8, 0.4)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    rows[i] = row
    return row
  end

  local count = ui:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  count:SetPoint("BOTTOMLEFT", 20, 18)

  local unhide = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
  unhide:SetSize(110, 22)
  unhide:SetPoint("BOTTOM", 0, 12)
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

  function ui.Refresh()
    local list, shared = {}, 0
    for _, e in pairs(byKey) do
      list[#list + 1] = e
      if e.author then shared = shared + 1 end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    for i, e in ipairs(list) do
      local row = rows[i] or NewRow(i)
      row.e = e
      row.name:SetText((FACTION_COLOR[e.faction] or "|cffffffff") .. e.name .. "|r")
      if not row.reason:HasFocus() then
        row.reason:SetText(e.author and ("|cff8888ff" .. e.author .. ":|r " .. e.reason) or e.reason)
      end
      row.reason:EnableMouse(not e.author)
      row.seen:SetText(e.seen and ((e.seenZone or "") .. " " .. Coords(e)) or "never seen")
      row.pin:SetShown(e.seenMap ~= nil)
      row:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #list * ROWH))
    count:SetText(#list .. " on the list" .. (shared > 0 and (" (" .. shared .. " from others)") or ""))
    local hidden = 0
    for _ in pairs(db.hidden) do hidden = hidden + 1 end
    unhide:SetText("Unhide (" .. hidden .. ")")
    unhide:SetShown(hidden > 0)
  end
  ui:SetScript("OnShow", ui.Refresh)
end

local function ToggleUI()
  if not ui then BuildUI(); ui.Refresh(); return end
  ui:SetShown(not ui:IsShown())
end

-- Minimap button: click toggles the panel, drag moves it around the minimap edge.
local function MinimapButton()
  local b = CreateFrame("Button", "DeathnoteMinimapButton", Minimap)
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
    GameTooltip:AddLine("Deathnote v" .. VERSION)
    GameTooltip:AddLine("Click: open the list", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  Place()
end

SLASH_DEATHNOTE1 = "/deathnote"
SlashCmdList.DEATHNOTE = function(msg)
  local cmd, rest = msg:match("^(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "add" then
    if UnitIsPlayer("target") then return Put(nil, rest, "target") end
    local name, reason = rest:match("^(%S+)%s*(.*)$")
    if not name then return say("target a player or give a name: /deathnote add Name reason") end
    Put(name, reason)
  elseif cmd == "del" then
    Remove(rest ~= "" and rest or (UnitIsPlayer("target") and GetUnitName("target", true)) or nil)
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
    DeathnoteDB = DeathnoteDB or {}
    db = DeathnoteDB
    db.hideFriendly = nil
    db.players = db.players or {}
    db.shared = db.shared or {}
    db.hidden = db.hidden or {}
    for author, list in pairs(db.shared) do
      if time() - (list.updated or 0) > SHARED_TTL then db.shared[author] = nil end
    end
    Rebuild()
    MinimapButton()
    C_ChatInfo.RegisterAddonMessagePrefix(COMM)
    C_Timer.NewTicker(0.3, Pump)
    if TooltipDataProcessor then
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, TooltipUnit)
    else
      GameTooltip:HookScript("OnTooltipSetUnit", TooltipUnit)
    end
    for _, ev in ipairs({ "PLAYER_LOGIN", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
      "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED", "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE" }) do
      self:RegisterEvent(ev)
    end
  elseif event == "PLAYER_LOGIN" then
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
    if arg == COMM then OnComm(arg2, arg4) end
  elseif event == "NAME_PLATE_UNIT_ADDED" then PlateAdded(arg)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then PlateRemoved(arg)
  elseif event == "UPDATE_MOUSEOVER_UNIT" then CheckUnit("mouseover", "mouseover")
  elseif event == "PLAYER_TARGET_CHANGED" then CheckUnit("target", "target")
  end
end)
