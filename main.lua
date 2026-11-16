--[[--
Color separation plugin for KOReader.

Re-renders the current page of a paged document (PDF, CBZ…) in RGB, even on
a grayscale device, then shows it in the image viewer through several modes:
  1. every distinct color present mapped to a distinct gray and fill pattern, with a legend
  2+. one color present on the page shown black, everything else faded
      (picked from a selector at the bottom)

Normal page rendering is never modified: the color render is momentary.

@module koplugin.HueLens
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DrawContext = require("ffi/drawcontext")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageViewer = require("ui/widget/imageviewer")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local KoptOptions = require("ui/data/koptoptions")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local ToggleSwitch = require("ui/widget/toggleswitch")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local bit = require("bit")
local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

-- Hue bands in degrees, used to name the colors found.
local BANDS = {
    { name = _("Red"),     from = 345, to = 15  },
    { name = _("Orange"),  from = 15,  to = 45  },
    { name = _("Yellow"),  from = 45,  to = 70  },
    { name = _("Green"),   from = 70,  to = 165 },
    { name = _("Cyan"),    from = 165, to = 200 },
    { name = _("Blue"),    from = 200, to = 255 },
    { name = _("Purple"),  from = 255, to = 300 },
    { name = _("Magenta"), from = 300, to = 345 },
}

-- Fill patterns for the "all colors" mode, on a TILE-pixel period. The render is
-- ~1.5x the screen, so this ends up around 8 px on screen.
local TILE = 12
local PATTERNS = {
    function() return true end,
    function(x, y) return (x + y) % TILE < 4 end,
    function(x, y) return y % TILE < 4 end,
    function(x, y) return x % 6 < 3 and y % 6 < 3 end,
    function(x, y) return (x + y) % TILE < 3 or (x - y) % TILE < 3 end,
    function(x) return x % TILE < 4 end,
    function(x, y) return (x - y) % TILE < 4 end,
    function(x, y) return x % TILE < 3 or y % TILE < 3 end,
}

local CHROMA_MIN = 40       -- below this (0-255), a pixel counts as neutral (text, axes, background)
local MERGE_DIST = 10       -- RGB distance under which two colors count as the same series
local ASSIGN_DIST = 60      -- colors farther than this from every series are left as context
local RENDER_SCALE = 1.5    -- render at 1.5x the reader's zoom so you can zoom into the chart
local MAX_PIXELS = 8000000  -- safety cap (~32 MB for the RGB render)

local function bandOf(h)
    for i, bd in ipairs(BANDS) do
        if bd.from > bd.to then
            if h >= bd.from or h < bd.to then return i end
        elseif h >= bd.from and h < bd.to then
            return i
        end
    end
    return 1
end

-- Returns luminance (0-255), chroma (0-255) and hue band index (or nil).
local function classify(r, g, b)
    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local chroma = max - min
    local lum = 0.299 * r + 0.587 * g + 0.114 * b
    if chroma == 0 then return lum, 0, nil end
    local h
    if max == r then
        h = ((g - b) / chroma) % 6
    elseif max == g then
        h = (b - r) / chroma + 2
    else
        h = (r - g) / chroma + 4
    end
    return lum, chroma, bandOf(h * 60)
end

-- Per-color classification indexed by 6-bit-per-channel RGB (64^3 = 262144 entries),
-- built once and shared by every mode's LUT and by the color census.
local LUT_SIZE = 262144
local base_lum, base_chroma
local function buildBase()
    if base_lum then return end
    base_lum = ffi.new("uint8_t[?]", LUT_SIZE)
    base_chroma = ffi.new("uint8_t[?]", LUT_SIZE)
    for ri = 0, 63 do
        for gi = 0, 63 do
            for bi = 0, 63 do
                local i = bor(lshift(ri, 12), lshift(gi, 6), bi)
                local lum, chroma = classify(ri * 4 + 2, gi * 4 + 2, bi * 4 + 2)
                base_lum[i] = math.floor(lum + 0.5)
                base_chroma[i] = chroma
            end
        end
    end
end

local function rgbOf(i)
    return rshift(i, 12) * 4 + 2, band(rshift(i, 6), 63) * 4 + 2, band(i, 63) * 4 + 2
end

local function nearest(colors, r, g, b)
    local best, best_d = nil, math.huge
    for k, c in ipairs(colors) do
        local dr, dg, db = c.r - r, c.g - g, c.b - b
        local d = dr * dr + dg * dg + db * db
        if d < best_d then best, best_d = k, d end
    end
    return best, best_d
end

-- Isolate found[id].
local function isolateLut(assign, id)
    buildBase()
    local lut = ffi.new("uint8_t[?]", LUT_SIZE)
    for i = 0, LUT_SIZE - 1 do
        local out
        if base_chroma[i] < CHROMA_MIN then
            out = 120 + base_lum[i] / 2 -- neutral context: faded but visible
        elseif assign[i] == id then
            out = 0                     -- selected color: black
        else
            out = 215                   -- other colors: light gray
        end
        lut[i] = math.floor(out + 0.5)
    end
    return lut
end

local function rgbIndex(p, bgr)
    local r, b = p.r, p.b
    if bgr then r, b = b, r end
    return bor(lshift(rshift(r, 2), 12), lshift(rshift(p.g, 2), 6), rshift(b, 2))
end

-- "All colors" mode: grays spread over the whole usable range in the colors'
-- original lightness order (so sequential scales stay ordered), and each color
-- gets a fill pattern. Sets f.gray, f.off and f.pattern on each found entry.
-- Pattern pixels use `on`, gaps use `off` (a lighter gray, so thin lines survive).
local function buildAllMode(found, assign)
    buildBase()
    local order = {}
    for i, f in ipairs(found) do order[i] = f end
    table.sort(order, function(a, b) return a.lum < b.lum end)
    local n = #order
    local on_g, off_g = {}, {}
    local tiles = ffi.new("uint16_t[?]", (#PATTERNS + 1) * TILE)
    for i = 0, (#PATTERNS + 1) * TILE - 1 do tiles[i] = 0xFFFF end
    for rank, f in ipairs(order) do
        f.gray = n == 1 and 60 or 30 + 140 * (rank - 1) / (n - 1)
        f.off = math.min(220, f.gray + 70)
        f.pattern = PATTERNS[rank]
        on_g[f.id], off_g[f.id] = f.gray, f.off
        for y = 0, TILE - 1 do
            local bits = 0
            for x = 0, TILE - 1 do
                if f.pattern(x, y) then bits = bor(bits, lshift(1, x)) end
            end
            tiles[f.id * TILE + y] = bits
        end
    end
    local on = ffi.new("uint8_t[?]", LUT_SIZE)
    local off = ffi.new("uint8_t[?]", LUT_SIZE)
    for i = 0, LUT_SIZE - 1 do
        local lum, g = base_lum[i], on_g[assign[i]]
        if g then
            local w = math.min(1, math.max(0, (base_chroma[i] - 25) / 50))
            on[i] = math.floor(lum * (1 - w) + g * w + 0.5)
            off[i] = math.floor(lum * (1 - w) + off_g[assign[i]] * w + 0.5)
        else
            on[i], off[i] = lum, lum
        end
    end
    return { on = on, off = off, tiles = tiles, assign = assign }
end

local function applyAllMode(src, m, bgr)
    local w, h = src:getWidth(), src:getHeight()
    local dst = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local sdata = ffi.cast("ColorRGB32*", src.data)
    local ddata = ffi.cast("uint8_t*", dst.data)
    local sps = src.pixel_stride
    local dstride = tonumber(dst.stride)
    local on, off, tiles, assign = m.on, m.off, m.tiles, m.assign
    for y = 0, h - 1 do
        local srow = sdata + y * sps
        local drow = ddata + y * dstride
        local ty = y % TILE
        for x = 0, w - 1 do
            local i = rgbIndex(srow[x], bgr)
            local bits = tiles[assign[i] * TILE + ty]
            drow[x] = band(rshift(bits, x % TILE), 1) == 1 and on[i] or off[i]
        end
    end
    return dst
end

-- Swatch drawn at render scale and shown scaled down, so it looks like the page.
local function legendSwatch(f, size)
    local s = math.floor(size * RENDER_SCALE)
    local bb = Blitbuffer.new(s, s, Blitbuffer.TYPE_BB8)
    for y = 0, s - 1 do
        for x = 0, s - 1 do
            local v = f.pattern(x % TILE, y % TILE) and f.gray or f.off
            bb:setPixel(x, y, Blitbuffer.Color8(math.floor(v + 0.5)))
        end
    end
    return ImageWidget:new{ image = bb, scale_factor = 1 / RENDER_SCALE }
end

local function applyLut(src, lut, bgr)
    local w, h = src:getWidth(), src:getHeight()
    local dst = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local sdata = ffi.cast("ColorRGB32*", src.data)
    local ddata = ffi.cast("uint8_t*", dst.data)
    local sps = src.pixel_stride
    local dstride = tonumber(dst.stride)
    for y = 0, h - 1 do
        local srow = sdata + y * sps
        local drow = ddata + y * dstride
        for x = 0, w - 1 do
            drow[x] = lut[rgbIndex(srow[x], bgr)]
        end
    end
    return dst
end

-- Returns the distinct colors on the page, in hue then lightness order, as
-- { id, r, g, b, lum, band, name, share }, plus `assign`, mapping each 6-bit RGB
-- index to the id of its color (0 for neutral or unmatched colors).
-- Colors are peaks of the page's color histogram rather than fixed hue bands, so
-- shades of one hue (e.g. a sequential colormap) still come out as separate colors.
-- Tiny counts are gradients and scattered pixels, not real series.
local function findColors(src, bgr)
    buildBase()
    local counts = ffi.new("uint32_t[?]", LUT_SIZE)
    local flat = ffi.new("uint32_t[?]", LUT_SIZE)
    local sdata = ffi.cast("ColorRGB32*", src.data)
    local sps = src.pixel_stride
    local w = src:getWidth()
    local prev = ffi.new("uint32_t[?]", w)
    local cur = ffi.new("uint32_t[?]", w)
    for y = 0, src:getHeight() - 1 do
        local srow = sdata + y * sps
        for x = 0, w - 1 do
            local i = rgbIndex(srow[x], bgr)
            cur[x] = i
            if base_chroma[i] >= CHROMA_MIN then counts[i] = counts[i] + 1 end
        end
        if y > 0 then
            for x = 0, w - 2 do
                local i = prev[x]
                if i == prev[x + 1] and i == cur[x] then flat[i] = flat[i] + 1 end
            end
        end
        prev, cur = cur, prev
    end
    local bins, colored = {}, 0
    for i = 0, LUT_SIZE - 1 do
        if counts[i] > 0 then
            table.insert(bins, i)
            colored = colored + counts[i]
        end
    end

    -- Peaks are picked among flat pixels (same color as their right and lower
    -- neighbours): anti-aliasing fringes of text and lines never are, and near
    -- shades of a colormap can't be told apart from them by color alone.
    table.sort(bins, function(a, b) return flat[a] > flat[b] end)
    local peaks = {}
    for __, i in ipairs(bins) do
        if flat[i] < 50 or #peaks == 16 then break end
        local r, g, b = rgbOf(i)
        local __, d = nearest(peaks, r, g, b)
        if d > MERGE_DIST * MERGE_DIST then
            table.insert(peaks, { r = r, g = g, b = b, count = 0 })
        end
    end
    for __, i in ipairs(bins) do
        local k, d = nearest(peaks, rgbOf(i))
        if d <= ASSIGN_DIST * ASSIGN_DIST then peaks[k].count = peaks[k].count + counts[i] end
    end
    local found = {}
    for __, p in ipairs(peaks) do
        if p.count >= 500 and p.count >= colored * 0.01 then table.insert(found, p) end
    end
    table.sort(found, function(a, b) return a.count > b.count end)
    for k = #found, #PATTERNS + 1, -1 do found[k] = nil end

    -- Listed in hue order, shades of the same hue numbered from darkest to lightest.
    local per_band, seen = {}, {}
    for __, f in ipairs(found) do
        local lum, __, bnd = classify(f.r, f.g, f.b)
        f.lum, f.band = lum, bnd
        per_band[f.band] = (per_band[f.band] or 0) + 1
    end
    table.sort(found, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        return a.lum < b.lum
    end)
    for k, f in ipairs(found) do
        f.id, f.count = k, 0
        f.name = BANDS[f.band].name
        if per_band[f.band] > 1 then
            seen[f.band] = (seen[f.band] or 0) + 1
            f.name = f.name .. " " .. seen[f.band]
        end
    end

    local assign = ffi.new("uint8_t[?]", LUT_SIZE)
    for __, i in ipairs(bins) do
        local k, d = nearest(found, rgbOf(i))
        if k and d <= ASSIGN_DIST * ASSIGN_DIST then
            assign[i] = k
            found[k].count = found[k].count + counts[i]
        end
    end
    for __, f in ipairs(found) do f.share = f.count / colored end
    return found, assign
end

-- Image viewer with a mode selector at the bottom instead of tap-to-cycle.
-- The selector is a ToggleSwitch (same widget as the reader's bottom panel); it
-- reports taps through `config:onConfigChoose`, which we implement ourselves.
local ModeViewer = ImageViewer:extend{
    buttons_visible = true,
}

function ModeViewer:init()
    ImageViewer.init(self)
    local per_row = 5
    local rows = math.ceil(#self.labels / per_row)
    local width = self.width - 2 * self.button_padding
    self.selector = ToggleSwitch:new{
        width = width,
        height = Size.item.height_default * rows,
        row_count = rows,
        toggle = self.labels,
        values = {},
        alternate = false,
        config = self,
    }
    self.selector:setPosition(1)
    self.legend = self:buildLegend(width)
    self:setButtons(true)
    self:update()
end

function ModeViewer:buildLegend(width)
    local per_row = 4
    local cell_w = math.floor(width / per_row)
    local sw = Screen:scaleBySize(24)
    local pad = Size.padding.default
    local face = Font:getFace("x_smallinfofont")
    local legend = VerticalGroup:new{ align = "left" }
    local row
    for i, f in ipairs(self.legend_items) do
        if (i - 1) % per_row == 0 then
            row = HorizontalGroup:new{}
            if i > 1 then table.insert(legend, VerticalSpan:new{ width = pad }) end
            table.insert(legend, row)
        end
        table.insert(row, LeftContainer:new{
            dimen = Geom:new{ w = cell_w, h = sw + 2 * Size.border.thin },
            HorizontalGroup:new{
                FrameContainer:new{
                    bordersize = Size.border.thin,
                    padding = 0,
                    legendSwatch(f, sw),
                },
                HorizontalSpan:new{ width = pad },
                TextWidget:new{
                    text = f.name,
                    face = face,
                    max_width = cell_w - sw - 3 * pad,
                },
            },
        })
    end
    return legend
end

-- update() requires self.button_table (it relabels its buttons); we just don't show it.
function ModeViewer:setButtons(with_legend)
    local group = VerticalGroup:new{ align = "center" }
    if with_legend then
        table.insert(group, self.legend)
        table.insert(group, VerticalSpan:new{ width = self.button_padding })
    end
    table.insert(group, self.selector)
    self.button_container = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = group:getSize().h + 2 * self.button_padding },
        group,
    }
end

function ModeViewer:onConfigChoose(_, _, _, _, position)
    self:switchToImageNum(position)
end

function ModeViewer:switchToImageNum(n)
    if n ~= self._images_list_cur then
        self.title_bar:setTitle(self.titles[n], true)
        self.selector:setPosition(n)
        self:setButtons(n == 1)
    end
    ImageViewer.switchToImageNum(self, n)
end

-- The legend may not be in the widget tree when closing.
function ModeViewer:onCloseWidget()
    ImageViewer.onCloseWidget(self)
    self.legend:free()
end

function ModeViewer:onTap(_, ges)
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        self:onClose()
    end
    return true
end

-- Takes ownership of src, a TYPE_BBRGB32 render.
local function showModes(src)
    local bgr = require("ffi/mupdf").bgr and true or false
    local found, assign = findColors(src, bgr)
    if #found == 0 then
        src:free()
        UIManager:show(InfoMessage:new{ text = _("No colors found.") })
        return
    end

    local list = {
        image_disposable = true, -- each generated gray image is freed when replaced
        free = function() src:free() end, -- free the RGB render on close
    }
    local titles = { _("All colors → distinct grays and patterns") }
    local labels = { _("All") }
    local all_mode = buildAllMode(found, assign)
    list[1] = function() return applyAllMode(src, all_mode, bgr) end
    for k, f in ipairs(found) do
        local name = f.name
        list[k + 1] = function() return applyLut(src, isolateLut(assign, k), bgr) end
        titles[k + 1] = string.format(_("%s  (%d%% of colored area)"), name, math.floor(f.share * 100 + 0.5))
        labels[k + 1] = name
    end

    UIManager:show(ModeViewer:new{
        image = list,
        image_disposable = true, -- calls list:free() on close
        images_keep_pan_and_zoom = true,
        fullscreen = true,
        with_title_bar = true,
        title_text = titles[1],
        titles = titles,
        labels = labels,
        legend_items = found,
    })
end

-- Any image viewer showing a single color image gets a "Colors" button that opens
-- it in the mode viewer. ImageViewer builds its button row inline in init, so we
-- rebuild the ButtonTable with one more button. Guarded against double wrapping
-- if this file is loaded again.
if not ImageViewer._huelens_orig_init then
    ImageViewer._huelens_orig_init = ImageViewer.init
    function ImageViewer:init()
        ImageViewer._huelens_orig_init(self)
        if self._images_list or type(self.image) ~= "cdata"
                or self.image:getType() ~= Blitbuffer.TYPE_BBRGB32 then
            return
        end
        local rows = self.button_table.buttons
        table.insert(rows[1], #rows[1], {
            text = _("Colors"),
            callback = function() showModes(self.image:copy()) end,
        })
        self.button_table:free()
        self.button_table = ButtonTable:new{
            width = self.width - 2 * self.button_padding,
            buttons = rows,
            zero_sep = true,
            show_parent = self,
        }
        self.button_container[1] = self.button_table
        self:update()
    end
end

local HueLens = WidgetContainer:extend{
    name = "huelens",
    is_doc_only = true,
}

function HueLens:init()
    Dispatcher:registerAction("huelens_show", {
        category = "none", event = "HueLensShow",
        title = _("Color separation of current page"), paging = true,
    })
    self.ui.menu:registerToMainMenu(self)
    self:addToBottomPanel()
end

-- KoptOptions is the shared table the PDF bottom panel is built from; add a
-- one-button row to its contrast tab (once per session, it outlives documents).
function HueLens:addToBottomPanel()
    for __, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.contrast" then
            for __, opt in ipairs(tab.options) do
                if opt.name == "huelens" then return end
            end
            table.insert(tab.options, {
                name = "huelens",
                name_text = _("Color separation"),
                toggle = { _("show") },
                values = {},
                event = "HueLensShow",
                help_text = _([[Show the current page with each chart color mapped to a distinct gray and pattern, or isolate one color at a time.]]),
            })
            return
        end
    end
end

function HueLens:addToMainMenu(menu_items)
    if not self.ui.paging then return end
    menu_items.huelens = {
        text = _("Color separation of current page"),
        sorting_hint = "tools",
        callback = function() self:onHueLensShow() end,
    }
end

-- The page region the reader currently shows, in page coordinates at `zoom`.
-- In scroll mode, the page taking most of the screen. Reflowed pages don't map
-- to native coordinates, so those get the whole page.
function HueLens:getViewArea()
    local view = self.ui.view
    local doc = self.ui.document
    local state, area = view.state, view.visible_area
    if view.page_scroll then
        state = nil
        for __, st in ipairs(view.page_states or {}) do
            if not state or st.visible_area.h > state.visible_area.h then state = st end
        end
        area = state and state.visible_area
    end
    if state and area and area.w > 0 and doc.configurable.text_wrap ~= 1 then
        return state.page, state.zoom, area.x, area.y, area.w, area.h
    end
    local pageno = self.ui:getCurrentPage()
    local dims = doc:getNativePageDimensions(pageno)
    local zoom = Screen:getWidth() / dims.w
    return pageno, zoom, 0, 0, dims.w * zoom, dims.h * zoom
end

-- Momentarily switch MuPDF to RGB, render what the reader shows, switch back.
function HueLens:renderViewRGB()
    local doc = self.ui.document
    local mudoc = doc._document
    if not (mudoc and mudoc.setColorRendering and mudoc.openPage) then
        return nil, _("This document type doesn't support color rendering.")
    end
    local pageno, zoom, x, y, w, h = self:getViewArea()
    local scale = RENDER_SCALE
    if w * h * scale * scale > MAX_PIXELS then
        scale = math.sqrt(MAX_PIXELS / (w * h))
    end
    zoom = zoom * scale
    x, y = math.floor(x * scale), math.floor(y * scale)
    w, h = math.floor(w * scale), math.floor(h * scale)
    local dc = DrawContext.new()
    dc:setZoom(zoom)

    local was_color = mudoc.color
    mudoc:setColorRendering(true)
    local ok, bb = pcall(function()
        local page = mudoc:openPage(pageno)
        local out = page:draw_new(dc, w, h, x, y)
        page:close()
        return out
    end)
    mudoc:setColorRendering(was_color)

    if not ok then
        logger.warn("HueLens: color render failed:", bb)
        return nil, _("Could not render the page in color.")
    end
    if bb:getType() ~= Blitbuffer.TYPE_BBRGB32 then
        bb:free()
        return nil, _("Color rendering is not available here.")
    end
    return bb
end

function HueLens:onHueLensShow()
    if not self.ui.paging then return end
    -- Deferred so the bottom panel finishes handling the tap before we close it.
    UIManager:nextTick(function() self:show() end)
    return true
end

function HueLens:show()
    self.ui:handleEvent(Event:new("CloseConfigMenu"))
    local msg = InfoMessage:new{ text = _("Rendering page in color…") }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local src, err = self:renderViewRGB()
    UIManager:close(msg)
    if not src then
        UIManager:show(InfoMessage:new{ text = err })
        return true
    end

    showModes(src)
    return true
end

return HueLens
