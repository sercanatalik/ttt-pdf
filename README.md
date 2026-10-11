# pdf-viewer for ttt

Quick-look PDFs inside [ttt](https://github.com/eugenioenko/ttt). Open a `.pdf` from the explorer or the command line and it shows one page at a time in an editor tab. Terminals with the Kitty graphics protocol (Kitty, Ghostty, WezTerm) show the rendered page. Other terminals, and tmux, show the page's text instead.

```
paper.pdf  page 3/12  [image]  n/p page  g/G first/last  t text  r reload
```

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
| `n`, `Space`, `PgDn`, `→`, wheel down | Next page |
| `p`, `b`, `PgUp`, `←`, wheel up | Previous page |
| `g` / `Home` | First page |
| `G` / `End` | Last page |
| `t` | Toggle between the page image and its text |
| `j` / `k`, `↓` / `↑` | Scroll the text view |
| `r` | Reload the file (after rebuilding a LaTeX document, for example) |

## Permissions

| Permission | Why |
|------------|-----|
| `editor.file_handlers` | Open `.pdf` files (and files starting with `%PDF-`) in this viewer instead of the binary file card. |
| `system.exec`: `pdfinfo`, `pdftoppm`, `pdftotext` | Read the page count and size, render a page to PNG, and extract a page's text. No other programs are run. |

The plugin reads no other files, makes no network requests, and stores nothing.

## How it works

- `pdfinfo` gives the page count and page size when the file opens.
- Each page is rendered by `pdftoppm` at a resolution that fits the tab: tab width × the terminal's cell width in pixels ÷ page width in inches. It's rounded down to a multiple of 8 so small resizes don't re-render, and kept between 24 and 300 DPI.
- The PNG goes to `panel:image`, which sends it to the terminal once. The current page and its neighbours stay cached, and the next page is rendered ahead of time.
- In text mode, `pdftotext -layout` extracts just the current page.
- All poppler calls run asynchronously, so a slow page never blocks the editor. A reload drops results that were still in flight.

## Limitations

- One page at a time; no continuous scroll, zoom, search, or links.
- Page images need a terminal with the Kitty graphics protocol, outside tmux.
- The resolution is based on the first page's size; documents that mix page sizes still fit, but pages that differ in size can render smaller.
- Scanned PDFs have no text, so text mode shows nothing for them.

## Development

```sh
TTT_BIN=/path/to/ttt tests/run.sh
```

`tests/run.sh` installs the plugin into a throwaway config with its manifest permissions, then drives the real `ttt` binary headlessly with `--exec`: opening, paging and its bounds, reload, a corrupt file, and missing poppler. Headless runs have no graphics, so check image mode by hand in Kitty, Ghostty or WezTerm. `tests/make_fixture.py` regenerates `tests/fixtures/sample.pdf`.

## License

MIT
