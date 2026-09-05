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
  `cd Tests/python && uv run pytest`, all green, reported with actual output.
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
cd Tests/python && uv sync                  # once, or after dependency changes
cd Tests/python && uv run pytest            # L1 + L2 (liblsl comes with the pylsl wheel)
cd Tests/python && uv run pytest -m "not interop"   # L1 only
Scripts/build-docs.sh                       # DocC archive; must build without warnings
```

Run the Python suite on an otherwise quiet machine: the L1 mocks own the discovery port
range and fail on any stray LSL traffic, including a concurrent `soak.py`.

New public API is added deliberately, not by default. Anything needed across target
boundaries but not promised to a consumer is `package`; the published surface must stay
what SCOPE §7 and its deviations table describe. `swift package dump-symbol-graph
--minimum-access-level public` prints it.

## The family board

The owner-blocked queue for the whole family lives in **PWB**, at
`../PWB/.devtool/features/` — one kanban-markdown card per task (YAML
frontmatter, rendered by the LachyFS.kanban-markdown extension in VSCodium).
Labels say who is blocked — `owner-bench`, `owner-decision`, `agent`, `gated` —
and which repo owns the work.

**One board, not one per repo, because the bottleneck is one person.** NOW.md
still answers "where does this repo stand"; the board answers "where does the
owner stand", and that question does not decompose per repo.

Work done from here updates the cards there:

- **Move the card with the work.** Status changes travel in the same
  commit-sized unit as the change they describe; a card that closes moves to
  `done/` with `completedAt` set. A board updated in a later sweep is a board
  that reports yesterday.
- **A card is an index entry, never a copy.** The detail belongs in this repo's
  ROADMAP.md and its other records; the card names the goal, points at that
  section, and gives the next command. Copying detail into a card creates a
  second source of truth that drifts from the first.
- **Ask before adding a card.** New work appearing mid-task is normal and worth
  capturing, but what belongs on the owner's queue is the owner's judgement,
  not the agent's.

## The architecture gate

Family-wide architecture rules run as a pre-push hook in every repo. After
any structural change here — imports added, public types added, isolation
attributes changed — run
`swift test --package-path ../PWB/tools/arch/ArchRules`; fix or get a ruling,
never bypass silently. Setup and detail: `../PWB/TOOLING.md`.
