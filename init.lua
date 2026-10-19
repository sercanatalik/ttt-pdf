local ttt = require("ttt")
local sys = require("ttt.system")

local MIN_DPI, MAX_DPI, DPI_STEP = 24, 300, 8
local POLL_MS = 1000
local HINTS = "n/p page  : go to  / search  w fit  t text  r reload"
local SEARCH_HINTS = "n/N match  Esc clear"
-- Multiplied over the page, so text stays dark: the current match in yellow, the others on the page paler.
local HIGHLIGHT_CURRENT, HIGHLIGHT_OTHER = "1 0.84 0.2", "1 0.95 0.62"
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

local function exec_failure(binary, result, path)
  if result.stderr:find("Incorrect password", 1, true) then
    return basename(path) .. " is password-protected. pdf-viewer can't open encrypted PDFs yet."
  end
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

-- pdfinfo -f 1 -l N lists every page; a page rotated by 90 or 270 degrees renders with its width and height swapped.
local function parse_sizes(stdout)
  local sizes, rotations = {}, {}
  for page, w, h in stdout:gmatch("Page%s+(%d+) size:%s+([%d%.]+) x ([%d%.]+) pts") do
    sizes[tonumber(page)] = { tonumber(w), tonumber(h) }
  end
  for page, rot in stdout:gmatch("Page%s+(%d+) rot:%s+(%-?%d+)") do
    rotations[tonumber(page)] = tonumber(rot) % 360
  end
  for page, size in pairs(sizes) do
    if rotations[page] == 90 or rotations[page] == 270 then
      sizes[page] = { size[2], size[1] }
    end
  end
  return sizes
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

-- pdftotext ends every page with a form feed, so one extraction of the whole document splits back into pages.
local function split_pages(stdout, count)
  local pages, start = {}, 1
  for i = 1, count do
    local stop = stdout:find("\f", start, true)
    pages[i] = split_lines(stop and stdout:sub(start, stop - 1) or stdout:sub(start))
    start = stop and stop + 1 or #stdout + 1
  end
  return pages
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function unescape(text)
  return (text:gsub("&(%a+);", ENTITIES))
end

