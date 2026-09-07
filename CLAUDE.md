# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. Access is bounded by `read_roots`, configured per install.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real documents, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

Images and PDFs to run recognition against go under `$TMPDIR`, in a directory you made yourself — render or synthesise one there rather than reaching for a real document, and delete it in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) for OCR: reading text out of an image or a scanned PDF through `Vision`'s `VNRecognizeTextRequest`. No Finder, no Apple events, no network, no write of any kind.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-vision-mcp | grep UsageDescription
```
