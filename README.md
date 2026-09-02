# Kaitoio — SketchUp Bridge

A SketchUp extension (Ruby) that connects the active SketchUp model with the
[Kaitoio REST API](https://api.studio.kaitoi.io/api/v1/docs).

Licensed under the [Apache License, Version 2.0](../LICENSE).

- **Render** the active viewport: capture the view, pick a Kaitoio node, add a
  prompt, and run image→image / image→video — the result appears beside the
  capture
- **Run Templates**: pick a published Kaitoio template (endpoint-backed
  project); the capture + prompt bind to the template's *declared* inputs
- **Generations**: a persisted history of recent runs, each linking to the
  downloaded `image/*` / `video/*` file
- Outputs download to `~/KaitoioDownloads/` and open in your OS viewer/player

> The SketchUp Ruby API is the only way to drive SketchUp from inside the
> application. This plugin is therefore written in Ruby, not Python. A
> small Python `.venv` next to this folder is not used by the plugin and
> can be ignored or removed.

---

## Install

1. **Copy `kaitoi_sketchup.rb` and the `kaitoi_sketchup/` folder** into your
   SketchUp `Plugins` directory:
   - macOS: `~/Library/Application Support/SketchUp <year>/SketchUp/Plugins/`
   - Windows: `%APPDATA%\SketchUp <year>\SketchUp\Plugins\`

   Final layout — SketchUp loads `.rb` files sitting directly in `Plugins/`,
   so the loader and its folder are siblings:
   ```
   Plugins/
     kaitoi_sketchup.rb        <- loader, must be at the Plugins root
     kaitoi_sketchup/
       api/...
       agent/...
       mcp/...
       extensions/...
       model/...
       graph/...
       ui/...
       version.rb
       settings.rb
   ```

2. **Restart SketchUp.** A new `Plugins > Kaitoio` submenu appears.
   > Note: SketchUp loads Ruby once at startup. After updating the plugin
   > files you must **fully restart SketchUp** — reopening the panel only
   > reloads the HTML/JS, not the Ruby.

3. **Set your API key** (and confirm the base URL):
   `Plugins > Kaitoio > Credentials...`, or the **Preferences** tab of the
   panel. The key is saved to `~/.kaitoi_sketchup/config.json` (mode `0600`).

4. **Open the panel:** `Plugins > Kaitoio > Kaitoi Nodes`

Your Kaitoio API key needs at least these scopes (request them when creating
the key in the Kaitoio dashboard):
- `files:read`, `files:write`
- `projects:read`, `projects:write`
- `account_credits:read` (optional, for the **Check credits** button)

---

## Panel

The panel has four tabs: **Render**, **Templates**, **Generations**,
**Preferences**.

### 1. Render
- **Node type** dropdown listing the whole catalog (paginated server-side),
  with a live filter box (e.g. `image`). The last-used node is remembered in
  `config.json` and re-selected next launch.
- **Capture current view** → a PNG (longest edge capped by `capture_max_edge`).
- **Generate** uploads the capture, builds a one-node inline graph, submits a
  run, and polls it. If you hit Generate without a capture it auto-captures
  first. **Cancel** requests cancellation of the live run.
- Inputs are sent as typed pin objects: image/file pins as
  `{ "type": "file", "fileId": … }`, text pins as `{ "type": "string", … }`;
  unmatched pins fall back to their declared defaults.
- The result shows beside the capture — images inline, **video as a
  click-to-open poster** (SketchUp's embedded browser has no H.264 codec, so
  video can't play in-panel). An **Open file** link opens the download in your
  OS viewer/player.

### 2. Templates
- Lists your Kaitoio **templates** (`GET /templates`); a template is runnable
  when it exposes an endpoint (`hasEndpoint`).
- Pick one, capture the view, type a prompt, **Run**. The plugin reads the
  endpoint's declared input schema (`GET …/endpoints/{id}/docs`) and binds the
  uploaded capture to the first `file`/`image` input and the prompt to the
  first `string` input — no graph-pin guessing — then submits
  `POST …/endpoints/{id}/runs` and polls the task.

### 3. Generations
- A persisted history (last 50, in `~/.kaitoi_sketchup/history.json`) of
  successful runs: when, type, node/template, prompt, and a link that opens
  the downloaded file. **Clear** empties the list (files on disk are kept).

### 4. Preferences
- API key (stored first), base/web URLs, API path, timeout, retries, poll
  interval, capture max edge, download directory.
- **Test connection** and **Check credits** (shows the `balanceCents` value in
  cents + `updatedAt`).

---

## SketchUp Menu

```
Plugins > Kaitoio
  Kaitoi Nodes
  Kaitoi Agent...
  ─────
  Credentials...
```

Developer entries (**Reload** and **Run self-test**) are hidden. Enable them
with:

```ruby
Kaitoio::Settings.update('dev_mode' => true)   # then restart SketchUp
```

They are always available from the Ruby Console regardless:

```ruby
Kaitoio.reload!      # reload plugin Ruby after editing
Kaitoio.self_test!   # viewport -> image -> video, end to end
```

The Panel is the recommended way to work; the menu opens it, opens the Agent,
and opens the credentials editor (a resizable HtmlDialog — the native
`UI.inputbox` clipped long tokens and endpoints).

---

## Architecture

```
kaitoi_sketchup.rb            # entry point, requires everything
└─ kaitoi_sketchup/
   ├─ version.rb
   ├─ settings.rb             # ~/.kaitoi_sketchup/config.json (chmod 600)
   ├─ history.rb              # ~/.kaitoi_sketchup/history.json (Generations)
   ├─ api/
   │  ├─ client.rb            # Net::HTTP wrapper, Bearer auth, retries,
   │  │                       #   rate-limit handling, multipart upload
   │  ├─ errors.rb            # Kaitoio::Error, AuthError, VersionConflict…
   │  ├─ files.rb             # /files endpoints
   │  ├─ projects.rb          # /projects endpoints (incl. document ops)
   │  ├─ runs.rb              # /runs endpoints + poll_until_done
   │  ├─ node_types.rb        # /node-types endpoints
   │  └─ templates.rb         # /templates endpoints (list, docs, run, status)
   ├─ model/
   │  └─ exporters.rb         # save .skp, export scene PNGs (view.write_image)
   ├─ render.rb               # capture view; image2image, project & template
   │                          #   runs; result download + mime handling
   ├─ graph/
   │  └─ builder.rb           # PublicEditableGraph + addNode patch ops
   ├─ extensions/
   │  ├─ menu.rb              # installs the Plugins > Kaitoio menu
   │  └─ commands.rb          # menu command implementations
   └─ ui/
      ├─ dialog.rb            # UI::HtmlDialog wrapper, action callbacks,
      │                       #   run pollers (UI.start_timer)
      ├─ agent_dialog.rb     # the Kaitoi Agent panel
      └─ html/
         ├─ index.html
         ├─ style.css
         ├─ app.js            # vanilla JS, talks to Ruby via
         │                    #   window.sketchup.* action callbacks
         ├─ agent.html
         ├─ agent.css
         └─ agent.js
```

The JS side never makes HTTP calls directly — it goes through Ruby's
`Kaitoio::Api::Client` so the Bearer token never leaves Ruby and CORS
isn't an issue. Binary file uploads use the recommended direct-to-storage
flow:

1. `POST /api/v1/files/uploads` → signed `upload.url`
2. `PUT` the bytes to that signed URL (no auth header, just the signed
   headers)
3. `POST /api/v1/files/uploads/{id}/complete` → durable `fileId`

---

## Kaitoi Agent (MCP)

`Plugins > Kaitoio > Kaitoi Agent...` opens a second panel: a chat on the left,
the viewport capture and the generated result on the right. Each message
becomes a call to the [Kaitoi Studio MCP server](https://github.com/kaitoi-labs/kaitoi-mcp),
which picks the node and runs it — the transcript shows the tool traffic, so
what ran stays visible.

The panel is a real conversation. Each message goes to a **vision chat node**
run over MCP (`agent_chat_node`, default
`builtin/third_party/google/gemini_multimodal`), which sees the viewport
capture and answers in natural language. It triggers a generation only when
you actually ask for one — a greeting stays a greeting.

Earlier builds sent every message straight to `run_node_by_search`, so "hi"
came back as `AMBIGUOUS_NODE_MATCH`. The chat node now sits in front and
decides whether a run is wanted.

Chat turns cost credits. The first one asks for confirmation and offers
**Allow for this session** so a conversation is not a confirmation dialog per
message.

### Configuration

| Item | Value |
|---|---|
| Transport | Streamable HTTP (JSON-RPC 2.0) |
| Endpoint | `https://mcp.studio.kaitoi.io` |
| Auth | Bearer token, or OAuth 2.1 + PKCE |
| Scopes | `mcp:read`, `mcp:write` |
| Token settings | `mcp_url`, `mcp_token` in `~/.kaitoi_sketchup/config.json` |
| OAuth tokens | `~/.kaitoi_sketchup/mcp_auth.json` (mode `0600`) |

**MCP is a separate API from the REST API above.** A REST key is rejected
there with `invalid_token`; the two credentials are not interchangeable.

### Connecting

Either works — pick one:

1. **Token (recommended).** Mint one in Kaitoi Studio under
   **Settings → MCP**, then paste it into the panel's **Preferences → MCP
   token**. Tokens last 365
   days by default and are revocable; mint a separate one per client.
2. **OAuth.** Leave the token blank and press **Connect** in the Agent panel.
   The plugin registers itself dynamically, opens your browser for approval,
   and catches the redirect on `http://127.0.0.1:8785/callback`. Access
   tokens refresh automatically; **Sign out** clears them.

Neither credential is ever sent to the panel's JavaScript — both are redacted
to a short hint before `boot` returns.

### SketchUp's built-in AI Assistant

The bundled **AI Assistant** extension (`su_assistant`, Trimble) cannot be
connected to the Kaitoi MCP server. It is closed: its Ruby ships as encrypted
`.rbe` (`RBS2.0`), the extension is signed (`su_assistant.susig`), its agent
list is fixed in its own `config.json` (`AUTO_AGENT`, `HELP_AGENT`,
`RUBY_AGENT`, `TEXT_TO_3D_AGENT`), and its binaries contain no tool- or
provider-registration surface. There is no supported hook for third-party
agents or MCP servers.

What does work is the other direction. Its **RUBY_AGENT** writes and runs
Ruby, so it can drive this plugin through a stable console API:

```ruby
Kaitoio.help          # list the API
Kaitoio.capture       # capture the viewport and attach it
Kaitoio.ask("make this photoreal, golden hour")   # -> downloaded file path
Kaitoio.confirm("...")# same, confirming a costly run
Kaitoio.mcp_status    # server info and tool count
Kaitoio.mcp_tools     # available MCP tool names
Kaitoio.agent_panel   # open the Agent panel
```

Ask the AI Assistant to *"run `Kaitoio.ask(\"...\")` in Ruby"* and it will
call into the MCP bridge for you.

> These console calls **block** until the run finishes — SketchUp is
> unresponsive meanwhile. That is deliberate: a console script cannot receive
> a timer callback. Use the Agent panel for long runs; it polls on a timer.

### How a turn works

1. **Capture** exports the viewport to PNG.
2. MCP's `upload_file` imports a *public URL*, not a REST `fileId`, so the
   capture goes: REST upload → signed download URL → `upload_file` → a Kaitoi
   filename usable as a node input.
3. The message is sent as `run_node_by_search`. If the server answers
   `MISSING_REQUIRED_INPUTS`, the plugin reads the required input name from
   that reply and retries with the capture bound to it, rather than guessing
   a pin name.
4. `COST_CONFIRMATION_REQUIRED` surfaces a confirmation button and replays
   with the **same idempotency key**, so a retry cannot launch a second paid
   run.
5. Progress is polled with `UI.start_timer`; `get_displayable_outputs`
   resolves the result, which is downloaded and recorded in **Generations**.

---

## Limitations / Notes

- The Kaitoio REST API is **not** a 3D-model versioning system. It stores
  bytes verbatim and routes them through workflow graphs. The plugin
  therefore treats Kaitoio as an archive + workflow backend, not a 3D
  editor.
- 3D files larger than 25 MB use the multipart upload session endpoint,
  not the deprecated `POST /files` (which is hard-capped at 25 MB).
- Optimistic concurrency is honored: any update that requires
  `expectedVersion` reads it from the loaded document and surfaces
  `409` conflicts back to the UI as a clear error.
- Rate limiting: the client retries `429` automatically using the
  `Retry-After` header (with exponential backoff fallback). The
  plugin also retries idempotent failures and 5xx responses.
- Signed download URLs default to 1 hour (`expiresInSeconds`).
- **Threading:** SketchUp does not reliably schedule background Ruby threads,
  so short API calls run synchronously on the action-callback thread, and
  long-running runs are polled with `UI.start_timer` (main thread, repeating)
  so the UI stays responsive without blocking on a worker thread.
- All activity is logged to the **Ruby Console** and
  `~/.kaitoi_sketchup/plugin.log` (HTTP, API ops, run status, errors).
- Video results can't preview in-panel (no H.264 codec in the embedded
  browser); they download and open in the OS player instead.
- The plugin targets **SketchUp 2021+** (Ruby 2.7+). It uses only the Ruby
  stdlib (`Net::HTTP`, `Digest`, `JSON`, `URI`, `Socket`) plus
  `UI::HtmlDialog`. SketchUp 2026 ships Ruby 3.2.2.
- The **Templates** tab is currently hidden in the panel. Its markup and Ruby
  paths are retained; re-enable it by uncommenting the `#tab-templates`
  section and its tab button in `ui/html/index.html`.

---

## License

This project is licensed under the Apache License, Version 2.0. See
[`LICENSE`](LICENSE) for the full license text.

```
Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
