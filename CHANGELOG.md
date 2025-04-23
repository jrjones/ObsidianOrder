# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2025-04-27
### Added
- ObsidianModel: front-matter, link, and task parsing with comprehensive unit tests.
- VaultIndex: full and incremental vault indexing into SQLite with integration tests and fixture vault.
- CLI (`obs`): commands for `index`, `daily-report`, `weekly-preview`, `agenda`, and `collections`.
- JSON and Markdown emitters for reports; `--json` flags supported.
- Collections commands (`ls` and `show`) using SQLite index.
- GraphClient stub and agenda integration stubbed.
- Sample LaunchAgent plist in `support/` and installation documented in README.
- GitHub Actions CI workflow with Swift build/test and Codecov coverage.