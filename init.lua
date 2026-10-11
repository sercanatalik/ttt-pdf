local ttt = require("ttt")
local sys = require("ttt.system")

local MIN_DPI, MAX_DPI, DPI_STEP = 24, 300, 8
local HINTS = "n/p page  w fit  t text  r reload"
local INSTALL_HINT = "Install poppler: brew install poppler | apt install poppler-utils | dnf install poppler-utils"

local NO_GRAPHICS = { protocol = "none", cell_w = 0, cell_h = 0 }

-- ttt.graphics() arrived after file handlers; older builds still get the text view.
local function graphics()
  if ttt.graphics then
    return ttt.graphics()
  end
  return NO_GRAPHICS
end

local function basename(path)
  return path:match("([^/\\]+)$") or path
end

local function exec_failure(binary, result)
  if result.exit_code == -1 then
    return binary .. " is not available (" .. result.stderr .. "). " .. INSTALL_HINT
  end
  local detail = result.stderr:gsub("%s+$", "")
  if detail == "" then
    detail = "exit code " .. result.exit_code
  end
  return binary .. " failed: " .. detail
end

local function parse_info(stdout)
  local pages = tonumber(stdout:match("Pages:%s+(%d+)"))
  local w, h = stdout:match("Page size:%s+([%d%.]+) x ([%d%.]+) pts")
  return pages, tonumber(w), tonumber(h)
end

local function split_lines(text)
  local lines = {}
  text = text:gsub("\f", "")
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

-- Rounding down to DPI_STEP keeps small resizes from re-rendering; contain-fit never upscales, so a slightly smaller image still fits.
local function dpi_for(view, cols, rows, g)
  local avail_w = cols * g.cell_w
  local avail_h = math.max(rows - 1, 1) * g.cell_h
  local dpi = math.min(avail_w / (view.width / 72), avail_h / (view.height / 72))
  dpi = math.floor(dpi / DPI_STEP) * DPI_STEP
  return math.max(MIN_DPI, math.min(MAX_DPI, dpi))
end

local View = {}
View.__index = View

local function new_view(path)
  local view = setmetatable({ path = path }, View)
  view:reset()
  return view
end

function View:reset()
  self.page = self.page or 1
  self.pages = nil
  self.width, self.height = 612, 792
  self.error = nil
  self.images = {}
  self.shown = nil
  self.texts = {}
  self.pending = {}
  self.text_offset = 0
  self.text_mode = self.text_mode or false
  self.fit = self.fit or "page"
  self.scroll_rows = self.scroll_rows or 0
  self.generation = (self.generation or 0) + 1
end

function View:redraw()
  if self.panel then
    self.panel:redraw()
  end
end

-- A reload bumps the generation, so results from before it are dropped instead of overwriting fresh state.
function View:run(binary, args, key, on_success)
  if self.pending[key] then
    return
  end
  self.pending[key] = true
  local generation = self.generation
  sys.exec_async(binary, args, function(result)
    if generation ~= self.generation then
      return
    end
    self.pending[key] = nil
    if result.exit_code == 0 then
      on_success(result.stdout)
    else
      self.error = exec_failure(binary, result)
    end
    self:redraw()
  end)
end

function View:load_info()
  self:run("pdfinfo", { self.path }, "info", function(stdout)
    local pages, w, h = parse_info(stdout)
    if not pages or pages < 1 then
      self.error = "pdfinfo did not report a page count for " .. basename(self.path)
      return
    end
    self.pages = pages
    self.page = math.min(self.page, pages)
    if w and h and w > 0 and h > 0 then
      self.width, self.height = w, h
    end
  end)
end

function View:fetch(key, entry, args)
  if self.images[key] then
    return
  end
  self:run("pdftoppm", args, key, function(stdout)
    entry.data = stdout
    self.images[key] = entry
  end)
end

function View:fetch_page(page, dpi)
  if page < 1 or page > self.pages then
    return
  end
  local p = tostring(page)
  self:fetch("page:" .. page .. ":" .. dpi, { page = page, dpi = dpi, kind = "page" },
    { "-png", "-r", tostring(dpi), "-f", p, "-l", p, self.path })
end

-- pdftoppm crops while rendering, so fit-width only ever rasterizes the visible slice of a page.
function View:fetch_slice(page, dpi, y, w, h)
  local p = tostring(page)
  self:fetch("slice:" .. page .. ":" .. dpi .. ":" .. y .. ":" .. h, { page = page, dpi = dpi, kind = "slice", y = y },
    { "-png", "-r", tostring(dpi), "-f", p, "-l", p, "-x", "0", "-y", tostring(y), "-W", tostring(w), "-H", tostring(h), self.path })
