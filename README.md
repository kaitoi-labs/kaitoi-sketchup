# Kaitoi for SketchUp

A SketchUp extension that connects the active model to Kaitoi Studio: capture
the viewport, run it through Kaitoi's node library, and get the result back
beside it.

Two panels:

- **Kaitoi Nodes** — pick a node from the catalog, capture the view, add a
  prompt, run it. Talks to the [Kaitoi REST API](https://api.studio.kaitoi.io/api/v1/docs).
- **Kaitoi Agent** — a chat that decides what to run for you, over the
  [Kaitoi Studio MCP server](https://github.com/kaitoi-labs/kaitoi-mcp).

Outputs download to `~/KaitoioDownloads/` and are listed under **Generations**.

Licensed under the [Apache License 2.0](LICENSE). The Ruby namespace is
`Kaitoio`.

---

## Install

1. **Copy `kaitoi_sketchup.rb` and the `kaitoi_sketchup/` folder** into your
   SketchUp `Plugins` directory:
   - macOS: `~/Library/Application Support/SketchUp <year>/SketchUp/Plugins/`
   - Windows: `%APPDATA%\SketchUp <year>\SketchUp\Plugins\`

   SketchUp only loads `.rb` files sitting **directly** in `Plugins/`, so the
   loader and its folder are siblings:

   ```
   Plugins/
     kaitoi_sketchup.rb        <- loader, must be at the Plugins root
     kaitoi_sketchup/          <- everything else
   ```

2. **Restart SketchUp.** A `Plugins > Kaitoio` submenu appears.

   SketchUp loads Ruby once at startup, so after changing plugin files you
   must restart it — reopening a panel reloads only the HTML/JS.

3. **Add your credentials:** `Plugins > Kaitoio > Credentials...`

4. **Open a panel:** `Plugins > Kaitoio > Kaitoi Nodes` or `Kaitoi Agent...`

### Requirements

- **SketchUp 2021+** (Ruby 2.7+). SketchUp 2026 ships Ruby 3.2.2.
- Ruby stdlib only — no gems. `Net::HTTP`, `Digest`, `JSON`, `URI`, `Socket`.

---

## Credentials

`Plugins > Kaitoio > Credentials...` opens a resizable editor with one card
per API, full-width monospace fields, a **Show** toggle so a pasted token can
be checked, and a **Test** button for each.

The two APIs are **separate and not interchangeable**:

| | REST API | MCP API |
|---|---|---|
| Used by | Kaitoi Nodes panel | Kaitoi Agent |
| Endpoint | `https://api.studio.kaitoi.io` + `/api/v1` | `https://mcp.studio.kaitoi.io` |
| Credential | API key | MCP token, or OAuth |
| Scopes | `files:*`, `projects:*`, `node_types:read`, `runs:*`, `account_credits:read` | `mcp:read`, `mcp:write` |

A REST key sent to the MCP endpoint is rejected with `invalid_token`.

Stored in `~/.kaitoi_sketchup/config.json` (mode `0600`). Neither credential
is ever sent to the panels' JavaScript — both are redacted to a short hint.
The REST base URL is joined idempotently, so pasting the full
`https://api.studio.kaitoi.io/api/v1` does not produce `/api/v1/api/v1`.

### Connecting the MCP API

**Token (recommended).** Mint one in Kaitoi Studio under **Settings → MCP**,
paste it into the Credentials editor's MCP card. Tokens last 365 days by
default, are revocable, and are scoped to the minting user — mint one per
client.

**OAuth.** Leave the token blank and press **Connect** in the Agent panel. The
plugin registers itself dynamically (OAuth 2.1 + PKCE), opens your browser for
approval, and catches the redirect on `http://127.0.0.1:8785/callback`. Tokens
live in `~/.kaitoi_sketchup/mcp_auth.json` (mode `0600`) and refresh
automatically. **Sign out** clears them.

---

## Kaitoi Nodes panel

Tabs: **Render**, **Generations**, **Preferences**.

### Render
- **Node type** dropdown over the whole catalog (paginated server-side) with a
  live filter. Your last node and prompt are restored on reopen; a remembered
  node that is not on the current page is kept selectable and marked
  *(last used)*.
- **Capture current view** → PNG, longest edge capped by `capture_max_edge`.
- **Generate** uploads the capture, builds a one-node inline graph, submits a
  run and polls it. Without a capture it captures first. **Cancel** stops the
  live run.
- Inputs are bound from the node's **declared schema**: the capture goes to an
  image pin, the prompt to a prompt-like pin. A node with no image input runs
  prompt-only; one that wants something else (a `3d` mesh, say) is refused up
  front rather than failing inside the node.
- Run events collapse to one updating line with a repeat counter, so a node
  emitting `IN_QUEUE` fifty times stays one row.
- Images preview inline. **Video opens in your OS player** — SketchUp's
  embedded browser has no H.264 codec.

### Generations
Last 50 successful runs from `~/.kaitoi_sketchup/history.json`: when, kind,
node, prompt, and a link that opens the file. **Clear** empties the list;
files on disk are kept.

### Preferences
Base and web URLs, API path, timeout, retries, poll interval, capture max
edge, download directory, MCP endpoint and token. Plus **Test connection** and
**Check credits**.

> The **Templates** tab is hidden. Its markup and Ruby paths are retained —
> re-enable by uncommenting the `#tab-templates` section and its tab button in
> `ui/html/index.html`.

---

## Kaitoi Agent panel

Chat on the left; the input image and the generated result on the right.

Each message goes to a **vision chat node** run over MCP (`agent_chat_node`,
default `builtin/third_party/google/gemini_multimodal`), which sees your
capture and answers in natural language. It starts a generation only when you
ask for one — a greeting stays a greeting. Conversation history is kept in
Ruby and replayed into the prompt, bounded by `agent_history_turns`, because
MCP scratch runs are isolated and hold no memory of their own.

### Options

- **use capture** — attach the current viewport.
- **use last asset** — attach the **previous result** instead, so edits
  compound: generate an image, restyle it, then turn it into a video. Disabled
  until something has been generated; a session reset clears it.
- **Open folder** — opens the download directory.
- **New session** — clears the transcript, history and attachments.

### What you see while it runs

A live block in the transcript shows the node title, a percent bar, the newest
event message and elapsed seconds, driven by `get_graph_run_events`. Under it,
the MCP tool currently running, ticked with its duration when it finishes:

```
FLUX SRPO Image to Image            42s · 68% · running
██████████████░░░░░░
IN_PROGRESS
▸ run_node_by_type — builtin/third_party/fal/flux_srpo_image_to_image
```

Percentages go on the bar rather than the log, and repeated identical messages
are collapsed, so the Ruby Console stays readable.

### Cost

Chat turns and generations cost credits. The first one shows a summarised
preview (`Gemini 0.01 per_call`) with **Confirm and run** and **Allow for this
session**, so a conversation is not a confirmation dialog per message.
Confirmation replays the **same idempotency key**, so a retry cannot launch a
second paid run.

### How a turn works

1. The capture is exported to PNG. MCP's `upload_file` imports a *public URL*
   rather than a REST `fileId`, so it goes: REST upload → signed download URL
   → `upload_file` → a Kaitoi filename usable as a node input.
2. The chat node replies with `{reply, generate}`. Only a non-null `generate`
   starts a run.
3. `run_node_by_search` picks the node. On `AMBIGUOUS_NODE_MATCH` the agent
   picks a candidate itself — preferring ones that matched **semantically**,
   since lexical-only matches carry a flat low confidence and can otherwise
   win on rank alone. When nothing matches semantically it lists the
   candidates and waits for you to choose.
4. Once the exact node type is known, inputs are bound from **its** schema.
   Pin names differ between nodes (`inputImage` vs `inputImages`), so generic
   names are never assumed.
5. Progress is polled with `UI.start_timer`. A completion signal only
   *triggers* a collection attempt — the turn ends when media actually comes
   back, since a scratch run can sit at `running` well after its node has
   finished. A 10-minute cap stops any run that never resolves.
6. `get_displayable_outputs` resolves the result, which is downloaded and
   recorded in **Generations**.

---

## SketchUp menu

```
Plugins > Kaitoio
  Kaitoi Nodes
  Kaitoi Agent...
  ─────
  Credentials...
  Open downloads folder
```

Developer entries are hidden. Enable with:

```ruby
Kaitoio::Settings.update('dev_mode' => true)   # then restart SketchUp
```

which adds **Run self-test (image → video)** and **Reload (dev)**.

---

## Ruby Console API

```ruby
Kaitoio.help          # list the API
Kaitoio.capture       # capture the viewport and attach it
Kaitoio.ask("make this photoreal, golden hour")   # -> downloaded file path
Kaitoio.confirm("...")# same, confirming a costly run
Kaitoio.mcp_status    # server info and tool count
Kaitoio.mcp_tools     # available MCP tool names
Kaitoio.agent_panel   # open the Agent panel
Kaitoio.self_test!    # viewport -> image -> video, end to end
Kaitoio.reload!       # reload plugin Ruby after editing
```

> `ask` and `confirm` **block** until the run finishes — SketchUp is
> unresponsive meanwhile. A console script cannot receive a timer callback.
> Use the Agent panel for long runs; it polls on a timer. `self_test!` is
> timer-driven and does not block.

### SketchUp's built-in AI Assistant

It cannot be connected to Kaitoi. The bundled `su_assistant` extension is
closed: its Ruby ships as encrypted `.rbe` (`RBS2.0`), the extension is signed,
its agent list is fixed in its own config, and its binaries expose no tool- or
provider-registration surface. The official Ruby API documents no assistant,
chat, LLM or agent interface for extensions.

The reverse works: its `RUBY_AGENT` writes and runs Ruby, so asking it to
*"run `Kaitoio.ask(\"...\")` in Ruby"* drives this plugin.

---

## Settings

`~/.kaitoi_sketchup/config.json`, mode `0600`.

| Key | Default |
|---|---|
| `base_url` | `https://api.studio.kaitoi.io` |
| `api_path` | `/api/v1` |
| `web_url` | `https://studio.kaitoi.io` |
| `api_key` | *(empty)* |
| `mcp_url` | `https://mcp.studio.kaitoi.io` |
| `mcp_token` | *(empty — falls back to OAuth)* |
| `agent_chat_node` | `builtin/third_party/google/gemini_multimodal` |
| `agent_history_turns` | `8` |
| `request_timeout_seconds` | `120` |
| `max_retries` | `3` |
| `poll_interval_seconds` | `2` |
| `capture_max_edge` | `1024` |
| `download_dir` | *(empty → `~/KaitoioDownloads`)* |
| `dev_mode` | `false` |

`last_node_type`, `last_prompt`, `last_template_id` and
`last_template_prompt` are written as you edit, and restored on reopen.

Other files: `history.json` (Generations), `plugin.log` (all activity),
`mcp_auth.json` (OAuth tokens, `0600`).

---

## Architecture

```
kaitoi_sketchup.rb            # entry point, requires everything
└─ kaitoi_sketchup/
   ├─ version.rb
   ├─ settings.rb             # config.json (created 0600)
   ├─ history.rb              # history.json (atomic writes)
   ├─ render.rb               # capture, pin binding, runs, downloads
   ├─ api/                    # REST
   │  ├─ client.rb            #   Net::HTTP, Bearer, retries, 429/5xx backoff
   │  ├─ errors.rb            #   Kaitoio::Error and friends
   │  ├─ files.rb             #   direct-to-storage upload flow
   │  ├─ runs.rb              #   /runs + events + poll_until_done
   │  ├─ node_types.rb        #   catalog and per-node schema
   │  ├─ projects.rb          #   documents, graph, spend
   │  └─ templates.rb         #   endpoints, docs, runs
   ├─ mcp/                    # MCP
   │  ├─ client.rb            #   JSON-RPC 2.0 over Streamable HTTP
   │  └─ oauth.rb             #   OAuth 2.1 + PKCE, dynamic registration
   ├─ agent/
   │  ├─ session.rb           #   one conversation: chat, run, collect
   │  ├─ api.rb               #   Kaitoio.ask / capture / mcp_status …
   │  └─ self_test.rb         #   image -> video, timer-driven
   ├─ graph/builder.rb        # inline graph for one-node runs
   ├─ model/exporters.rb      # save .skp, export scene PNGs
   ├─ extensions/
   │  ├─ menu.rb              # the Plugins > Kaitoio menu
   │  └─ commands.rb          # menu command implementations
   └─ ui/
      ├─ dialog.rb            # Kaitoi Nodes panel
      ├─ agent_dialog.rb      # Kaitoi Agent panel
      ├─ credentials_dialog.rb
      └─ html/               # index/agent/credentials .html .css .js
```

**JavaScript never makes HTTP calls.** Panels invoke Ruby action callbacks and
Ruby answers via `execute_script`, so credentials stay in Ruby and CORS never
applies.

**Threading.** SketchUp does not reliably schedule background Ruby threads, so
short API calls run synchronously on the action-callback thread and long runs
are polled with `UI.start_timer` on the main thread.

**Uploads** use the direct-to-storage flow:

1. `POST /api/v1/files/uploads` → signed `upload.url`
2. `PUT` the bytes there — the signed URL is the credential, so no Bearer
   token is sent to storage
3. `POST /api/v1/files/uploads/{id}/complete` → durable `fileId`

---

## Development

```bash
node test/panel_smoke.js   # runs each panel's JS against a stub DOM
ruby test/self_calls.rb    # flags self-calls nothing defines
```

`ruby -c` only parses. `panel_smoke.js` executes the panel JS, fires the
buttons and asserts the expected `sketchup.*` callback fires; `self_calls.rb`
catches a call site whose method was never added. Both exist because those
bugs shipped.

For an end-to-end check against the live API, enable `dev_mode` and run
**Run self-test (image → video)**, or `Kaitoio.self_test!` from the console.
It spends credits.

---

## Notes and limits

- Kaitoi is an archive plus workflow backend, not a 3D-model versioning
  system. It stores bytes verbatim and routes them through graphs.
- Files over 25 MB use the multipart upload session, not the deprecated
  `POST /files`.
- `429` is retried using `Retry-After`, with exponential backoff as fallback;
  idempotent failures and `5xx` are retried too.
- Optimistic concurrency is honoured — `409` conflicts surface as a clear
  error.
- Signed download URLs default to one hour.
- Video cannot preview in-panel (no H.264 codec in the embedded browser); it
  downloads and opens in the OS player.
- Everything is logged to the Ruby Console and `~/.kaitoi_sketchup/plugin.log`.

---

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
