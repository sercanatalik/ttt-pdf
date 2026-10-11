# pdf-viewer for ttt

[![test](https://github.com/sercanatalik/ttt-pdf/actions/workflows/test.yml/badge.svg)](https://github.com/sercanatalik/ttt-pdf/actions/workflows/test.yml)

Quick-look PDFs inside [ttt](https://github.com/eugenioenko/ttt). Open a `.pdf` from the explorer or the command line and it shows one page at a time in an editor tab. Terminals with the Kitty graphics protocol (Kitty, Ghostty, WezTerm) show the rendered page. Other terminals, and tmux, show the page's text instead.

<p align="center">
  <img src="docs/screenshot.png" alt="A page of a research paper rendered inside a ttt editor tab in Ghostty, with the status line showing page 2/15 and the viewer's keys" width="640">
</p>

> **Status:** early. It needs a ttt build with plugin file handlers and the image widget, proposed in [eugenioenko/ttt#813](https://github.com/eugenioenko/ttt/issues/813). Older ttt versions keep showing PDFs as binary files.

## Requirements

- ttt with plugin file handlers (and `ttt.graphics()` for page images)
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

## Keys

| Key | Action |
|-----|--------|
| `n` / `→` | Next page |
| `p` / `←` | Previous page |
| `Space` / `PgDn` | Next screen: scrolls down the page in fit width, then continues on the next page |
| `b` / `PgUp` | Previous screen: scrolls up, then continues at the bottom of the previous page |
| `g` / `Home`, `G` / `End` | First / last page |
| `:` | Go to a page: a number, `$` for the last page, or `+N` / `-N` relative to the current one |
| `w` | Switch between **fit page** (whole page visible) and **fit width** (page as wide as the tab, scroll vertically) |
| `j` / `k`, `↓` / `↑`, mouse wheel | Scroll (fit width and text); the wheel turns pages in fit page |
| `t` | Toggle between the page image and its text |
| `r` | Reload the file (after rebuilding a LaTeX document, for example) |

## Permissions

| Permission | Why |
|------------|-----|
| `editor.file_handlers` | Open `.pdf` files (and files starting with `%PDF-`) in this viewer instead of the binary file card. |
| `keybindings` | Show the `:` go-to-page prompt (`ttt.command_line`). The plugin binds no global keys; its keys only work while a PDF tab is focused. |
| `system.exec`: `pdfinfo`, `pdftoppm`, `pdftotext` | Read the page count and size, render a page to PNG, and extract a page's text. No other programs are run. |

The plugin reads no other files, makes no network requests, and stores nothing.

## How it works

- `pdfinfo` gives the page count and page size when the file opens.
- **Fit page** renders each page with `pdftoppm` at the largest resolution that fits the whole page in the tab, from the terminal's cell size in pixels. It's rounded down to a multiple of 8 so small resizes don't re-render, and kept between 24 and 300 DPI.
- **Fit width** picks the resolution that makes the page as wide as the tab and renders only the visible slice (`pdftoppm -x -y -W -H`), so tall pages never get rasterized in full. Scrolling renders the next slice, which is fetched ahead of time.
- The PNG goes to `panel:image`, which sends it to the terminal once. The current page and its neighbours stay cached, and the next page is rendered ahead of time.
- In text mode, `pdftotext -layout` extracts just the current page.
- All poppler calls run asynchronously, so a slow page never blocks the editor. A reload drops results that were still in flight.

## Limitations

- One page at a time in fit page; fit width scrolls within a page and steps to the next one. No arbitrary zoom levels, search, or links.
- In fit width each scroll step sends a new slice to the terminal (about 1 MB per screen at 1200 px wide), which is fine locally but slow over SSH.
- Page images need a terminal with the Kitty graphics protocol, outside tmux.
- The resolution is based on the first page's size; documents that mix page sizes still fit, but pages that differ in size can render smaller.
- Scanned PDFs have no text, so text mode shows nothing for them.

## Development

```sh
TTT_BIN=/path/to/ttt tests/run.sh
```

`tests/run.sh` installs the plugin into a throwaway config with its manifest permissions, then drives the real `ttt` binary:

- **Text mode**, headlessly with `--exec`: opening, paging and its bounds, go to page, reload, a corrupt file, and missing poppler.
- **Image mode**, with `tests/kitty.py` (needs `python3`): it runs ttt in a pseudo-terminal that reports pixel sizes the way Ghostty does, drives it over `--listen` (port 4242 must be free), and decodes the Kitty graphics commands ttt sends. The checks cover fit page, fit width, scrolling across pages, and that idle redraws send nothing. Decoded images land in the temp dir, which is handy when debugging.

`tests/make_fixture.py` regenerates `tests/fixtures/sample.pdf`.

## License

MIT
