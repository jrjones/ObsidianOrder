# Obsidian Order (obs)

![CI](https://github.com/jrjones/ObsidianOrder/actions/workflows/ci.yml/badge.svg)
[![codecov](https://codecov.io/gh/jrjones/ObsidianOrder/branch/main/graph/badge.svg)](https://codecov.io/gh/jrjones/ObsidianOrder)

`obs` is a headless CLI agent for indexing and reporting on your Obsidian vault.

## Requirements
- Swift 6
- macOS 15.4+

## Build
```bash
git clone git@github.com:jrj/obsidian-order.git
cd obsidian-order
swift build -c release
```

## Usage

Replace `obs` with the built binary at `.build/release/obs` or install to `/usr/local/bin/obs`.

### Index a Vault
```bash
.build/release/obs index --vault ~/Obsidian --db ~/.obsidian-order/state.sqlite
```
Defaults: `--vault ~/Obsidian`, `--db ~/.obsidian-order/state.sqlite`.

### Daily Report
```bash
.build/release/obs daily-report [--json]
```
  
### Agenda
```bash
.build/release/obs agenda [--json]
```

### Weekly Preview
```bash
.build/release/obs weekly-preview [--json]
```

### Collections
List collections:
```bash
.build/release/obs collections ls [--db <path>]
```
Show a collection:
```bash
.build/release/obs collections show <name> [--db <path>]
```

## LaunchAgent Installation
To run the indexer periodically via `launchd`:
```bash
mkdir -p ~/Library/LaunchAgents
cp support/com.jrj.obs.indexer.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jrj.obs.indexer.plist
```

## Support
- Sample LaunchAgent plist: `support/com.jrj.obs.indexer.plist`
```
