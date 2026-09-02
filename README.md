# Kaitoi for SketchUp

A SketchUp extension that connects the active model to Kaitoi Studio. Capture
the viewport, run it through Kaitoi's node library, and get the result back
beside it.

Two panels:

- **Kaitoi Nodes** — pick a node from the catalog, capture the view, add a
  prompt, run it.
- **Kaitoi Agent** — a chat that picks and runs nodes for you.

Outputs download to `~/KaitoioDownloads/` and are listed under
**Generations**.

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

2. **Restart SketchUp.** A `Plugins > Kaitoio` submenu appears. SketchUp loads
   Ruby once at startup, so restart after changing plugin files — reopening a
   panel reloads only the HTML/JS.

3. **Add your credentials:** `Plugins > Kaitoio > Credentials...`

4. **Open a panel:** `Kaitoi Nodes` or `Kaitoi Agent...`

**Requires SketchUp 2021+** (Ruby 2.7+; SketchUp 2026 ships 3.2.2). Ruby
stdlib only — no gems.

---

## Credentials

`Plugins > Kaitoio > Credentials...` — one card per API, with a **Show**
toggle for pasted tokens and a **Test** button for each.

The two APIs are **separate and not interchangeable**. A REST key sent to the
MCP endpoint is rejected with `invalid_token`.

| | REST API | MCP API |
|---|---|---|
| Used by | Kaitoi Nodes | Kaitoi Agent |
| Endpoint | `https://api.studio.kaitoi.io/api/v1` | `https://mcp.studio.kaitoi.io` |
| Credential | API key | MCP token, or OAuth |
| Scopes | `files:*`, `projects:*`, `node_types:read`, `runs:*`, `account_credits:read` | `mcp:read`, `mcp:write` |

Both live in `~/.kaitoi_sketchup/config.json` (mode `0600`) and are redacted
to a short hint before reaching the panels' JavaScript.

**Connecting the MCP API** — either:

- **Token (recommended).** Mint one in Kaitoi Studio under **Settings → MCP**
  and paste it into the MCP card. Tokens last 365 days, are revocable, and are
  scoped to the minting user.
- **OAuth.** Leave the token blank and press **Connect** in the Agent panel.
  Your browser opens for approval; the redirect is caught on
  `http://127.0.0.1:8785/callback`. Tokens are stored in
  `~/.kaitoi_sketchup/mcp_auth.json` (`0600`) and refresh automatically.
  **Sign out** clears them.

---

## Kaitoi Nodes

Tabs: **Render**, **Generations**, **Preferences**.

**Render.** Pick a node from the catalog — the dropdown pages the whole
library and has a live filter. Capture the view, add a prompt, **Generate**.
Your last node and prompt come back next time you open the panel.

Inputs are bound from the node's declared schema, so the capture lands on the
node's actual image pin and the prompt on its prompt pin. A node with no image
input runs prompt-only; one that wants something else — a `3d` mesh, say — is
refused up front rather than failing mid-run.

Images preview inline. **Video opens in your OS player**, since SketchUp's
embedded browser has no H.264 codec.

**Generations.** The last 50 successful runs, with a link that opens each
file. **Clear** empties the list; files on disk are kept.

**Preferences.** URLs, timeout, retries, poll interval, capture size,
download directory, MCP endpoint and token — plus **Test connection** and
**Check credits**.

> The **Templates** tab is hidden. Its markup and Ruby paths are retained;
> re-enable by uncommenting the `#tab-templates` section and its tab button in
> `ui/html/index.html`.

---

## Kaitoi Agent

Chat on the left; the input image and the generated result on the right.

Messages go to a vision chat node that sees your capture and answers in
natural language, starting a generation only when you ask for one — a greeting
stays a greeting. When a request matches several nodes equally well, the agent
either picks the best match or lists the candidates for you to choose.

**Options**

- **use capture** — attach the current viewport.
- **use last asset** — attach the *previous result* instead, so edits compound:
  generate an image, restyle it, then turn it into a video.
- **Open folder** — open the download directory.
- **New session** — clear the transcript, history and attachments.

**While it runs**, the transcript shows the node, a progress bar, the latest
event and which MCP tool is working:

```
FLUX SRPO Image to Image            42s · 68% · running
██████████████░░░░░░
IN_PROGRESS
▸ run_node_by_type — builtin/third_party/fal/flux_srpo_image_to_image
```

