# Obsidian Order / (`obs`)
Read-only CLI agent for JRJ's Obsidian vault

Target: **Swift 6**, Swift-Argument-Parser, **macOS 15.4+******

## Phase 1

### 1. Scope of Phase 1

| **Goal**                                      | **Deliverable**                                                       | 
| --------------------------------------------- | --------------------------------------------------------------------- |
| Zero-touch **index & query** of the vault     | Fast SQLite manifest (state.sqlite) updated on demand or by launchd.  | 
| **No file mutations** yet                     | All operations are read-only previews.                                | 
| Run headless on JRJ's always-on desktop Mac   | CLI binary (obs) plus sample LaunchAgent plist.                       | 


### 2. High-level architecture
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

### 3. Command-line interface
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
  
### 4. Modules / packages

| **Package** | **Responsibility** | **3rd-party deps** | 
| ---- | ---- | ----  |
| **ObsidianModel** | Markdown front-matter parsing, task/entity structs | _Yams_ (YAML), _SwiftMarkdown_ | 
| **VaultIndex** | File crawler, SQLite adapter, diffing | _SQLite.swift_ | 
| **GraphClient** | Thin wrapper around MSAL + /me/calendarView | _MSAL.swift_ (OAuth) | 
| **Reporting** | Templated markdown / JSON emitters | None | 
| **obs** (CLI) | Swift-Argument-Parser entry points | _swift-argument-parser_ | 

All packages live in one workspace (ObsidianOrder).

### 5. Data model (SQLite)
```    
    notes(id PK, path, title, created, modified, tags TEXT, is_daily BOOL, is_meeting BOOL)
    links(from_id, to_title)
    tasks(id PK, note_id, line_no, text, state ENUM)
    assets(id PK, path, sha256, byte_size)
    calendar(id PK, uid, start, end, title, location, is_virtual)
```
  
### 6. LaunchAgent template

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

### 7. Build & run
```bash    
    git clone git@github.com:jrj/obsidian-order.git
    cd obsidian-order
    swift build -c release
    ./.build/release/obs index --vault ~/Obsidian
    ./.build/release/obs daily-report
```
  
### **8. Testing**

- **Unit tests** using SwiftTesting for Markdown parsing, index diffing, date windows.
- **Integration test** fixture vault in Tests/Fixtures checked into repo.
- Continuous integration via GitHub Actions (macOS 14 runner).
* * *

### 9. Future phases (outline only)

 1. **Phase 2** -- safe write-ops behind --apply flag (snapshot freezing, collection updates).

 2. **Phase 3** -- bidirectional task sync, Porcupine wake-word, voice interface.

 3. **Phase 4** -- GUI menubar wrapper / merge with Plogger.

### 10. Project conventions

- Default branch **main**; agent runs create feature branches (Phase 2).
- Semantic versioning 0.x until writable features ship.
- All code under MIT license unless corporate policy dictates otherwise.

# Phase 2

_Adds interactive exploration + first LLM features, still _**_read-only_**_, builds on Phase 1.___

## 0. Objectives

| **#** | **Outcome** | **Why it matters** | 
| ----- | ----------- | -----------------  |
| 1     | **obs shell REPL** for ad-hoc SQL/CLI commands. | Lets JRJ "poke around" the DB, cement mental model. | 
| 2 | **Daily Summary generator** (obs daily-summary) that produces one Markdown digest covering _all_ notes created/modified today--no file writes, stdout only. | First practical LLM usage; validates summariser pipeline without touching vault. | 
| 3 | **Embeddings & semantic search** (obs embed, obs ask) with local MiniLM (fallback: remote). | Improves search now and sets groundwork for later RAG features. | 

## 1. CLI extensions (Swift-Argument-Parser)
```
    obs shell
    obs daily-summary [--date YYYY-MM-DD] [--format md|json]
    obs embed        [--since <ISO>]           # updates DB vectors
    obs ask "<query>" [--top 5] [--rerank 70b] # semantic search

obs --help shows new commands grouped under **Explore**.
```
## 2. Architecture deltas
```    
    +---------------------+
    | REPL (Swiftline)    |  <-- new interactive layer
    +---------------------+
    | CLI commands        |
    +---------------------+
    |   Reporting         |  <-- add DailySummary.swift
    |   SearchEngine      |  <-- add embeddings + ANN
    +---------------------+
    | VaultIndex (Phase1) |
    | SQLite vec.ext      |  <-- new 'embedding' column
    +---------------------+
```

- **SQLite-vec** extension bundled as a static lib; adds vector_cosine() and approx_knn virtual table.
- **LLMClient** (new): wraps local Ollama & remote endpoints, exposes summarize(text) and embed(text).

