-- BeamGMod menu v2: car cards with BeamNG's real preview pictures, type filters, search, config thumbnails.
-- Loaded after cl_main.lua, so it replaces the old bg_menu / BeamNG icon.
-- Pictures: data/beamgmod/thumbs/vehicles_<model>_<config>.jpg  (copied by copy_thumbs.bat / play.bat)

if not CLIENT then return end

local C = BG.C

surface.CreateFont("BGU_Title", { font = "Roboto", size = 28, weight = 800, antialias = true })
surface.CreateFont("BGU_Name", { font = "Roboto", size = 18, weight = 700, antialias = true })
surface.CreateFont("BGU_Big", { font = "Roboto", size = 26, weight = 800, antialias = true })
surface.CreateFont("BGU_Small", { font = "Roboto", size = 14, weight = 500, antialias = true })
surface.CreateFont("BGU_Btn", { font = "Roboto", size = 16, weight = 700, antialias = true })

local COL = {
    bg = Color(16, 18, 23, 250),
    panel = Color(26, 29, 36),
    card = Color(34, 38, 47),
    cardHi = Color(46, 51, 64),
    accent = Color(255, 122, 26),
    accentHi = Color(255, 150, 64),
    text = Color(236, 239, 246),
    dim = Color(140, 149, 167),
    dark = Color(12, 13, 17),
}

local THUMBS = "beamgmod/thumbs/"
local matCache, listCache = {}, {}

local function LoadThumb(name)
    local m = matCache[name]
    if m ~= nil then return m or nil end
    local rel
    if file.Exists(THUMBS .. name .. ".jpg", "DATA") then rel = THUMBS .. name .. ".jpg"
    elseif file.Exists(THUMBS .. name .. ".png", "DATA") then rel = THUMBS .. name .. ".png" end
    if not rel then matCache[name] = false return nil end
    local mat = Material("data/" .. rel, "smooth mips")
    if not mat or mat:IsError() then matCache[name] = false return nil end
    matCache[name] = mat
    return mat
end

local function Key(s) return string.lower(tostring(s)) end

-- picture of a model (its default shot, else any of its configurations)
local function ModelThumb(model)
    if not model then return nil end
    local m = LoadThumb("vehicles_" .. Key(model) .. "_default")
    if m then return m end
    local l = listCache[model]
    if l == nil then
        local files = file.Find(THUMBS .. "vehicles_" .. Key(model) .. "_*.jpg", "DATA")
        l = (files and files[1]) and string.StripExtension(files[1]) or false
        listCache[model] = l
    end
    return l and LoadThumb(l) or nil
end

local function ConfigThumb(model, cfg)
    if not model or not cfg or cfg == "" then return ModelThumb(model) end
    return LoadThumb("vehicles_" .. Key(model) .. "_" .. Key(cfg)) or ModelThumb(model)
end

local function DrawCover(mat, x, y, w, h)
    surface.SetMaterial(mat)
    surface.SetDrawColor(255, 255, 255, 255)
    local tw, th = mat:Width(), mat:Height()
    if not tw or not th or tw <= 0 or th <= 0 then surface.DrawTexturedRect(x, y, w, h) return end
    local ar, tr = w / h, tw / th
    local u0, v0, u1, v1 = 0, 0, 1, 1
    if tr > ar then
        local k = ar / tr
        u0 = (1 - k) / 2 u1 = 1 - u0
    else
        local k = tr / ar
        v0 = (1 - k) / 2 v1 = 1 - v0
    end
    surface.DrawTexturedRectUV(x, y, w, h, u0, v0, u1, v1)
end

local function Fit(text, font, maxw)
    surface.SetFont(font)
    text = tostring(text or "")
    if surface.GetTextSize(text) <= maxw then return text end
    while #text > 1 and surface.GetTextSize(text .. "...") > maxw do text = string.sub(text, 1, -2) end
    return text .. "..."
end

