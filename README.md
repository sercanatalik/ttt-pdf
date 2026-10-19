# pdf-viewer for ttt

[![test](https://github.com/sercanatalik/ttt-pdf/actions/workflows/test.yml/badge.svg)](https://github.com/sercanatalik/ttt-pdf/actions/workflows/test.yml)

Quick-look PDFs inside [ttt](https://github.com/eugenioenko/ttt). Open a `.pdf` from the explorer or the command line and it shows one page at a time in an editor tab. Terminals with the Kitty graphics protocol (Kitty, Ghostty, WezTerm) show the rendered page, and so does [herdr](#inside-herdr). Other terminals, and tmux, show the page's text instead.

<p align="center">
  <img src="docs/screenshot.png" alt="A page of a research paper rendered inside a ttt editor tab in Ghostty, with the status line showing page 2/15 and the viewer's keys" width="640">
</p>

> **Status:** early. It needs ttt's plugin file handlers and image widget, added in [ttt 1.8.0](https://github.com/eugenioenko/ttt/releases/tag/v1.8.0). Older ttt versions keep showing PDFs as binary files.

## Requirements

- [ttt](https://github.com/eugenioenko/ttt) 1.8.0 or newer
- [poppler](https://poppler.freedesktop.org/) command-line tools: `pdfinfo`, `pdftoppm`, `pdftotext`

| Platform | Install poppler |
|----------|-----------------|
| macOS    | `brew install poppler` |
| Debian/Ubuntu | `sudo apt install poppler-utils` |
| Fedora   | `sudo dnf install poppler-utils` |

## Install

In ttt, run **Plugins: Install from URL** and enter `https://github.com/sercanatalik/ttt-pdf`, then approve the permissions.

Or clone it into your config directory:

```sh
git clone https://github.com/sercanatalik/ttt-pdf ~/.config/ttt/plugins/pdf-viewer
```

## Inside herdr

[herdr](https://herdr.dev) works too: the screenshot above is ttt running in a herdr pane, opened by ttt's own herdr plugin, **TTT Editor**.

1. Install the TTT Editor plugin for herdr:

   ```sh
   herdr plugin install eugenioenko/ttt/herdr-plugin
   ```

   It runs the `ttt` on your `PATH` with your normal ttt config, so install pdf-viewer [as above](#install). That `ttt` has to meet the [requirements](#requirements) too.

2. Turn on herdr's Kitty graphics support. It's experimental and needs herdr 0.5.9 or newer:

   ```toml
   # ~/.config/herdr/config.toml
   [experimental]
   kitty_graphics = true
   ```

   Restart herdr after changing it. Without it herdr doesn't draw images, so the page area stays empty; press `t` to read the page as text.

3. In herdr, open TTT Editor (the **Open TTT** action, or `herdr plugin pane open --plugin ttt.editor --entrypoint editor`) and open a PDF from the explorer.

## Keys

| Key | Action |
|-----|--------|
| `n` / `→` | Next page (next match while a search is active) |
| `p` / `←` | Previous page |
| `Space` / `PgDn` | Next screen: scrolls down the page in fit width, then continues on the next page |
| `b` / `PgUp` | Previous screen: scrolls up, then continues at the bottom of the previous page |
| `g` / `Home`, `G` / `End` | First / last page |
| `:` | Go to a page: a number, `$` for the last page, or `+N` / `-N` relative to the current one |
| `/` | Search the document (case-insensitive), including phrases that wrap onto the next line. Jumps to the first match on or after the current page and highlights the matches |
| `n` / `N` | Next / previous match, wrapping around the document |
| `Esc` | Clear the search, so `n` turns pages again |
| `w` | Switch between **fit page** (whole page visible) and **fit width** (page as wide as the tab, scroll vertically) |
| `j` / `k`, `↓` / `↑`, mouse wheel | Scroll (fit width and text); the wheel turns pages in fit page |
| `t` | Toggle between the page image and its text |
| `r` | Reload the file now. Usually not needed: the viewer reloads by itself when the PDF changes on disk |

## Permissions

| Permission | Why |
|------------|-----|
| `editor.file_handlers` | Open `.pdf` files (and files starting with `%PDF-`) in this viewer instead of the binary file card. |
| `keybindings` | Show the `:` go-to-page prompt (`ttt.command_line`). The plugin binds no global keys; its keys only work while a PDF tab is focused. |
| `events.file` | Know when a PDF tab closes, so it stops watching that file for changes. |
| `system.exec`: `pdfinfo`, `pdftoppm`, `pdftotext` | Read the page count and size, render a page to PNG (and draw search highlights on it), and extract a page's text and word positions. No other programs are run. |

The plugin reads no other files, makes no network requests, and stores nothing.

## How it works

- `pdfinfo` gives the page count when the file opens, then each page's size and rotation, so landscape and rotated pages in a portrait document fill the tab too.
- **Fit page** renders each page with `pdftoppm` at the largest resolution that fits the whole page in the tab, from the terminal's cell size in pixels. It's rounded down to a multiple of 8 so small resizes don't re-render, and kept between 24 and 300 DPI.
- **Fit width** picks the resolution that makes the page as wide as the tab and renders only the visible slice (`pdftoppm -x -y -W -H`), so tall pages never get rasterized in full. Scrolling renders the next slice, which is fetched ahead of time.
- The PNG goes to `panel:image`, which sends it to the terminal once. The current page and its neighbours stay cached, and the next page is rendered ahead of time.
- In text mode, `pdftotext -layout` extracts just the current page.
- **Search** extracts the whole document once with each word's position (`pdftotext -bbox-layout`) and matches the query against each page's words in reading order, so a phrase still matches when it wraps onto the next line. Text mode highlights the lines a match covers and the current match. In image mode the viewer jumps to the page, and in fit width it scrolls so the match sits a third of the way down the tab, unless it is already on screen. After an auto-reload the matches are recomputed.
- **Highlights** in image mode are drawn by poppler, since the image widget can't draw over a picture and the plugin can't encode a PNG fast enough itself. When a match is in view, `pdftoppm` renders that image again as raw pixels, the plugin wraps them in a one-page PDF with a yellow rectangle per matched line in multiply blend mode (so text stays dark), and `pdftoppm` renders that to the PNG that is shown. The word boxes come from `pdftotext -bbox-layout` for the page on screen. The plain image shows while the highlighted one renders, which takes about twice as long as a plain render.
- **Auto-reload:** while a PDF tab is open, `pdfinfo` runs once a second. Its output includes the page count, file size, page size and modification dates, so a rebuild changes it. A change is only applied once two checks in a row agree, and a check that fails (file missing or still being written) is ignored. That way a LaTeX build in progress never shows a broken page. The reload keeps your page, scroll position and fit mode, and the old image stays up until the new one is rendered.
- All poppler calls run asynchronously, so a slow page never blocks the editor. A reload drops results that were still in flight.

## Limitations

- One page at a time in fit page; fit width scrolls within a page and steps to the next one. No arbitrary zoom levels or links.
- Search doesn't match across pages, or join a word hyphenated at the end of a line (`exam-` / `ple` is found as `exam- ple`).
- In fit width each scroll step sends a new slice to the terminal. ttt 1.8.0 sends images as raw pixels, about 4 MB per screen at 1200 px wide, which is fine locally but slow over SSH; [eugenioenko/ttt#1020](https://github.com/eugenioenko/ttt/pull/1020) compresses them, to about 0.3 MB for a page of dense text. A screen with a search match is sent twice, plain and then highlighted.
- Page images need a terminal with the Kitty graphics protocol. They work inside herdr with `kitty_graphics` enabled, but not inside tmux.
- Password-protected PDFs (ones that need a password to open) aren't supported yet; the tab says so. PDFs that only restrict printing or copying open normally.
- Scanned PDFs have no text, so text mode shows nothing for them.

## Development

```sh
TTT_BIN=/path/to/ttt tests/run.sh
```

`tests/run.sh` installs the plugin into a throwaway config with its manifest permissions, then drives the real `ttt` binary:

- **Text mode**, headlessly with `--exec`: opening, paging and its bounds, go to page, search (jump, `n`/`N`, wrap, no match, `Esc`, a phrase across lines, a page with no text, scrolling to the match), reload, a corrupt file, an encrypted file, and missing poppler.
- **Image mode**, with `tests/kitty.py` (needs `python3`): it runs ttt in a pseudo-terminal that reports pixel sizes the way Ghostty does, drives it over `--listen` (port 4242 must be free), and decodes the Kitty graphics commands ttt sends. The checks cover fit page, fit width, scrolling across pages, mixed page sizes and rotation, scrolling to a search match in fit width and highlighting it (counted in the decoded pixels), that idle redraws send nothing, and auto-reload (a half-written file is ignored; a rebuilt one reloads in place). Decoded images land in the temp dir, which is handy when debugging.

`tests/make_fixture.py` regenerates the fixtures in `tests/fixtures/`.

## License

MIT
