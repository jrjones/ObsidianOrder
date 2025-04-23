# Obsidian Order / (`obs`) -- Phase-1 Specification
Read-only CLI agent for JRJ's Obsidian vault

Target: **Swift 6**, Swift-Argument-Parser, **macOS 15.4+******

## 1. Scope of Phase 1

| **Goal** | **Deliverable** | 
| ---- | ----  |
| Zero-touch **index & query** of the vault | Fast SQLite manifest (state.sqlite) updated on demand or by launchd. | 
| **No file mutations** yet | All operations are read-only previews. | 
| Run headless on JRJ's always-on desktop Mac | CLI binary (obs) plus sample LaunchAgent plist. | 


## 2. High-level architecture
```
    ┌──────────┐    scan/update     ┌──────────────┐
    │  obs CLI │ ───────────────▶   │  Index DB    │  (SQLite)
    │ (Swift)  │ ◀───────────────   └──────────────┘
    └──────────┘    query/report
```

- **Indexer** -- walks vault, parses front-matter + links + tasks.
- **Query engine** -- produces JSON/markdown reports (daily, weekly, collections, etc.).
- **CLI** -- sub-commands exposed via Swift Argument Parser.
- **Scheduler** -- launchd plist calling obs index --since 15m every 15 min.

## 3. Command-line interface
```
    obs <command> [options]
    
    Commands (Phase-1)
      index           Scan vault, refresh SQLite manifest
      agenda          Print today's calendar pulled from Graph  (read-only)
      daily-report    Merge today's notes, tasks, meetings → stdout
      weekly-preview  Render ISO-week dashboard (no file write)
      collections ls  List all notes tagged 'collection'
      collections show <name>
      help, version

Common flags
    
    
    --vault <path>      Defaults to ~/Obsidian
    --db    <path>      Defaults to ~/.obsidian-order/state.sqlite
    --since <ISO-datetime>  (index only) scan incrementally
    --json              Output raw JSON instead of markdown
```
  
## 4. Modules / packages

| **Package** | **Responsibility** | **3rd-party deps** | 
| ---- | ---- | ----  |
| **ObsidianModel** | Markdown front-matter parsing, task/entity structs | _Yams_ (YAML), _SwiftMarkdown_ | 
| **VaultIndex** | File crawler, SQLite adapter, diffing | _SQLite.swift_ | 
| **GraphClient** | Thin wrapper around MSAL + /me/calendarView | _MSAL.swift_ (OAuth) | 
| **Reporting** | Templated markdown / JSON emitters | None | 
| **obs** (CLI) | Swift-Argument-Parser entry points | _swift-argument-parser_ | 

All packages live in one workspace (ObsidianOrder).

## 5. Data model (SQLite)
```    
    notes(id PK, path, title, created, modified, tags TEXT, is_daily BOOL, is_meeting BOOL)
    links(from_id, to_title)
    tasks(id PK, note_id, line_no, text, state ENUM)
    assets(id PK, path, sha256, byte_size)
    calendar(id PK, uid, start, end, title, location, is_virtual)
```
  
## 6. LaunchAgent template

`~/Library/LaunchAgents/com.jrj.obs.indexer.plist`

```xml
    <plist version="1.0">
      <dict>
        <key>Label</key> <string>com.jrj.obs.indexer</string>
        <key>ProgramArguments</key>
          <array><string>/usr/local/bin/obs</string><string>index</string></array>
        <key>StartInterval</key><integer>900</integer> <!-- 15 min -->
        <key>RunAtLoad</key><true/>
        <key>StandardOutPath</key><string>/tmp/obs.log</string>
        <key>StandardErrorPath</key><string>/tmp/obs.log</string>
      </dict>
    </plist>
```

## 7. Build & run
```bash    
    git clone git@github.com:jrj/obsidian-order.git
    cd obsidian-order
    swift build -c release
    ./.build/release/obs index --vault ~/Obsidian
    ./.build/release/obs daily-report
```
  
## **8. Testing**

- **Unit tests** using SwiftTesting for Markdown parsing, index diffing, date windows.
- **Integration test** fixture vault in Tests/Fixtures checked into repo.
- Continuous integration via GitHub Actions (macOS 14 runner).
* * *

## 9. Future phases (outline only)

 1. **Phase 2** -- safe write-ops behind --apply flag (snapshot freezing, collection updates).

 2. **Phase 3** -- bidirectional task sync, Porcupine wake-word, voice interface.

 3. **Phase 4** -- GUI menubar wrapper / merge with Plogger.

## 10. Project conventions

- Default branch **main**; agent runs create feature branches (Phase 2).
- Semantic versioning 0.x until writable features ship.
- All code under MIT license unless corporate policy dictates otherwise.
