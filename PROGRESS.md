# Project Progress

**Specification reviewed:** `obs/Specification.md`
**Plan approved by user:** Approved

## Phase 1 Tasks

 - [x] 1. Project Initialization
     - [x] Ensure Swift workspace builds on macOS 15.4+ (Swift 6)
     - [ ] Verify integration tests with fixture vault
- [x] 2. Core Data Model & Parsing
    - [x] Implement `ObsidianModel` package (stub target)
    - [x] Add unit tests for front‑matter
    - [x] Add unit tests for links
    - [x] Add unit tests for tasks
 - [ ] 3. Vault Indexer
     - Build `VaultIndex` crawler & SQLite schema
     - Support full and incremental scans with `--since`
     - Implement diffing logic for updated files
 - [ ] 4. Query Engine & Reporting
     - Create JSON/Markdown emitters for `agenda`, `daily-report`, etc.
     - Support `--json` flag
 - [ ] 5. GraphClient Calendar Integration
     - Stub `GraphClient` with OAuth/MSAL
     - Fetch events for `agenda` command
 - [ ] 6. CLI Entrypoints
     - Wire up commands using Swift Argument Parser
     - Add common flags (`--vault`, `--db`, etc.)
 - [ ] 7. LaunchAgent & Packaging
     - Add sample LaunchAgent plist (`support/`)
     - Document build & install instructions
 - [ ] 8. CI & Test Coverage
     - Setup GitHub Actions for macOS runner
     - Add coverage reporting and badge
 - [ ] 9. Phase‑1 Wrap‑up
     - Final review, bump to v0.1.0, tag release

 ---
 _Progress will be checked in and updated as tasks start and complete._

## Progress Log

 - 2025-04-23: Created `PROGRESS.md`; documented and logged Phase 1 plan after user approval.
 - 2025-04-23: Scaffolded Swift Package Manager support (Package.swift, obsTests); `swift build` passed.
 - 2025-04-23: Added `ObsidianModel` library target stub; updated `Package.swift`.
 - 2025-04-24: Implemented front-matter parsing (split + YAML) in ObsidianModel; added FrontMatterTests.
 - 2025-04-24: Added link parsing and task parsing in ObsidianModel; added LinkTests and TaskTests.