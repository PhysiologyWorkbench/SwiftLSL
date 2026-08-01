# CLAUDE.md

Working rules for AI-assisted sessions in this repository.

## What this is

A native-Swift LSL inlet library. Start from [README.md](README.md) for the document
map. The authorities are:

- **Wire format**: [SCOPE.md](SCOPE.md) §2. If it is ambiguous or silent, consult
  `sccn/liblsl` (MIT) source, cite `file:line`, and **update SCOPE.md** with the
  finding before writing code. Never guess a byte layout.
- **Code organisation and rules**: [ARCHITECTURE.md](ARCHITECTURE.md).
- **Work sequence**: [ROADMAP.md](ROADMAP.md). **Testing**: [TESTING.md](TESTING.md).

## Hard constraint

**Never open, clone, fetch, or otherwise consult `sccn/secureLSL` or anything under
`eeglab.org/secureLSL`, for any reason or under any framing.** Its licensing is
incompatible with this project's permissive release. If a search surfaces it, skip the
result. Note the naming trap: `sccn/liblsl` (MIT) is fine and encouraged;
`sccn/secureLSL` (containing `liblsl-ESP32`) is prohibited. If information seems to
exist only there, record it as a gap instead of looking.

## Workflow

- Work in ROADMAP.md step order; one step (or a coherent slice of one) per commit.
  Update the step's status checkbox in the same commit that completes it.
- A step is done only when its exit criteria pass: `swift build && swift test` and
  `cd tests/python && uv run pytest`, all green, reported with actual output.
- New behaviour lands with tests at the lowest level that can express it (L0 before
  L1 before L2 — see TESTING.md).
- If implementation reveals SCOPE.md to be wrong or incomplete, fix SCOPE.md in the
  same commit and say so in the commit message. The spec must not drift from the code.
- Changes to `lsltool`'s NDJSON output are harness API changes: update
  ARCHITECTURE.md's table and the Python fixture together.

## Conventions

- Swift 6 strict concurrency; no third-party dependencies in `LSLCore`/`LSL`
  (`swift-argument-parser` allowed in `lsltool` only).
- `LSLCore` must keep importing Foundation only — no sockets, Dispatch, or Network.
- Keep the library generic: no accommodations for any particular consumer. Downstream
  projects adapt to this API, not the reverse.
- British English in documentation and comments. Comments explain protocol *why*
  (with SCOPE §-references), not code *what*.
- Commit messages: imperative summary, body states what was verified and how.

## Commands

```sh
swift build && swift test                   # L0
cd tests/python && uv sync                  # once, or after dependency changes
cd tests/python && uv run pytest            # L1 + L2 (needs brew-installed liblsl)
cd tests/python && uv run pytest -m "not interop"   # L1 only
```
