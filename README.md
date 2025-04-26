# Obsidian Order (obs)
<!---
![CI](https://github.com/jrjones/ObsidianOrder/actions/workflows/ci.yml/badge.svg)
[![codecov](https://codecov.io/gh/jrjones/ObsidianOrder/branch/main/graph/badge.svg)](https://codecov.io/gh/jrjones/ObsidianOrder)
--->
<img src="./support/oo-logo.webp" width="150" align="right">
`obs` is a headless CLI agent for indexing and reporting on your [Obsidian.md](https://obsidian.md) vault.

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
Defaults: `--vault (from config) `--db (from config).

```yaml
vault: /path/to/Obsidian      # default vault path
db:    /path/to/state.sqlite  # default database path
```
(See sample config file at [/support/config.yaml](support/config.yaml))

### Daily Report
```bash
.build/release/obs daily-report [--json] [-uo] 2025-01-01 
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

### Shell (interactive REPL)
Start an interactive SQL shell against your Obsidian index:
```bash
.build/release/obs shell [--db ~/.obsidian-order/state.sqlite]
```
Inside the prompt, you can use built-in commands (start with `\`) or any raw SQL. Results are truncated to 50 rows.

Built-in commands:
- `\q` or `\quit`      Exit the shell
- `\tables`             List all tables in the database
- `\desc <table>`       Show schema of a table (e.g. `\desc notes`)
- `\ask <query>`        (Future: LLM-powered search; currently a stub)

SQL examples:
- List 10 most-recent notes:
  ```sql
  SELECT id, title, modified
    FROM notes
    ORDER BY modified DESC
    LIMIT 10;
  ```
- Show incomplete tasks:
  ```sql
  SELECT note_id, line_no, text
    FROM tasks
    WHERE state = 'todo';
  ```
- Count today's calendar events:
  ```sql
  SELECT COUNT(*)
    FROM calendar
    WHERE date(start) = date('now');
  ```

## LaunchAgent Installation
To run the indexer periodically via `launchd`:
```bash
mkdir -p ~/Library/LaunchAgents
cp support/com.jrj.obs.indexer.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jrj.obs.indexer.plist
```
## Config and Requirements
You will need to set up a configuration file. There's a sample in /support

We will avoid smart defaults for config values - too much risk of hitting an external model with confidential data or touching the wrong obsidian vault. Get the config right.

You also need to have an ollama install, on localhost or the local network. It will need a few models:

summit or summit-small 
deepseek-r1:70b or deepseek-r1:latest
nomic-embed (based on nomic-embed-text)
Model files will be provided as things stabilize

## Support
- Sample LaunchAgent plist: `support/com.jrj.obs.indexer.plist`
- Sample config file: `config.yaml` (default location: ~/.config/obsidian-order/config.yaml)
- nomic-embed.modelfile

Needed:

- summit.modelfile
- summit-small.modelfile

## Appendix: Name
Yes, it's a [star trek reference](https://memory-alpha.fandom.com/wiki/Obsidian_Order).

