# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. Access is bounded by `read_roots`, configured per install.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real documents, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

Images and PDFs to run recognition against go under `$TMPDIR`, in a directory you made yourself — render or synthesise one there rather than reaching for a real document, and delete it in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) for OCR and barcode reading: reading text, or QR codes and barcodes, out of an image or a scanned PDF through `Vision`'s `VNRecognizeTextRequest` and `VNDetectBarcodesRequest`. No Finder, no Apple events, no network, no write of any kind, **no third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot. `Deadline.swift` is a copy of the reference's `Deadline` until the shared file has it.

## Apple frameworks

[Vision](https://developer.apple.com/documentation/vision) — `VNRecognizeTextRequest` at `.accurate` with `usesLanguageCorrection` on, run through `VNImageRequestHandler`, reading `VNRecognizedTextObservation.topCandidates(1)`. Barcodes use `VNDetectBarcodesRequest` with its default of every supported symbology, reading `VNBarcodeObservation`'s `symbology`, `payloadStringValue` and `boundingBox`. [PDFKit](https://developer.apple.com/documentation/pdfkit) is a rasteriser only: `PDFDocument`, `PDFPage.draw(with:to:)`, and nothing else. [Image I/O](https://developer.apple.com/documentation/imageio) loads image files; [Core Graphics](https://developer.apple.com/documentation/coregraphics) provides the bitmap context.

## Native surface not used

- Every Vision request class except text recognition and barcode detection, including document segmentation, face and body analysis, classification, saliency, feature prints, and all tracking and registration.
- The newer Swift-only Vision API (`RecognizeTextRequest`, `RecognizeDocumentsRequest`). This repository uses the Objective-C `VN*` API.
- Every part of PDFKit except opening a document and drawing a page — no `PDFPage.string`, no `outlineRoot`, no `documentAttributes`. Reading a PDF's own text layer is out of scope for this repository; do not add it.
- Any write path at all. `VisionStore` exposes `canonicalise`, `probe`, the OCR call and the barcode call, and that is the whole protocol.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-vision-mcp | grep UsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