end

function View:fetch_text(page)
  if self.texts[page] then
    return
  end
  local p = tostring(page)
  self:run("pdftotext", { "-layout", "-f", p, "-l", p, self.path, "-" }, "txt:" .. page, function(stdout)
    self.texts[page] = split_lines(stdout)
  end)
end

-- Keeps what the next keypress is likely to need (neighbouring pages, nearby slices, current resolution) so memory stays bounded on long documents.
function View:prune(dpi, y, span)
  for key, entry in pairs(self.images) do
    local far_page = math.abs(entry.page - self.page) > 1
    local stale = entry.dpi ~= dpi and entry.page ~= self.page
    local far_slice = entry.kind == "slice" and y and (entry.page ~= self.page or math.abs(entry.y - y) > 2 * span)
    if far_page or stale or far_slice then
      self.images[key] = nil
    end
  end
  for page in pairs(self.texts) do
    if math.abs(page - self.page) > 1 then
      self.texts[page] = nil
    end
  end
end

-- While a render is in flight the last image shown stays up, but only for the same page and fit: a prefetched neighbouring slice would show the wrong part of the page.
function View:image_for(key, kind)
  local exact = self.images[key]
  if exact then
    self.shown = { page = self.page, kind = kind, data = exact.data }
    return exact.data
  end
  if self.shown and self.shown.page == self.page and self.shown.kind == kind then
    return self.shown.data
  end
end

function View:status_line(mode)
  local pages = self.pages and tostring(self.pages) or "?"
  return string.format("%s  page %d/%s  [%s]  %s", basename(self.path), self.page, pages, mode, HINTS)
end

function View:render_page(panel, cols, rows, g)
  local dpi = dpi_for(self, cols, rows, g)
  self:prune(dpi)
  self:fetch_page(self.page, dpi)
  self:fetch_page(self.page + 1, dpi)
  local png = self:image_for("page:" .. self.page .. ":" .. dpi, "page")
  if png then
    panel:image({ data = png, alt = "Page " .. self.page .. " of " .. self.pages })
  else
    panel:label({ text = "Rendering page " .. self.page .. "...", style = "muted" })
  end
end

-- Layout runs before anything is drawn, so the status line and the key handlers read the same clamped scroll position.
function View:layout_width(cols, rows, g)
  local visible = math.max(rows - 1, 1)
  local dpi = math.floor(cols * g.cell_w / (self.width / 72) / DPI_STEP) * DPI_STEP
  dpi = math.max(MIN_DPI, math.min(MAX_DPI, dpi))
  local page_h = math.floor(self.height / 72 * dpi)
  local max_scroll = math.max(0, math.ceil(page_h / g.cell_h) - visible)
  self.scroll_rows = math.max(0, math.min(self.scroll_rows, max_scroll))
  self.layout = {
    visible = visible,
    max_scroll = max_scroll,
    dpi = dpi,
    slice_w = math.floor(self.width / 72 * dpi),
    span = visible * g.cell_h,
    y = self.scroll_rows * g.cell_h,
    last_y = max_scroll * g.cell_h,
  }
end

function View:render_width(panel)
  local l = self.layout
  self:prune(l.dpi, l.y, l.span)
  self:fetch_slice(self.page, l.dpi, l.y, l.slice_w, l.span)
  local next_y = math.min(l.y + l.span, l.last_y)
  if next_y > l.y then
    self:fetch_slice(self.page, l.dpi, next_y, l.slice_w, l.span)
  end
  local png = self:image_for("slice:" .. self.page .. ":" .. l.dpi .. ":" .. l.y .. ":" .. l.span, "slice")
  if png then
    panel:image({ data = png, alt = "Page " .. self.page .. " of " .. self.pages })
  else
    panel:label({ text = "Rendering page " .. self.page .. "...", style = "muted" })
  end
end

