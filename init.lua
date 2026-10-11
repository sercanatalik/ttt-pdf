local ttt = require("ttt")
local sys = require("ttt.system")

local MIN_DPI, MAX_DPI, DPI_STEP = 24, 300, 8
local HINTS = "n/p page  g/G first/last  t text  r reload"
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
  self.texts = {}
  self.pending = {}
  self.text_offset = 0
  self.text_mode = self.text_mode or false
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

function View:image_key(page, dpi)
  return "png:" .. page .. ":" .. dpi
end

function View:fetch_image(page, dpi)
  if page < 1 or page > self.pages then
    return
  end
  local key = self:image_key(page, dpi)
  if self.images[key] then
    return
  end
  local p = tostring(page)
  self:run("pdftoppm", { "-png", "-r", tostring(dpi), "-f", p, "-l", p, self.path }, key, function(stdout)
    self.images[key] = stdout
  end)
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

-- Keeps the current page and its neighbours at the current resolution; everything else is dropped so memory stays bounded on long documents.
function View:prune(dpi)
  for key in pairs(self.images) do
    local page, key_dpi = key:match("^png:(%d+):(%d+)$")
    page, key_dpi = tonumber(page), tonumber(key_dpi)
    if math.abs(page - self.page) > 1 or (key_dpi ~= dpi and page ~= self.page) then
      self.images[key] = nil
    end
  end
  for page in pairs(self.texts) do
    if math.abs(page - self.page) > 1 then
      self.texts[page] = nil
    end
  end
end

function View:current_image(dpi)
  local exact = self.images[self:image_key(self.page, dpi)]
  if exact then
    return exact
  end
  local prefix = "png:" .. self.page .. ":"
  for key, png in pairs(self.images) do
    if key:sub(1, #prefix) == prefix then
      return png
    end
  end
end

function View:status_line(mode)
  local pages = self.pages and tostring(self.pages) or "?"
  return string.format("%s  page %d/%s  [%s]  %s", basename(self.path), self.page, pages, mode, HINTS)
end

function View:render_image(panel, cols, rows, g)
  local dpi = dpi_for(self, cols, rows, g)
  self:prune(dpi)
  self:fetch_image(self.page, dpi)
  self:fetch_image(self.page + 1, dpi)
  local png = self:current_image(dpi)
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
  for i = self.text_offset + 1, math.min(#lines, self.text_offset + visible) do
    panel:label(lines[i])
  end
end

function View:render(panel)
  self.panel = panel
  local cols, rows = panel:size()
  local g = graphics()
  local can_draw = g.protocol == "kitty" and g.cell_w > 0 and g.cell_h > 0
  local mode = (can_draw and not self.text_mode) and "image" or "text"

  panel:label({ text = self:status_line(mode), style = "muted" })
  if self.error then
    panel:label({ text = self.error, style = "danger" })
    return
  end
  if not self.pages then
    panel:label({ text = "Reading " .. basename(self.path) .. "...", style = "muted" })
    return
  end
  if mode == "image" then
    self:render_image(panel, cols, rows, g)
  else
    self:render_text(panel, rows)
  end
end

function View:go_to(page)
  if not self.pages then
    return false
  end
  page = math.max(1, math.min(self.pages, page))
  if page ~= self.page then
    self.page = page
    self.text_offset = 0
  end
  return true
end

function View:scroll(delta)
  self.text_offset = math.max(0, self.text_offset + delta)
  return true
end

local KEYS = {
  n = function(v) return v:go_to(v.page + 1) end,
  [" "] = function(v) return v:go_to(v.page + 1) end,
  PgDn = function(v) return v:go_to(v.page + 1) end,
  Right = function(v) return v:go_to(v.page + 1) end,
  p = function(v) return v:go_to(v.page - 1) end,
  b = function(v) return v:go_to(v.page - 1) end,
  PgUp = function(v) return v:go_to(v.page - 1) end,
  Left = function(v) return v:go_to(v.page - 1) end,
  g = function(v) return v:go_to(1) end,
  Home = function(v) return v:go_to(1) end,
  G = function(v) return v:go_to(v.pages or 1) end,
  End = function(v) return v:go_to(v.pages or 1) end,
  j = function(v) return v:scroll(1) end,
  Down = function(v) return v:scroll(1) end,
  k = function(v) return v:scroll(-1) end,
  Up = function(v) return v:scroll(-1) end,
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
    if ev.button == "wheel_down" then
      handled = self.text_mode and self:scroll(3) or self:go_to(self.page + 1)
    elseif ev.button == "wheel_up" then
      handled = self.text_mode and self:scroll(-3) or self:go_to(self.page - 1)
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
