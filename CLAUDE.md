# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S FILES ARE NOT YOURS TO CHANGE

**It is FORBIDDEN to create, modify, move, trash or tag any file outside this repository.**
This rule outranks every other instruction in this file. It applies to every agent and every
session, with no "just this once" and no putting-it-back-afterwards.

This server exists to bound what a program may touch. An agent that reaches around it —
opening a file with `Vision` or `PDFKit` directly, shelling out, or "just checking"
something in the home directory — has defeated the only thing the repository is for.

Never:

- read or otherwise touch any real path outside this repository, by any route, including
  plain shell commands;
- run `vision_ocr` against a real path to test it: `PathScopeTests` covers every case
  with a modelled scope;
- widen `readRoots` in a committed default;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A temporary directory the agent created
itself — under `$TMPDIR`, never under `~` — may be written to and read from freely, provided
it is deleted in the same session.

**Fixtures first, always.** The store double in `PathScopeTests` **throws from every method
except `canonicalise`**. That is deliberate: a scope test that accidentally reached a real
file must fail loudly rather than quietly pass. Keep it that way.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests model the scope; they never touch a real file |
| `initialize`, `tools/list` over stdio | Protocol only; no path is resolved |
| `ls`, `stat` inside this repository | Read-only, in scope |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against real files remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) for OCR: reading text out of an image or a
scanned PDF through `Vision`'s `VNRecognizeTextRequest`. No Finder, no Apple events, no
network, no write of any kind.

**This package requires macOS 26** (`platforms: [.macOS("26.0")]`), matching every other
server in this family. Note that `.v26` does not exist as a `PackageDescription` case in
this toolchain; the string form is required.

This is one of a 4-way split of what used to be `apple-filesystem-mcp`'s combined
FileManager + Spotlight + PDFKit + Vision surface — see `apple-filesystem-split-plan.md`
(an external, unversioned planning document that lives in `~/Code/`, alongside this
repository rather than inside it) for the reasoning.

## `PDFKit` here is a rasterizer, never a reader

`SystemVisionStore.render(_:)` uses `PDFKit` for exactly one thing: turning a `PDFPage`
into a `CGImage` so Vision has pixels to recognise text in. It never touches
`document.string`, `document.outlineRoot` or `document.documentAttributes`. That is
`apple-pdf-mcp`'s `PDFStore`, a distinct protocol in a distinct repository with its own
allow-list.

**Do not add PDF text/outline/metadata to this server.** The moment `vision_ocr` (or a
new tool) starts returning a PDF's own text layer rather than pixels run through OCR,
this repository has drifted back into the domain-mixing shape the split was written to
undo — see `apple-filesystem-split-plan.md` §4 (in `~/Code/`, not in this repository)
for the reasoning behind keeping the two apart. If a caller needs both a PDF's text layer and OCR
of a scanned page in the same PDF, that is two tool calls, one to each server, not a
merged tool here.

## Architecture

`Sources/VisionMCPCore` holds everything; `Sources/apple-vision-mcp/main.swift` is a
launcher that exists only because a Swift executable target cannot be imported by a test
target.

**`PathScope` is the point of the repository.** One small file with one exported
operation: turn a string the model wrote into a `ScopedPath`, or refuse.

**`ScopedPath`'s initialiser is `fileprivate` to `PathScope.swift`.** No other code in the
module can mint one, so a store method that takes a path can only ever be handed a path
that came through the allow-list. Forgetting the check is a **compile error**, not an
escape — and the tests cannot skip past the guard either. Do not relax that access level,
and do not add a second way to construct one.

## Invariants worth protecting

- **Canonicalise first, then compare. The order is not negotiable.** Comparing the raw
  string would let `~/Documents/../../../etc` and a symlink pointing out of the tree both
  pass a prefix test while landing somewhere else entirely.
- **The roots are canonicalised too.** `/tmp` is a symlink to `/private/tmp`, so a root
  compared raw would reject every path that resolved through it.
- **Containment is by path component, not by string prefix.** `Documents-private` is not
  inside `Documents`.
- **This server has no write of any kind and never will.** `VisionStore` has no write
  method, full stop.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## `read_roots` is the one settings exception in this family

Every sibling server (WhatsApp, Messages, Mail, Calendar, Notes, …) had its `user_config`
settings removed in favour of plug-and-play: constants in code, with only the per-tool
allow/ask/prohibit switch left as a control. This server — like `apple-filesystem-mcp`,
`apple-spotlight-mcp` and `apple-pdf-mcp` — is the deliberate exception. `read_roots` is
not a preference to default away — it is the security boundary itself. Do not remove
this setting to make the server "consistent" with the plug-and-play ones; that
inconsistency is intentional.

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce
`dist/apple-vision-mcp.mcpb`. The manifest's `tools` array creates the per-tool switches
in Claude Desktop and is read before the server has ever run.

`read_roots` is a `multiple: true` directory setting, passed as `--read-roots …`.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject**. The embedded `Resources/Info.plist` declares the folder usage
descriptions — Desktop, Documents, Downloads, removable and network volumes — without
which macOS denies access **without ever prompting**.

Those prompts are per-folder and appear the first time a path inside one is touched. A
root that is configured but never reached will not prompt, which is why `vision_status`
probes every root and reports what it found.

**A linker-signed binary gets no TCC prompt at all.** `pack.sh` re-signs and prints the
designated requirement; an empty line there means the build is broken in a way nothing
else will show.