function View:render_text(panel, rows)
  self:prune(nil)
  self:fetch_text(self.page)
  local lines = self.texts[self.page]
  if not lines then
    panel:label({ text = "Extracting text from page " .. self.page .. "...", style = "muted" })
    return
  end
  if #lines == 0 then
    panel:label({ text = "Page " .. self.page .. " has no extractable text (it may be a scanned image).", style = "muted" })
    return
  end
  local visible = math.max(rows - 1, 1)
  self.text_offset = math.max(0, math.min(self.text_offset, #lines - visible))
  self.layout = { visible = visible, max_scroll = math.max(0, #lines - visible) }
  for i = self.text_offset + 1, math.min(#lines, self.text_offset + visible) do
    panel:label(lines[i])
  end
end

function View:mode_label()
  if self.mode == "width" then
    local max = self.layout and self.layout.max_scroll or 0
    local pct = max > 0 and math.floor(self.scroll_rows / max * 100) or 0
    return "fit width " .. pct .. "%"
  end
  if self.mode == "page" then
    return "fit page"
  end
  return "text"
end

function View:render(panel)
  self.panel = panel
  local cols, rows = panel:size()
  local g = graphics()
  local can_draw = g.protocol == "kitty" and g.cell_w > 0 and g.cell_h > 0
  if can_draw and not self.text_mode then
    self.mode = self.fit
  else
    self.mode = "text"
  end
  self.layout = nil

  if self.error or not self.pages then
    panel:label({ text = self:status_line(self:mode_label()), style = "muted" })
    panel:label({ text = self.error or ("Reading " .. basename(self.path) .. "..."), style = self.error and "danger" or "muted" })
    return
  end
  if self.mode == "width" then
    self:layout_width(cols, rows, g)
  end
  panel:label({ text = self:status_line(self:mode_label()), style = "muted" })
  if self.mode == "page" then
    self:render_page(panel, cols, rows, g)
  elseif self.mode == "width" then
    self:render_width(panel)
  else
    self:render_text(panel, rows)
  end
end

function View:go_to(page, scroll)
  if not self.pages then
    return false
  end
  page = math.max(1, math.min(self.pages, page))
  if page ~= self.page then
    self.page = page
    self.text_offset = 0
    self.scroll_rows = scroll or 0
  end
  return true
end

function View:scroll(delta)
  if self.mode == "width" then
    self.scroll_rows = math.max(0, self.scroll_rows + delta)
  else
    self.text_offset = math.max(0, self.text_offset + delta)
  end
  return true
end

-- In fit-width a screen step scrolls within the page and only crosses to the next or previous page at its edges.
function View:screen_down()
  if self.mode ~= "width" or not self.layout then
    return self:go_to(self.page + 1)
  end
  if self.scroll_rows >= self.layout.max_scroll then
    return self:go_to(self.page + 1)
  end
  return self:scroll(self.layout.visible)
end

function View:screen_up()
  if self.mode ~= "width" or not self.layout then
    return self:go_to(self.page - 1)
  end
  if self.scroll_rows <= 0 then
    return self:go_to(self.page - 1, math.huge)
  end
  return self:scroll(-self.layout.visible)
end

local KEYS = {
  n = function(v) return v:go_to(v.page + 1) end,
  Right = function(v) return v:go_to(v.page + 1) end,
  p = function(v) return v:go_to(v.page - 1) end,
  Left = function(v) return v:go_to(v.page - 1) end,
  [" "] = function(v) return v:screen_down() end,
  PgDn = function(v) return v:screen_down() end,
  b = function(v) return v:screen_up() end,
  PgUp = function(v) return v:screen_up() end,
  g = function(v) return v:go_to(1) end,
  Home = function(v) return v:go_to(1) end,
  G = function(v) return v:go_to(v.pages or 1) end,
  End = function(v) return v:go_to(v.pages or 1) end,
  j = function(v) return v:scroll(1) end,
  Down = function(v) return v:scroll(1) end,
  k = function(v) return v:scroll(-1) end,
  Up = function(v) return v:scroll(-1) end,
  w = function(v)
    v.fit = v.fit == "width" and "page" or "width"
    v.scroll_rows = 0
    return true
  end,
  t = function(v)
    v.text_mode = not v.text_mode
    return true
  end,
  r = function(v)
    v:reset()
    v:load_info()
    return true
  end,
}

function View:on_event(ev)
  local handled = false
  if ev.type == "key" and (ev.mod == nil or ev.mod == "shift") then
    local action = KEYS[ev.key]
    handled = action ~= nil and action(self)
  elseif ev.type == "mouse" then
    local paging = self.mode == "page"
    if ev.button == "wheel_down" then
      handled = paging and self:go_to(self.page + 1) or self:scroll(3)
    elseif ev.button == "wheel_up" then
      handled = paging and self:go_to(self.page - 1) or self:scroll(-3)
    end
  end
  if handled then
    self:redraw()
  end
  return handled
end

ttt.register({
  file_handlers = {
    {
      id = "pdf",
      title = "PDF Viewer",
      extensions = { "pdf" },
      magic = "%PDF-",
      open = function(path, tab)
        local view = new_view(path)
        view:load_info()
        tab.render = function(panel) view:render(panel) end
        tab.on_event = function(ev) return view:on_event(ev) end
      end,
    },
  },
})
