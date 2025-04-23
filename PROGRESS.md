# Project Progress

**Specification reviewed:** `obs/Specification.md`
**Plan approved by user:** Approved

## Phase 1 Tasks

- [x] 1. Project Initialization
    - [x] Ensure Swift workspace builds on macOS 15.4+ (Swift 6)
    - [x] Verify integration tests with fixture vault
- [x] 2. Core Data Model & Parsing
    - [x] Implement `ObsidianModel` package (stub target)
    - [x] Add unit tests for front‑matter
    - [x] Add unit tests for links
    - [x] Add unit tests for tasks
 - [x] 3. Vault Indexer
     - [x] Build `VaultIndex` crawler & SQLite schema
     - [x] Support full and incremental scans with `--since`
     - [x] Implement diffing logic for updated files
 - [x] 4. Query Engine & Reporting
     - [x] Create JSON/Markdown emitter for `daily-report`
     - [x] Create JSON/Markdown emitters for `agenda`, `weekly-preview`, etc.
     - [x] Support `--json` flag for `daily-report`
- [x] 5. GraphClient Calendar Integration
     - Stub `GraphClient` with OAuth/MSAL
     - Fetch events for `agenda` command
 - [x] 6. CLI Entrypoints
     - Wire up commands using Swift Argument Parser
     - Add common flags (`--vault`, `--db`, etc.)
 - [x] 7. LaunchAgent & Packaging
     - [x] Add sample LaunchAgent plist (`support/`)
     - [x] Document build & install instructions
 - [x] 8. CI & Test Coverage
     - [x] Setup GitHub Actions for macOS runner
     - [x] Add coverage reporting and badge
 - [x] 9. Phase‑1 Wrap‑up
     - Final review, bump to v0.1.0, tag release

 ---
 _Progress will be checked in and updated as tasks start and complete._

## Progress Log

 - 2025-04-23: Created `PROGRESS.md`; documented and logged Phase 1 plan after user approval.
 - 2025-04-23: Scaffolded Swift Package Manager support (Package.swift, obsTests); `swift build` passed.
 - 2025-04-23: Added `ObsidianModel` library target stub; updated `Package.swift`.
 - 2025-04-24: Implemented front-matter parsing (split + YAML) in ObsidianModel; added FrontMatterTests.
 - 2025-04-24: Added link parsing and task parsing in ObsidianModel; added LinkTests and TaskTests.
 - 2025-04-24: Added `VaultIndex` module with SQLite schema and full-scan support; wrote basic integration test.
 - 2025-04-25: Extended `VaultIndex` for incremental scans (`--since`) and diffing logic (updating changed files, removing deleted).
 - 2025-04-25: Implemented CLI skeleton with Swift Argument Parser, commands, and common flags.
 - 2025-04-26: Added sample LaunchAgent plist under `support/` and created `README.md` with build, usage, and launch agent instructions
 - 2025-04-27: Added GitHub Actions CI workflow with build, test, and Codecov coverage upload