## 3. Feature details

### 3.1 obs shell

- Uses **Swiftline** or linenoise for readline, history, autocomplete on table/column names.
- Built-ins:

    - \tables -- list DB tables
    - \desc <table> -- schema
    - \ask <query> -- same as CLI ask
    - Raw SQL executes and prints pretty table (50-row cap).
    - Special output formatting for Obsidian links:
        - Single-column `path` queries print each row as a raw `obsidian://open?path=…` URL for click-to-open.
        - Two-column `[*, path]` queries emit a bullet list `- <first field>  <obsidian://open?path=…>` with the first field truncated/padded and the full Obsidian URI.
    - \\open <id> -- open the note with the given database `id` in Obsidian via the `obsidian://open?path=` URI scheme.

### 3.2 Daily Summary
```shell    
    obs daily-summary --date 2025-04-23 --format md
```
1. Pull all notes modified BETWEEN date 00:00 … 23:59.
2. Chunk text to ≤4 k tokens → feed to local 70 B summarize prompt.
3. Merge chunk summaries via small 7 B "combine" prompt.
4. Render Markdown sections:

    - 📄 **Notes created**
    - 📌 **Tasks completed / still open**
    - 🤝 **Meetings** (reads existing Summary:: property if present)

_Note: This command requires an explicit `summarize_model` entry in `config.yaml`. No built-in defaults are used for summarization models; omitting or misconfiguring this setting will cause the command to error. This ensures no unintended remote or unauthorized model usage._

5. Output to stdout (user can pipe to file).

_Nothing is persisted to the vault._ Optionally store final summary in summaries DB table for later reuse.

### 3.3 Embeddings & search

 - **obs embed**

    Flags:
      • `--since <ISO>`: only embed notes modified since timestamp (default: all notes)
      • `--host <URL>`: override Ollama API base URL (default from config)
      • `--model <model>`: override embedding model name (default from config or `nomic-embed-text`)
      • `--reset`: clear existing embeddings before embedding

    Behavior:
      • On `--reset`, runs `UPDATE notes SET embedding=NULL, last_embedded=NULL`
      • Ensures `notes` table has columns `embedding BLOB` and `last_embedded DOUBLE` (ALTER TABLE if needed)
      • Scans vault markdown files; filters by modification date (> last_embedded or `--since`)
      • Reads file contents, POSTs to Ollama `/api/embed` with `{ model, input: [text] }`
      • Writes returned vector as BLOB into `notes.embedding`, updates `last_embedded`
      • Emits a colored progress dot per file: green `.` on success, red `.` on failure

 - **obs ask**

    1. Embed the query text via Ollama (`/api/embed`).

    2. SELECT path, title, and cosine similarity:
       ```sql
       SELECT path, title, vector_cosine(embedding, ?) AS score
         FROM notes
        ORDER BY score DESC
        LIMIT <k>;
       ```

    3. Load the full text of each top-<k> note from disk.

    4. Construct a RAG prompt with an optional system instruction and each note under a heading:
       ```
       You are a helpful assistant. Use the provided notes to answer the question.

       ### Note: <title> (score: <score>)
       <full note text>

       Question: <query>
       Answer:
       ```

    5. POST this prompt to Ollama `/api/generate` and return the model’s `completion`.

    6. Display a spinner or status indicator while waiting for LLM response.

    7. (Future) Support streaming token-by-token output for improved interactivity.

## 4. Configuration
~/.config/obsidian-order/config.yaml:
``` yaml    
    embedding_model: ollama/nomic-embed
    summarize_model:
      primary: ollama/llama3:70b
      fallback: gpt-4o
    ollama_hosts:
      mac: http://127.0.0.1:11434
      pc:  http://10.0.1.42:11434
    cloud_budget_usd_per_day: 1.00

Router policy identical to Phase 1 description.
```
 
**Important:** Critical configuration values such as `summarize_model` and `embedding_model` must be explicitly defined in `config.yaml`. The system does not apply intelligent defaults for these settings; missing or invalid entries will cause commands to error. This prevents unintended remote calls or policy violations.

## 5. Testing & CI additions

| **Layer** | **New tests** | 
| ---- | ----  |
| **SearchEngineTests** | cosine accuracy on toy corpus; re-ranker order. | 
| **SummaryTests** | snapshot test: given fixture notes, summary == golden file. | 
| **ShellTests** | parse built-ins, execute SELECT 1. | 

CI: add swift test --enable-code-coverage; keep existing Codecov step.