**Cost.** Chat turns and generations spend credits. The first one shows a
preview (`Gemini 0.01 per_call`) with **Confirm and run** and **Allow for this
session**. Confirming reuses the same idempotency key, so a retry cannot
launch a second paid run.

---

## Menu

```
Plugins > Kaitoio
  Kaitoi Nodes
  Kaitoi Agent...
  ─────
  Credentials...
  Open downloads folder
```

Developer entries — **Run self-test (image → video)** and **Reload (dev)** —
are hidden. Enable with:

```ruby
Kaitoio::Settings.update('dev_mode' => true)   # then restart SketchUp
```

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

> `ask` and `confirm` block until the run finishes, freezing SketchUp
> meanwhile — a console script cannot receive a timer callback. Use the Agent
> panel for long runs. `self_test!` is timer-driven and does not block.

**SketchUp's built-in AI Assistant cannot be connected to Kaitoi.** The
bundled `su_assistant` extension ships encrypted and signed, its agent list is
fixed, and the SketchUp Ruby API documents no assistant or agent interface for
extensions. The reverse works: its `RUBY_AGENT` writes and runs Ruby, so
asking it to *"run `Kaitoio.ask(\"...\")` in Ruby"* drives this plugin.

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
`last_template_prompt` are written as you edit and restored on reopen.

Alongside it: `history.json` (Generations), `plugin.log` (all activity),
`mcp_auth.json` (OAuth tokens, `0600`).

---

## Under the hood

```
kaitoi_sketchup.rb            # entry point, requires everything
└─ kaitoi_sketchup/
   ├─ settings.rb             # config.json (created 0600)
   ├─ history.rb              # history.json (atomic writes)
   ├─ render.rb               # capture, pin binding, runs, downloads
   ├─ api/                    # REST: client, files, runs, node_types,
   │                          #   projects, templates, errors
   ├─ mcp/
   │  ├─ client.rb            # JSON-RPC 2.0 over Streamable HTTP
   │  └─ oauth.rb             # OAuth 2.1 + PKCE, dynamic registration
   ├─ agent/
   │  ├─ session.rb           # one conversation: chat, run, collect
   │  ├─ api.rb               # the Kaitoio.* console API
   │  └─ self_test.rb         # image -> video, timer-driven
   ├─ graph/builder.rb        # inline graph for one-node runs
   ├─ model/exporters.rb      # save .skp, export scene PNGs
   ├─ extensions/             # menu and its commands
   └─ ui/                     # dialog, agent_dialog, credentials_dialog
      └─ html/                # index / agent / credentials .html .css .js
```

**JavaScript never makes HTTP calls.** Panels invoke Ruby action callbacks and
Ruby answers via `execute_script`, so credentials stay in Ruby and CORS never
applies.

**Threading.** SketchUp does not reliably schedule background Ruby threads, so
short API calls run synchronously on the action-callback thread and long runs
are polled with `UI.start_timer` on the main thread.

**Uploads** use the direct-to-storage flow: `POST /files/uploads` returns a
signed URL, the bytes are `PUT` there (the signed URL is the credential, so no
Bearer token reaches storage), then `POST …/complete` yields a durable
`fileId`. Files over 25 MB use this session rather than the deprecated
`POST /files`. Signed download URLs last an hour.

**An Agent turn.** MCP's `upload_file` takes a public URL rather than a REST
`fileId`, so a capture goes: REST upload → signed download URL → `upload_file`
→ a Kaitoi filename usable as a node input. The chat node replies with
`{reply, generate}`; only a non-null `generate` starts a run.
`run_node_by_search` selects the node, inputs are bound from that node's
schema, and progress is polled until the output resolves, with a 10-minute
cap. Results are downloaded and recorded in Generations.

**Errors.** `429` is retried using `Retry-After` with exponential backoff;
idempotent failures and `5xx` are retried too. `409` conflicts surface as a
clear error. Everything is logged to the Ruby Console and
`~/.kaitoi_sketchup/plugin.log`.

The Ruby namespace is `Kaitoio`.

---

## Development

```bash
node test/panel_smoke.js   # runs each panel's JS against a stub DOM
ruby test/self_calls.rb    # flags self-calls nothing defines
```

`ruby -c` only parses. `panel_smoke.js` executes the panel JS, fires the
buttons and asserts the expected `sketchup.*` callback fires; `self_calls.rb`
catches a call site whose method was never defined.

For an end-to-end check against the live API, enable `dev_mode` and run
**Run self-test (image → video)**, or `Kaitoio.self_test!`. It spends credits.

---

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