local function collapse(text)
  return (text:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function positions(text, marker)
  local list, from = {}, 1
  while true do
    local at = text:find(marker, from, true)
    if not at then
      return list
    end
    list[#list + 1] = at
    from = at + #marker
  end
end

-- pdftotext -bbox-layout lists each page's words in reading order, with boxes in points in the page's rendered orientation.
-- A page keeps its words joined into one lowercase string, so a phrase is found even when it wraps onto the next line,
-- plus where each word starts in that string, its top edge, and which of the page's lines it is on.
-- Parsing runs on the UI thread and a long document's XML runs to tens of megabytes, so it is one pass over the words
-- (in poppler's fixed attribute order), placed on their page and line by where the <page> and <line> tags are.
local function parse_words(stdout)
  stdout = stdout:lower()
  local page_at, line_at = positions(stdout, "<page "), positions(stdout, "<line ")
  local pages = {}
  for i = 1, #page_at do
    pages[i] = { parts = {}, starts = {}, ys = {}, line_of = {}, lines = {}, line_count = 0, pos = 1 }
  end
  local p, l = 0, 0
  for at, y, text in stdout:gmatch('()<word xmin="[^"]*" ymin="([^"]*)" xmax="[^"]*" ymax="[^"]*">([^<]*)</word>') do
    while page_at[p + 1] and page_at[p + 1] < at do
      p = p + 1
    end
    local page, new_line = pages[p], false
    while line_at[l + 1] and line_at[l + 1] < at do
      l, new_line = l + 1, true
    end
    if new_line then
      page.line_count = page.line_count + 1
    end
    text = unescape(text)
    local n = #page.parts + 1
    page.parts[n], page.starts[n], page.ys[n], page.line_of[n] = text, page.pos, tonumber(y), page.line_count
    page.pos = page.pos + #text + 1
  end
  for _, page in ipairs(pages) do
    local parts, first = page.parts, 1
    for n = 1, #parts do
      if page.line_of[n + 1] ~= page.line_of[n] then
        page.lines[#page.lines + 1] = table.concat(parts, " ", first, n)
        first = n + 1
      end
    end
    page.text = table.concat(parts, " ")
    page.parts, page.line_count, page.pos = nil, nil, nil
  end
  return pages
end

-- The word containing position pos of a page's text: the last one starting at or before it.
local function word_at(starts, pos)
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= pos then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

-- -layout and -bbox-layout come from the same text analysis, so each bbox line appears within one layout line
-- (a multi-column layout line holds one line from each column). Searching on from the last hit keeps repeated lines in order.
local function map_lines(lines, layout)
  local collapsed = {}
  for i, l in ipairs(layout) do
    collapsed[i] = collapse(l)
  end
  local map, cursor = {}, 1
  for n, text in ipairs(lines) do
    for k = 0, #collapsed - 1 do
      local i = (cursor - 1 + k) % #collapsed + 1
      if collapsed[i]:find(text, 1, true) then
        map[n], cursor = i, i
        break
      end
    end
  end
  return map
end

-- One page's word boxes in points, in the same order parse_words lists them.
local function parse_boxes(stdout)
  local boxes = {}
  for x0, y0, x1, y1 in stdout:gmatch('<word xMin="([^"]*)" yMin="([^"]*)" xMax="([^"]*)" yMax="([^"]*)">') do
    boxes[#boxes + 1] = { tonumber(x0), tonumber(y0), tonumber(x1), tonumber(y1) }
  end
  return boxes
end

-- Wraps a binary PPM from pdftoppm in a one-page PDF that draws it and multiplies highlight rectangles over it,
-- so pdftoppm tints and re-encodes it as a PNG: Lua here has no bit operations to compute PNG checksums cheaply.
-- rects are { x, y, w, h, color } in pixels from the image's top-left corner.
local function highlight_pdf(ppm, rects)
  local w, h, start = ppm:match("^P6%s+(%d+)%s+(%d+)%s+255%s()")
  if not w then
    return nil
  end
  local pixels = ppm:sub(start)
  local ops = { string.format("q %s 0 0 %s 0 0 cm /Im Do Q /M gs", w, h) }
  for _, r in ipairs(rects) do
    ops[#ops + 1] = string.format("%s rg %.2f %.2f %.2f %.2f re f", r[5], r[1], h - r[2] - r[4], r[3], r[4])
  end
  local content = table.concat(ops, " ")
  local objects = {
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    string.format("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Contents 4 0 R "
      .. "/Resources << /XObject << /Im 5 0 R >> /ExtGState << /M << /BM /Multiply >> >> >> >>", w, h),
    string.format("<< /Length %d >>\nstream\n%s\nendstream", #content, content),
    string.format("<< /Type /XObject /Subtype /Image /Width %s /Height %s /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length %d >>\nstream\n",
      w, h, #pixels) .. pixels .. "\nendstream",
  }
  local out, offsets, size = { "%PDF-1.4\n" }, {}, 9
  for i, body in ipairs(objects) do
    local obj = i .. " 0 obj\n" .. body .. "\nendobj\n"
    offsets[i] = string.format("%010d 00000 n \n", size)
    out[#out + 1] = obj
    size = size + #obj
  end
  out[#out + 1] = string.format("xref\n0 %d\n0000000000 65535 f \n%s", #objects + 1, table.concat(offsets))
  out[#out + 1] = string.format("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", #objects + 1, size)
  return table.concat(out)
end

-- Rounding down to DPI_STEP keeps small resizes from re-rendering; contain-fit never upscales, so a slightly smaller image still fits.
local function dpi_for(view, page, cols, rows, g)
  local w, h = view:page_size(page)
  local avail_w = cols * g.cell_w
  local avail_h = math.max(rows - 1, 1) * g.cell_h
  local dpi = math.min(avail_w / (w / 72), avail_h / (h / 72))
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
  self.sizes = {}
  self.error = nil
  self.images = {}
  self.shown = nil
  self.texts = {}
  self.boxes = {}
  self.doc = nil
  self.words = nil
  if self.search then
    self.search.matches = nil
  end
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
function View:run(binary, args, key, on_success, opts)
  if self.pending[key] then
    return
  end
  self.pending[key] = true
  local generation = self.generation
  sys.exec_async(binary, args, opts or {}, function(result)
    if generation ~= self.generation then
      return
    end
    self.pending[key] = nil
    if result.exit_code == 0 then
      on_success(result.stdout)
    else
      self.error = exec_failure(binary, result, self.path)
    end
    self:redraw()
  end)
end

function View:apply_info(stdout)
  local pages, w, h = parse_info(stdout)
  if not pages or pages < 1 then
    return false
  end
  self.fingerprint = stdout
  self.pages = pages
  self.page = math.min(self.page, pages)
  if w and h and w > 0 and h > 0 then
    self.width, self.height = w, h
  end
  return true
end

function View:page_size(page)
  local size = self.sizes[page]
  if size then
    return size[1], size[2]
  end
  return self.width, self.height
end

function View:load_sizes()
  self:run("pdfinfo", { "-f", "1", "-l", tostring(self.pages), self.path }, "sizes", function(stdout)
    self.sizes = parse_sizes(stdout)
  end)
end

function View:load_info()
  self:run("pdfinfo", { self.path }, "info", function(stdout)
    if self:apply_info(stdout) then
      self:load_sizes()
    else
      self.error = "pdfinfo did not report a page count for " .. basename(self.path)
    end
  end)
end

-- pdfinfo's output (page count, file size, page size, modification dates) changes whenever the file is rebuilt,
-- and is cheap enough to poll. A change only counts once two polls agree, so a half-written file is never loaded.
function View:poll()
  if self.polling then
    return
  end
  self.polling = true
  sys.exec_async("pdfinfo", { self.path }, function(result)
    self.polling = false
    if self.stopped or result.exit_code ~= 0 or result.stdout == self.fingerprint then
      self.candidate = nil
      return
    end
    if self.candidate ~= result.stdout then
      self.candidate = result.stdout
      return
    end
    self.candidate = nil
    self:refresh(result.stdout)
  end)
end

-- Unlike r, a refresh keeps the last image on screen until the new render arrives, so a rebuild never flashes an empty tab.
function View:refresh(stdout)
  local page = self.page
  self.generation = self.generation + 1
  self.pending = {}
  self.images = {}
  self.texts = {}
  self.boxes = {}
  self.doc = nil
  self.words = nil
  if self.search then
    self.search.matches = nil
  end
  self.sizes = {}
  self.error = nil
  if self:apply_info(stdout) then
    self:load_sizes()
  else
    self.error = "pdfinfo did not report a page count for " .. basename(self.path)
  end
  if self.page ~= page and self.shown then
    self.shown = nil
  end
  self:redraw()
end

function View:watch()
  self.timer = ttt.set_interval(POLL_MS, function() self:poll() end)
end

function View:stop()
  self.stopped = true
  if self.timer then
    ttt.clear_interval(self.timer)
    self.timer = nil
  end
end

function View:fetch(key, entry, args)
  if self.images[key] then
    return
  end
  self:run("pdftoppm", { "-png", unpack(args) }, key, function(stdout)
    entry.data = stdout
    self.images[key] = entry
  end)
end

-- An image is a cache key, the entry it is cached as, and the pdftoppm arguments that render it (without the output format).
local function page_image(view, page, dpi)
  local p = tostring(page)
  return "page:" .. page .. ":" .. dpi, { page = page, dpi = dpi, kind = "page", y = 0 },
    { "-r", tostring(dpi), "-f", p, "-l", p, view.path }
end

-- pdftoppm crops while rendering, so fit-width only ever rasterizes the visible slice of a page.
local function slice_image(view, page, dpi, y, w, h)
  local p = tostring(page)
  return "slice:" .. page .. ":" .. dpi .. ":" .. y .. ":" .. h, { page = page, dpi = dpi, kind = "slice", y = y },
    { "-r", tostring(dpi), "-f", p, "-l", p, "-x", "0", "-y", tostring(y), "-W", tostring(w), "-H", tostring(h), view.path }
end

function View:fetch_page(page, dpi)
  if page < 1 or page > self.pages then
    return
  end
  self:fetch(page_image(self, page, dpi))
end

function View:fetch_slice(page, dpi, y, w, h)
  self:fetch(slice_image(self, page, dpi, y, w, h))
end

-- Word boxes are only needed for the page on screen, so they come from a quick extraction of that page alone.
function View:page_boxes(page)
  local boxes = self.boxes[page]
  if not boxes then
    local p = tostring(page)
    self:run("pdftotext", { "-bbox-layout", "-f", p, "-l", p, self.path, "-" }, "boxes:" .. page, function(stdout)
      self.boxes[page] = parse_boxes(stdout)
    end)
  end
  return boxes
end

-- The rectangles covering each match on the page, one per line a match spans, in pixels from the top of an image rendered
-- at dpi starting y pixels down the page. Nil when no match shows in it or the page's boxes are not in yet.
function View:match_rects(page, dpi, y, h)
  local s = self.search
  local words = s and s.matches and self.words and self.words[page]
  local boxes = words and self:page_boxes(page)
  -- The two extractions should list the same words; if they disagree, a highlight could land on the wrong ones.
  if not boxes or #boxes ~= #words.starts then
    return nil
  end
  local scale, rects = dpi / 72, {}
  for i, m in ipairs(s.matches) do
    if m.page == page then
      local color = i == s.index and HIGHLIGHT_CURRENT or HIGHLIGHT_OTHER
      local n = m.first
      while n <= m.last do
        local x0, y0, x1, y1 = boxes[n][1], boxes[n][2], boxes[n][3], boxes[n][4]
        local line = words.line_of[n]
        while n < m.last and words.line_of[n + 1] == line do
          n = n + 1
          local b = boxes[n]
          x0, y0, x1, y1 = math.min(x0, b[1]), math.min(y0, b[2]), math.max(x1, b[3]), math.max(y1, b[4])
        end
        local top, bottom = (y0 - 1) * scale - y, (y1 + 1) * scale - y
        if bottom > 0 and top < h then
          rects[#rects + 1] = { (x0 - 1) * scale, top, (x1 - x0 + 2) * scale, bottom - top, color }
        end
        n = n + 1
      end
    end
  end
  return #rects > 0 and rects or nil
end

-- The highlighted version of an image renders it as a PPM and has pdftoppm draw that again with the matches tinted.
-- Returns its cache key, or nil when no match shows in the image.
function View:fetch_highlight(key, entry, args, h)
  local rects = self:match_rects(entry.page, entry.dpi, entry.y, h)
  if not rects then
    return nil
  end
  local s = self.search
  local hkey = "hl:" .. s.index .. ":" .. s.query .. ":" .. key
  if not self.images[hkey] then
    self:run("pdftoppm", args, "ppm:" .. hkey, function(ppm)
      local pdf = highlight_pdf(ppm, rects)
      if pdf then
        self:run("pdftoppm", { "-png", "-r", "72", "-" }, hkey, function(png)
          self.images[hkey] = { page = entry.page, dpi = entry.dpi, kind = entry.kind, y = entry.y, data = png }
        end, { stdin = pdf })
      end
    end)
  end
  return hkey
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

-- Search matches on the words and their positions; text mode shares the layout extraction, so a match's lines are the lines text mode shows.
function View:load_doc(on_ready)
  local function ready()
    if self.doc and self.words then
      on_ready()
    end
  end
  if not self.doc then
    self:run("pdftotext", { "-layout", self.path, "-" }, "doc", function(stdout)
      self.doc = split_pages(stdout, self.pages)
      ready()
    end)
  end
  if not self.words then
    self:run("pdftotext", { "-bbox-layout", self.path, "-" }, "words", function(stdout)
      self.words = parse_words(stdout)
      ready()
    end)
  end
  ready()
end

-- Every occurrence of needle on a page, with the top of its first word and the layout lines it covers.
function View:find_on_page(page, needle, matches)
  local words = self.words[page]
  local from, map = 1, nil
  while true do
    local s, e = words.text:find(needle, from, true)
    if not s then
      return
    end
    map = map or map_lines(words.lines, self.doc[page] or {})
    local first, last = word_at(words.starts, s), word_at(words.starts, e)
    local m = { page = page, y = words.ys[first], first = first, last = last, lines = {} }
    for n = words.line_of[first], words.line_of[last] do
      local line = map[n]
      if line then
        m.lines[line] = true
        m.line = math.min(m.line or line, line)
      end
    end
    table.insert(matches, m)
    from = e + 1
  end
end

-- stay recomputes matches after a reload without moving the view or announcing anything.
function View:search_for(query, stay)
  self.search = { query = query }
  self:load_doc(function()
    if not self.search or self.search.query ~= query then
      return
    end
    local needle = collapse(query)
    local matches = {}
    for page = 1, #self.words do
      self:find_on_page(page, needle, matches)
    end
    if #matches == 0 then
      self.search = nil
      if not stay then
        ttt.notify('No matches for "' .. query .. '" in ' .. basename(self.path), "warn")
      end
      return
    end
    self.search.matches = matches
    self.search.index = 1
    for i, m in ipairs(matches) do
      if m.page >= self.page then
        self.search.index = i
        break
      end
    end
    if not stay then
      self:show_match()
    end
  end)
end

function View:show_match()
  local m = self.search.matches[self.search.index]
  self:go_to(m.page)
  if m.line then
    self.text_offset = math.max(0, m.line - 3)
  end
  self.match_y = m.y
end

function View:step_match(delta)
  local s = self.search
  s.index = (s.index - 1 + delta) % #s.matches + 1
  self:show_match()
  return true
end

function View:prompt_search()
  if not (ttt.command_line and self.pages) then
    return false
  end
  ttt.command_line.show({
    prefix = "Search: ",
    text = self.search and self.search.query or "",
    on_submit = function(text)
      if text:match("%S") then
        self:search_for(text)
      else
        self.search = nil
      end
      self:redraw()
    end,
  })
  return true
end

-- Keeps what the next keypress is likely to need (neighbouring pages at their own resolution, nearby slices) so memory stays bounded on long documents.
-- expected(page) gives the resolution a page renders at now; nil (text mode) keeps only the current page.
function View:prune(expected, y, span)
  for key, entry in pairs(self.images) do
    local far_page = math.abs(entry.page - self.page) > 1
    local stale = entry.page ~= self.page and (not expected or entry.dpi ~= expected(entry.page))
    local far_slice = entry.kind == "slice" and y and (entry.page ~= self.page or math.abs(entry.y - y) > 2 * span)
    if far_page or stale or far_slice then
      self.images[key] = nil
    end
  end
  for _, cache in ipairs({ self.texts, self.boxes }) do
    for page in pairs(cache) do
      if math.abs(page - self.page) > 1 then
        cache[page] = nil
      end
    end
  end
end

-- While a render is in flight the last image shown stays up, but only for the same page and fit: a prefetched neighbouring slice would show the wrong part of the page.
-- A highlighted image is preferred to the plain one. While it renders, the image of the same view stays up if one is
-- (so moving to the next match on screen doesn't flash the page without highlights), and otherwise the plain one shows.
function View:image_for(key, kind, highlight)
  local exact = highlight and self.images[highlight]
  if not exact and highlight and self.shown and self.shown.key == key then
    return self.shown.data
  end
  exact = exact or self.images[key]
  if exact then
    self.shown = { page = self.page, kind = kind, key = key, data = exact.data }
    return exact.data
  end
  if self.shown and self.shown.page == self.page and self.shown.kind == kind then
    return self.shown.data
  end
end

function View:status_line(mode)
  local pages = self.pages and tostring(self.pages) or "?"
  local hints = HINTS
  local s = self.search
  if s and s.matches then
    hints = string.format('match %d/%d "%s"  %s', s.index, #s.matches, s.query, SEARCH_HINTS)
  elseif s then
    hints = 'searching for "' .. s.query .. '"...'
  end
  return string.format("%s  page %d/%s  [%s]  %s", basename(self.path), self.page, pages, mode, hints)
end

function View:render_page(panel, cols, rows, g)
  local function expected(page) return dpi_for(self, page, cols, rows, g) end
  local dpi = expected(self.page)
  self:prune(expected)
  self:fetch_page(self.page, dpi)
  if self.page < self.pages then
    self:fetch_page(self.page + 1, expected(self.page + 1))
  end
  local key, entry, args = page_image(self, self.page, dpi)
  local _, h = self:page_size(self.page)
  local png = self:image_for(key, "page", self:fetch_highlight(key, entry, args, math.ceil(h / 72 * dpi)))
  if png then
    panel:image({ data = png, alt = "Page " .. self.page .. " of " .. self.pages })
  else
    panel:label({ text = "Rendering page " .. self.page .. "...", style = "muted" })
  end
end

-- Layout runs before anything is drawn, so the status line and the key handlers read the same clamped scroll position.
function View:layout_width(cols, rows, g)
  local visible = math.max(rows - 1, 1)
  local w, h = self:page_size(self.page)
  local dpi = math.floor(cols * g.cell_w / (w / 72) / DPI_STEP) * DPI_STEP
  dpi = math.max(MIN_DPI, math.min(MAX_DPI, dpi))
  local page_h = math.floor(h / 72 * dpi)
  local total_rows = math.ceil(page_h / g.cell_h)
  local max_scroll = math.max(0, total_rows - visible)
  -- A search match knows where its first word is on the page. One already on screen stays put, so stepping between
  -- matches on the same screen only redraws the highlight; any other lands a third of the way down the tab.
  if self.match_y then
    local row = math.floor(self.match_y / 72 * dpi / g.cell_h)
    if row < self.scroll_rows or row >= self.scroll_rows + visible - 1 then
      self.scroll_rows = row - math.floor(visible / 3)
    end
    self.match_y = nil
  end
  self.scroll_rows = math.max(0, math.min(self.scroll_rows, max_scroll))
  self.layout = {
    visible = visible,
    max_scroll = max_scroll,
    dpi = dpi,
    slice_w = math.floor(w / 72 * dpi),
    span = visible * g.cell_h,
    y = self.scroll_rows * g.cell_h,
    last_y = max_scroll * g.cell_h,
  }
end

function View:render_width(panel)
  local l = self.layout
  self:prune(function() return l.dpi end, l.y, l.span)
  self:fetch_slice(self.page, l.dpi, l.y, l.slice_w, l.span)
  local next_y = math.min(l.y + l.span, l.last_y)
  if next_y > l.y then
    self:fetch_slice(self.page, l.dpi, next_y, l.slice_w, l.span)
  end
  local key, entry, args = slice_image(self, self.page, l.dpi, l.y, l.slice_w, l.span)
  local png = self:image_for(key, "slice", self:fetch_highlight(key, entry, args, l.span))
  if png then
    panel:image({ data = png, alt = "Page " .. self.page .. " of " .. self.pages })
  else
    panel:label({ text = "Rendering page " .. self.page .. "...", style = "muted" })
  end
end

function View:render_text(panel, rows)
  self:prune(nil)
  local lines = self.doc and self.doc[self.page]
  if not lines then
    self:fetch_text(self.page)
    lines = self.texts[self.page]
  end
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
  local s = self.search
  local styles = {}
  if s and s.matches then
    for i, m in ipairs(s.matches) do
      if m.page == self.page then
        for line in pairs(m.lines) do
          if i == s.index then
            styles[line] = "selected"
          elseif styles[line] ~= "selected" then
            styles[line] = "warning"
          end
        end
      end
    end
  end
  for i = self.text_offset + 1, math.min(#lines, self.text_offset + visible) do
    panel:label({ text = lines[i], style = styles[i] or "default" })
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
  if self.search and not self.search.matches and not self.pending.doc and not self.pending.words then
    self:search_for(self.search.query, true)
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

-- Accepts "12", "$" for the last page, and "+3" / "-2" relative to the current page.
function View:parse_target(text)
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "$" then
    return self.pages
  end
  local sign, digits = text:match("^([+-]?)(%d+)$")
  if not digits then
    return nil
  end
  local n = tonumber(digits)
  if sign == "+" then
    n = self.page + n
  elseif sign == "-" then
    n = self.page - n
  end
  if n >= 1 and n <= self.pages then
    return n
  end
end

function View:prompt_page()
  if not (ttt.command_line and self.pages) then
    return false
  end
  ttt.command_line.show({
    prefix = "Go to page (1-" .. self.pages .. "): ",
    on_submit = function(text)
      local target = self:parse_target(text)
      if target then
        self:go_to(target)
        self:redraw()
      elseif text:match("%S") then
        ttt.notify("No page " .. text .. " in " .. basename(self.path) .. " (1-" .. self.pages .. ")", "warn")
      end
    end,
  })
  return true
end

local function searching(v)
  return v.search and v.search.matches
end

local KEYS = {
  n = function(v)
    if searching(v) then
      return v:step_match(1)
    end
    return v:go_to(v.page + 1)
  end,
  N = function(v) return searching(v) and v:step_match(-1) or false end,
  ["/"] = function(v) return v:prompt_search() end,
  Esc = function(v)
    if v.search then
      v.search = nil
      return true
    end
    return false
  end,
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
  [":"] = function(v) return v:prompt_page() end,
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

-- ttt reports Escape as "Esc" (its plugin docs say "Escape"), so both names map to the same action.
local KEY_ALIASES = { Escape = "Esc" }

function View:on_event(ev)
  local handled = false
  if ev.type == "key" and (ev.mod == nil or ev.mod == "shift") then
    local action = KEYS[KEY_ALIASES[ev.key] or ev.key]
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

local views = {}

-- Polling has to stop when its tab closes; without the events.file permission (an older approval) auto-reload stays off rather than leak timers.
local watching = pcall(function()
  require("ttt.events").on("file.close", function(path)
    if views[path] then
      views[path]:stop()
      views[path] = nil
    end
  end)
end)

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
        if watching then
          if views[path] then
            views[path]:stop()
          end
          views[path] = view
          view:watch()
        end
        tab.render = function(panel) view:render(panel) end
        tab.on_event = function(ev) return view:on_event(ev) end
      end,
    },
  },
})