local function Placeholder(x, y, w, h, label)
    draw.RoundedBox(6, x, y, w, h, COL.dark)
    draw.SimpleText(string.upper(string.sub(tostring(label or "?"), 1, 1)), "BGU_Big", x + w / 2, y + h / 2, Color(60, 66, 82), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

local function Btn(parent, text, fn, accent)
    local b = vgui.Create("DButton", parent)
    b:SetText("")
    b.DoClick = fn
    b.Paint = function(s, w, h)
        local c
        if accent then c = s:IsHovered() and COL.accentHi or COL.accent
        else c = s:IsHovered() and COL.cardHi or COL.card end
        draw.RoundedBox(6, 0, 0, w, h, c)
        draw.SimpleText(text, "BGU_Btn", w / 2, h / 2, accent and Color(20, 20, 20) or COL.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    return b
end

local function BtnRow(parent, defs)
    local row = vgui.Create("DPanel", parent)
    row:Dock(TOP)
    row:SetTall(34)
    row:DockMargin(0, 0, 0, 6)
    row.Paint = nil
    local btns = {}
    for _, d in ipairs(defs) do btns[#btns + 1] = Btn(row, d[1], d[2], d[3]) end
    row.PerformLayout = function(s, w, h)
        local gap = 6
        local bw = (w - gap * (#btns - 1)) / #btns
        for i, b in ipairs(btns) do b:SetPos((i - 1) * (bw + gap), 0) b:SetSize(bw, h) end
    end
    return row
end

local function OpenMenu()
    if IsValid(C.frame) then C.frame:Remove() end
    matCache, listCache = {}, {}

    local selected, selectedCfg, selectedModel
    local filterType, query = "All", ""
    local cards = {}

    local W, H = math.min(ScrW() - 40, 1200), math.min(ScrH() - 40, 740)
    local f = vgui.Create("DFrame")
    f:SetSize(W, H)
    f:Center()
    f:SetTitle("")
    f:ShowCloseButton(false)
    f:SetDraggable(true)
    f:MakePopup()
    C.frame = f

    f.Paint = function(s, w, h)
        draw.RoundedBox(12, 0, 0, w, h, COL.bg)
        draw.RoundedBoxEx(12, 0, 0, w, 64, COL.panel, true, true, false, false)
        surface.SetDrawColor(COL.accent)
        surface.DrawRect(0, 64, w, 2)
        draw.SimpleText("BEAMNG", "BGU_Title", 24, 32, COL.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        surface.SetFont("BGU_Title")
        local tw = surface.GetTextSize("BEAMNG ")
        draw.SimpleText("GARAGE", "BGU_Title", 24 + tw, 32, COL.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- header: search + close
    local close = Btn(f, "X", function() f:Remove() end)
    close:SetPos(W - 52, 14)
    close:SetSize(36, 36)

    local search = vgui.Create("DTextEntry", f)
    search:SetPos(W - 52 - 12 - 320, 14)
    search:SetSize(320, 36)
    search:SetFont("BGU_Name")
    search.Paint = function(s, w, h)
        draw.RoundedBox(8, 0, 0, w, h, COL.dark)
        if s:GetValue() == "" and not s:HasFocus() then
            draw.SimpleText("Search cars or brands...", "BGU_Name", 12, h / 2, COL.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        s:DrawTextEntryText(COL.text, COL.accent, COL.text)
    end
    search:SetTextInset(12, 0) -- keeps text off the left edge

    -- sidebar: types
    local side = vgui.Create("DScrollPanel", f)
    side:SetPos(12, 78)
    side:SetSize(176, H - 90)
    side.Paint = function(s, w, h) draw.RoundedBox(10, 0, 0, w, h, COL.panel) end
    side:GetVBar():SetWide(0)

    -- right panel
    local RW = 370
    local right = vgui.Create("DPanel", f)
    right:SetPos(W - RW - 12, 78)
    right:SetSize(RW, H - 90)
    right.Paint = function(s, w, h) draw.RoundedBox(10, 0, 0, w, h, COL.panel) end

    local info = vgui.Create("DPanel", right)
    info:Dock(TOP)
    info:SetTall(292)
    info:DockMargin(0, 0, 0, 0)
    info.Paint = function(s, w, h)
        local pw, ph = w - 24, 200
        if not selected then
            draw.SimpleText("Pick a car on the left", "BGU_Name", w / 2, h / 2, COL.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        local mat = ConfigThumb(selected, selectedCfg)
        if mat then
            draw.RoundedBox(8, 12, 12, pw, ph, COL.dark)
            DrawCover(mat, 12, 12, pw, ph)
        else
            Placeholder(12, 12, pw, ph, selectedModel and selectedModel.name or selected)
        end
        local m = selectedModel or {}
        draw.SimpleText(Fit(m.name or selected, "BGU_Big", w - 24), "BGU_Big", 12, 228, COL.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        local sub = string.upper(tostring(m.brand or "")) .. ((m.brand and m.type) and "  -  " or "") .. string.upper(tostring(m.type or ""))
        draw.SimpleText(Fit(sub, "BGU_Small", w - 24), "BGU_Small", 12, 258, COL.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        if selectedCfg then
            draw.SimpleText(Fit("Config: " .. selectedCfg, "BGU_Small", w - 24), "BGU_Small", 12, 276, COL.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
    end

    local actions = vgui.Create("DPanel", right)
    actions:Dock(BOTTOM)
    actions:SetTall(6 + 40 + 6 + 40 * 3 + 12)
    actions:DockMargin(12, 0, 12, 12)
    actions.Paint = nil

    local spawn = Btn(actions, "SPAWN SELECTED", function()
        if selected then RunConsoleCommand("bg_spawn", tostring(selected), selectedCfg and tostring(selectedCfg) or "") end
    end, true)
    spawn:Dock(TOP)
    spawn:SetTall(44)
    spawn:DockMargin(0, 0, 0, 8)
    spawn.Paint = function(s, w, h)
        local c = s:IsHovered() and COL.accentHi or COL.accent
        draw.RoundedBox(8, 0, 0, w, h, c)
        draw.SimpleText("SPAWN" .. (selected and (" " .. string.upper(tostring(selectedModel and selectedModel.name or selected))) or ""), "BGU_Btn", w / 2, h / 2, Color(20, 20, 20), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- the layout below fills in order
    BtnRow(actions, { { "Remove", function() RunConsoleCommand("bg_remove") end }, { "Flip / repair", function() RunConsoleCommand("bg_here") end }, { "Reset", function() RunConsoleCommand("bg_reset") end } })
    BtnRow(actions, { { "Ignite", function() RunConsoleCommand("bg_ignite") end }, { "Extinguish", function() RunConsoleCommand("bg_extinguish") end }, { "Explode", function() RunConsoleCommand("bg_boom") end } })
    BtnRow(actions, { { "Launch", function() RunConsoleCommand("bg_launch") end }, { "Next car", function() RunConsoleCommand("bg_next") end } })

    local cfgScroll = vgui.Create("DScrollPanel", right)
    cfgScroll:Dock(FILL)
    cfgScroll:DockMargin(12, 0, 12, 10)
    cfgScroll:GetVBar():SetWide(6)
    cfgScroll:GetVBar().Paint = function() end
    cfgScroll:GetVBar().btnGrip.Paint = function(s, w, h) draw.RoundedBox(3, 0, 0, w, h, COL.cardHi) end
    cfgScroll:GetVBar().btnUp.Paint = function() end
    cfgScroll:GetVBar().btnDown.Paint = function() end

    local function ConfigRow(label, cfgKey, thumbMat)
        local r = vgui.Create("DButton", cfgScroll)
        r:SetText("")
        r:Dock(TOP)
        r:SetTall(56)
        r:DockMargin(0, 0, 6, 4)
        r.Paint = function(s, w, h)
            local sel = (selectedCfg == cfgKey)
            draw.RoundedBox(8, 0, 0, w, h, (sel or s:IsHovered()) and COL.cardHi or COL.card)
            if sel then draw.RoundedBox(2, 0, 8, 3, h - 16, COL.accent) end
            local mat = thumbMat or ConfigThumb(selected, cfgKey)
            if mat then DrawCover(mat, 8, 6, 78, 44) else Placeholder(8, 6, 78, 44, label) end
            draw.SimpleText(Fit(label, "BGU_Name", w - 104), "BGU_Name", 96, h / 2, sel and COL.text or Color(200, 205, 218), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        r.DoClick = function() selectedCfg = cfgKey end
        r.DoDoubleClick = function()
            selectedCfg = cfgKey
            if selected then RunConsoleCommand("bg_spawn", tostring(selected), cfgKey and tostring(cfgKey) or "") end
        end
        return r
    end

    local function FillConfigs(model)
        if not IsValid(cfgScroll) or model ~= selected then return end
        cfgScroll:Clear()
        ConfigRow("Default", nil)
        for _, c in ipairs(C.configs[model] or {}) do
            ConfigRow(tostring(c.name or c.k), c.k)
        end
    end
    C.onConfigs = FillConfigs

    local function Select(m)
        selected = m.k
        selectedModel = m
        selectedCfg = nil
        cfgScroll:Clear()
        if C.configs[selected] then
            FillConfigs(selected)
        else
            ConfigRow("Default", nil)
            RunConsoleCommand("bg_vconfigs", tostring(selected))
        end
    end

    -- center: cards
    local scroll = vgui.Create("DScrollPanel", f)
    scroll:SetPos(200, 78)
    scroll:SetSize(W - 200 - RW - 24, H - 90)
    local vb = scroll:GetVBar()
    vb:SetWide(8)
    vb.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, COL.panel) end
    vb.btnGrip.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, COL.cardHi) end
    vb.btnUp.Paint = function() end
    vb.btnDown.Paint = function() end

    local lastKey = ""
    local function LayoutCards(force)
        local availW = scroll:GetWide() - 14
        if availW < 100 then return end
        local key = availW .. ":" .. #cards
        if key == lastKey and not force then return end
        lastKey = key
        local gap = 10
        local cols = math.max(1, math.floor((availW + gap) / (210 + gap)))
        local cw = math.floor((availW - gap * (cols - 1)) / cols)
        local ch = math.floor(cw * 0.62) + 50
        for i, card in ipairs(cards) do
            local c = (i - 1) % cols
            local r = math.floor((i - 1) / cols)
            card:SetPos(c * (cw + gap), r * (ch + gap))
            card:SetSize(cw, ch)
        end
        local rows = math.ceil(#cards / cols)
        scroll:GetCanvas():SetTall(math.max(1, rows * (ch + gap)))
    end
    local basePL = scroll.PerformLayout
    scroll.PerformLayout = function(s, w, h)
        LayoutCards()
        basePL(s, w, h)
    end

    local empty = vgui.Create("DPanel", f)
    empty:SetPos(200, 78)
    empty:SetSize(W - 200 - RW - 24, H - 90)
    empty:SetMouseInputEnabled(false)
    empty.Paint = function(s, w, h)
        if #cards > 0 then return end
        local msg = #C.models == 0 and "Waiting for BeamNG's car list..." or "No cars match."
        draw.SimpleText(msg, "BGU_Name", w / 2, h / 2, COL.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    local noPics = not (file.Find(THUMBS .. "*.jpg", "DATA")[1])
    local banner = vgui.Create("DPanel", f)
    banner:SetPos(200, H - 12 - 34)
    banner:SetSize(W - 200 - RW - 24, 34)
    banner:SetMouseInputEnabled(false)
    banner.Paint = function(s, w, h)
        if not noPics then return end
        draw.RoundedBox(8, 0, 0, w, h, Color(70, 40, 10, 240))
        draw.SimpleText("No car pictures yet: run copy_thumbs.bat (BeamGMod folder), then reopen this menu.", "BGU_Small", w / 2, h / 2, COL.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    local function MakeCard(m)
        local b = vgui.Create("DButton", scroll)
        b:SetText("")
        b.Paint = function(s, w, h)
            local sel = selected == m.k
            draw.RoundedBox(10, 0, 0, w, h, (s:IsHovered() or sel) and COL.cardHi or COL.card)
            local ih = h - 50
            local mat = ModelThumb(m.k)
            if mat then
                draw.RoundedBox(8, 6, 6, w - 12, ih - 6, COL.dark)
                DrawCover(mat, 6, 6, w - 12, ih - 6)
            else
                Placeholder(6, 6, w - 12, ih - 6, m.name or m.k)
            end
            draw.SimpleText(Fit(m.name or m.k, "BGU_Name", w - 16), "BGU_Name", 10, h - 40, COL.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            draw.SimpleText(Fit(string.upper(tostring(m.brand or "") .. ((m.brand and m.type) and "  -  " or "") .. tostring(m.type or "")), "BGU_Small", w - 16), "BGU_Small", 10, h - 19, COL.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            if sel then
                surface.SetDrawColor(COL.accent)
                surface.DrawOutlinedRect(0, 0, w, h, 2)
            end
        end
        b.DoClick = function() Select(m) end
        b.DoDoubleClick = function()
            Select(m)
            RunConsoleCommand("bg_spawn", tostring(m.k))
        end
        return b
    end

    local sideBtns = {}
    local function FillSide()
        side:Clear()
        local counts, order = {}, {}
        for _, m in ipairs(C.models) do
            local t = tostring(m.type or "")
            if t == "" then t = "Other" end
            if not counts[t] then counts[t] = 0 order[#order + 1] = t end
            counts[t] = counts[t] + 1
        end
        table.sort(order)
        table.insert(order, 1, "All")
        counts["All"] = #C.models
        for _, t in ipairs(order) do
            local b = vgui.Create("DButton", side)
            b:SetText("")
            b:Dock(TOP)
            b:SetTall(36)
            b:DockMargin(8, 4, 8, 0)
            b.Paint = function(s, w, h)
                local sel = filterType == t
                draw.RoundedBox(8, 0, 0, w, h, sel and COL.accent or (s:IsHovered() and COL.cardHi or Color(0, 0, 0, 0)))
                draw.SimpleText(Fit(t, "BGU_Btn", w - 50), "BGU_Btn", 12, h / 2, sel and Color(20, 20, 20) or COL.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                draw.SimpleText(counts[t], "BGU_Small", w - 10, h / 2, sel and Color(40, 40, 40) or COL.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            end
            b.DoClick = function() filterType = t C.onModels() end
        end
    end

    local sideSig = -1
    C.onModels = function()
        if not IsValid(scroll) then return end
        for _, c in ipairs(cards) do if IsValid(c) then c:Remove() end end
        cards = {}
        local q = string.lower(query)
        for _, m in ipairs(C.models) do
            local t = tostring(m.type or "")
            if t == "" then t = "Other" end
            local name = tostring(m.name or m.k)
            local hay = string.lower(name .. " " .. tostring(m.brand or "") .. " " .. tostring(m.k))
            if (filterType == "All" or t == filterType) and (q == "" or string.find(hay, q, 1, true)) then
                cards[#cards + 1] = MakeCard(m)
            end
        end
        if sideSig ~= #C.models then sideSig = #C.models FillSide() end
        LayoutCards(true)
        scroll:InvalidateLayout()
    end
    search.OnChange = function(s) query = s:GetValue() or "" C.onModels() end

    RunConsoleCommand("bg_vlist")
    C.onModels()
end

concommand.Add("bg_menu", OpenMenu)

list.Set("DesktopWindows", "BeamGMod", {
    title = "BeamNG",
    icon = "icon16/car.png",
    width = 300,
    height = 100,
    onewindow = true,
    init = function(icon, window)
        if IsValid(window) then window:Remove() end
        timer.Simple(0, OpenMenu)
    end,
})
