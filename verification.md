# Manual verification

Everything below runs against **your real files**, which is why no agent may run it (see the
hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-vision-mcp
```

## 0 — Before you start

Build a sandbox you can delete afterwards:

```bash
mkdir -p ~/Documents/ZZTest
cp /path/to/a-photo-of-a-receipt.jpg ~/Documents/ZZTest/receipt.jpg
cp /path/to/a-blank-photo.jpg ~/Documents/ZZTest/blank.jpg
cp /path/to/a-scanned-document.pdf ~/Documents/ZZTest/scan.pdf
ln -s ~/Library ~/Documents/ZZTest/escape-hatch
```

You need one image with real text in it, one image with no text at all (to see the
"Vision recognised no text" path honestly), and one multi-page scanned PDF.

Configure the extension with:

- **read roots:** `~/Documents/ZZTest`

Restart Claude Desktop. Delete the whole `ZZTest` folder when you finish, symlink included.

## 1 — Status and the folder prompt

| Step | Call | Expected |
|---|---|---|
| 1.1 | `vision_status` | The root listed, canonicalised, probed as reachable. |
| 1.2 | First call touching `~/Documents` | macOS asks for Documents access, quoting the usage description. |
| 1.3 | Deny it, then `vision_ocr` | Refused, naming System Settings → Privacy & Security → Files and Folders. |
| 1.4 | Re-grant, restart, `vision_status` | Reachable again. |

## 2 — The boundary, which is the whole point

Every one of these must be **refused**. If any succeeds, stop.

| Step | Call | Expected |
|---|---|---|
| 2.1 | `vision_ocr` on `~/Documents/ZZTest/../../.ssh/config` | Refused as out of scope, showing the resolved path. |
| 2.2 | `vision_ocr` on `~/Library/Preferences/com.apple.finder.plist` | Refused. |
| 2.3 | `vision_ocr` on `~/Documents/ZZTest/escape-hatch/anything.jpg` | **Refused** — the symlink resolves to `~/Library`, which is outside the read root. |
| 2.4 | `vision_ocr` on `~/Documents/ZZTest-private/anything.jpg` | Refused. A shared name prefix is not containment. |

Step 2.3 is the one that would be quietly wrong if canonicalisation happened after
comparison rather than before.

## 3 — Reads inside scope

| Step | Call | Expected |
|---|---|---|
| 3.1 | `vision_ocr` on `receipt.jpg` | Recognised lines, source reported as "image". |
| 3.2 | `vision_ocr` on `blank.jpg` | Zero lines, and the response says so plainly rather than looking like an error. |
| 3.3 | `vision_ocr` on `scan.pdf` | Source reported as "pdf"; one page section per page. |
| 3.4 | `vision_ocr` on `scan.pdf` with `first_page`/`last_page` | Only that range is rendered and recognised. |
| 3.5 | `vision_ocr` with `languages: ["es-ES"]` on Spanish text | Compare accuracy against the same call with no `languages` given. |
| 3.6 | `vision_ocr` on a file that is neither a decodable image nor a PDF | Refused, naming the file rather than crashing. |

## 4 — The boundary with apple-pdf-mcp

| Step | Call | Expected |
|---|---|---|
| 4.1 | `pdf_read` (from apple-pdf-mcp) on `scan.pdf` | Refused, saying explicitly that the PDF has no text layer, pointing at `vision_ocr`. |
| 4.2 | `vision_ocr` on a PDF that DOES have a real text layer | Still works — it rasterizes and OCRs regardless — but compare the output against `pdf_read`'s and confirm `pdf_read` is the better tool for that file. |

This is the one design fork worth confirming by hand: this server renders pixels and
recognises text in them; it never reads a PDF's text, outline or metadata directly.

## 5 — Packaging

| Step | Command | Expected |
|---|---|---|
| 5.1 | `otool -P .build/release/apple-vision-mcp \| grep UsageDescription` | Desktop, Documents and Downloads keys present. |
| 5.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 5.3 | `codesign -dv extension/server/apple-vision-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 5.4 | Install, restart Claude Desktop | Two switches appear, one per tool. |

## 6 — Clean up

```bash
rm -rf ~/Documents/ZZTest
```

Then set the real read scope deliberately — it can be as generous as the sibling
filesystem server's read list, since this server never writes anything.
