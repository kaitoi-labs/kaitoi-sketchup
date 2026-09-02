# Kaitoi for SketchUp

> **AI changed creation. Kaitoi changes production.**

This plugin brings Kaitoi's models into the SketchUp viewport. Frame the model,
open a panel, describe what you want, press **Generate**. The view is captured,
sent through a Kaitoi node, and the result comes back beside it — without
leaving SketchUp.

---

## What you can do

### Restyle the viewport (Image → Image)

The capture goes to the model; the geometry you framed drives the composition.

| Example node | Kaitoi node type |
|---|---|
| FLUX SRPO Image to Image | `builtin/third_party/fal/flux_srpo_image_to_image` |
| Qwen Image Edit | `builtin/third_party/fal/qwen_image_edit` |
| Nano Banana 2 Edit | `builtin/third_party/fal/nano_banana_2_edit` |
| ImagineArt 2.0 Edit | `builtin/third_party/fal/imagineart_2_i2i` |

### Turn the view into a shot or a mesh

| Example node | Kaitoi node type |
|---|---|
| Seedance 2 (image → video) | `builtin/third_party/fal/seedance_2_i2v` |
| MiniMax H3 (image → video) | `builtin/third_party/fal/minimax_h3_i2v` |
| Hunyuan 3D (image → 3D) | `builtin/third_party/fal/hunyuan3d_image_to_3d` |
| Tripo 3D P1 (image → 3D) | `builtin/third_party/tripo/tripo_p1_image_to_3d` |

Any Kaitoi node with an image input and a prompt works — the whole catalog is
in the dropdown, and inputs are bound from each node's live schema rather than
hard-coded pin names.

### Chat instead of choosing

The **Kaitoi Agent** panel picks the node for you. Describe the change; it
answers in natural language, runs a node when you actually ask for one, and
shows which tool it used. **use last asset** feeds the previous result back in,
so edits compound: render the view, restyle it, then turn it into a video.

### Keep the model untouched

Nothing is written back into the SketchUp model. Results download to
`~/KaitoioDownloads/` and are listed under **Generations** — the last 50 runs,
each with its prompt, node and file.

---

## Why it works this way

**The viewport is the input.** What gets sent is the view as it renders —
camera, styles, shadows, section cuts — captured through SketchUp's own
`write_image`, so what you see is what the model gets.

**Any Kaitoi node can be wired in.** The plugin reads a node's published
schema at run time and binds the capture to its actual image pin and the
prompt to its prompt pin. Pin names differ between nodes (`inputImage` vs
`inputImages`), so none are assumed. A node that wants something else — a `3d`
mesh, say — is refused before the run rather than failing inside it.

**Credentials never reach the browser.** The panels are `UI::HtmlDialog`, and
their JavaScript makes no HTTP calls at all: it invokes Ruby action callbacks,
Ruby calls the API. Keys stay in Ruby, and CORS never applies.

---

## Quick start

**1. Get a Kaitoi Studio account** at [studio.kaitoi.io](https://studio.kaitoi.io)
and create an API key (`files:*`, `projects:*`, `node_types:read`, `runs:*`;
`account_credits:read` is optional).

**2. Install the extension.**

```bash
git clone https://github.com/kaitoi-labs/kaitoi_sketchup.git
cd kaitoi_sketchup
bash tools/build_rbz.sh          # -> build/kaitoi_sketchup-<version>.rbz
```

In SketchUp: **Window → Extension Manager → Install Extension**, pick the
`.rbz`, confirm.

To install by hand instead, copy `kaitoi_sketchup.rb` **and** the
`kaitoi_sketchup/` folder into the per-user plugins folder:

| OS | Folder |
|---|---|
| macOS | `~/Library/Application Support/SketchUp <year>/SketchUp/Plugins/` |
| Windows | `%APPDATA%\SketchUp <year>\SketchUp\Plugins\` |

SketchUp only loads `.rb` files sitting **directly** in `Plugins/`, so the
registration file and its folder end up as siblings.

**3. Restart SketchUp.** *Kaitoi for SketchUp* appears in **Window → Extension
Manager**, and a `Plugins > Kaitoio` submenu appears.

**4. Paste your API key** in `Plugins > Kaitoio > Credentials...`, **Save**,
**Test REST connection**.

**5. Verify.** Open **Kaitoi Nodes**, pick any image-to-image node, **Capture
current view**, type a prompt, **Generate**. The result appears beside the
capture and lands in `~/KaitoioDownloads/`.

For the Agent panel you also need an **MCP token** — see
[Configuration](#configuration).

---

## Example usage

**"Make it real."**
> Kaitoi Nodes, FLUX SRPO Image to Image. Prompt: *"photorealistic render,
> golden hour, natural materials, keep the geometry"*

The viewport is captured, uploaded and run; the render appears beside it.

**"Now make it move."**
> Kaitoi Agent, **use last asset** checked: *"turn this into a slow dolly
> forward"*

The previous render becomes the input, so the video builds on the image rather
than re-capturing the model.

**"Give me a mesh from this."**
> Kaitoi Nodes, Hunyuan 3D. The capture seeds a generated model, downloaded to
> your downloads folder.

---

## The panels

### Kaitoi Nodes

Tabs: **Render**, **Generations**, **Preferences**.

**Render** — Node type (the whole catalog, paged, with a live filter), Prompt,
**Capture current view**, **Generate**, **Cancel**. Your last node and prompt
return next time you open the panel. Run events collapse to one updating line,
so a node emitting `IN_QUEUE` fifty times stays one row.

**Generations** — one row per finished run: when, kind, node, prompt, and a
link that opens the file. **Clear** empties the list; files on disk are kept.

**Preferences** — URLs, timeout, retries, poll interval, capture size,
download folder, MCP endpoint and token. **Test connection** and **Check
credits**.

### Kaitoi Agent

Chat on the left; input image and result on the right. While a run is going,
the transcript shows the node, a progress bar, the newest event and the MCP
tool currently working:

```
FLUX SRPO Image to Image            42s · 68% · running
██████████████░░░░░░
IN_PROGRESS
▸ run_node_by_type — builtin/third_party/fal/flux_srpo_image_to_image
```

Options: **use capture**, **use last asset**, **Open folder**, **New session**.
Chat turns and generations spend credits; the first one offers **Confirm and
run** or **Allow for this session**, and confirming reuses the same idempotency
key so a retry cannot launch a second paid run.

---

## How a generation runs

```
viewport ──1. capture──▶ PNG, longest edge <= capture_max_edge
         ──2. upload───▶ POST /files/uploads → PUT signed URL → …/complete
         ──3. bind ────▶ GET /node-types/{type} → capture to its image pin
         ──4. run ─────▶ POST /runs (inline one-node graph) → poll + events
         ──5. download ▶ signed URL → ~/KaitoioDownloads → Generations
```

1. **Capture** — `view.write_image`, scaled so the longest edge fits
   `capture_max_edge`.
2. **Upload** — direct-to-storage session. The signed URL *is* the credential,
   so no Bearer token is sent to storage. Files over 25 MB use this session
   rather than the deprecated `POST /files`.
3. **Bind** — the node's live schema decides where the capture and prompt go.
4. **Run** — an inline graph, polled on a timer; `429` retries with
   `Retry-After` and exponential backoff.
5. **Download** — signed URLs last an hour; the file is fetched and recorded.

The Agent adds a step in front: MCP's `upload_file` takes a public URL rather
than a REST `fileId`, so a capture goes REST upload → signed download URL →
`upload_file` → a Kaitoi filename. A chat node then decides whether to run
anything at all.

**Threading:** SketchUp does not reliably schedule background Ruby threads, so
short API calls run synchronously on the action-callback thread and every long
run is polled with `UI.start_timer` on the main thread.

---

## Configuration

| Item | Value |
|---|---|
| REST API | `https://api.studio.kaitoi.io` — origin only; the client appends `/api/v1` ([docs](https://api.studio.kaitoi.io/api/v1/docs)) |
| REST auth | Bearer API key, created in Kaitoi Studio |
| MCP API | `https://mcp.studio.kaitoi.io` — a **separate** API; a REST key is rejected there with `invalid_token` |
| MCP auth | A token minted in Studio under **Settings → MCP**, or OAuth 2.1 + PKCE via **Connect** in the Agent panel |
| MCP scopes | `mcp:read`, `mcp:write` |
| Settings | `~/.kaitoi_sketchup/config.json` (mode 0600) |
| OAuth tokens | `~/.kaitoi_sketchup/mcp_auth.json` (mode 0600) |
| History / log | `~/.kaitoi_sketchup/history.json`, `~/.kaitoi_sketchup/plugin.log` (also echoed to the Ruby Console) |
| Downloads | `~/KaitoioDownloads/` |

Settings keys and their defaults:

| Key | Default |
|---|---|
| `base_url` / `api_path` | `https://api.studio.kaitoi.io` / `/api/v1` |
| `web_url` | `https://studio.kaitoi.io` |
| `api_key` | *(empty)* |
| `mcp_url` / `mcp_token` | `https://mcp.studio.kaitoi.io` / *(empty → OAuth)* |
| `agent_chat_node` | `builtin/third_party/google/gemini_multimodal` |
| `agent_history_turns` | `8` |
| `request_timeout_seconds` / `max_retries` | `120` / `3` |
| `poll_interval_seconds` | `2` |
| `capture_max_edge` | `1024` |
| `download_dir` | *(empty → `~/KaitoioDownloads`)* |
| `dev_mode` | `false` — adds **Run self-test** and **Reload (dev)** to the menu |

`last_node_type`, `last_prompt`, `last_template_id` and
`last_template_prompt` are written as you edit and restored on reopen.

---

## Requirements

- **SketchUp 2021+** (Ruby 2.7+). Developed and tested on SketchUp 2026
  (Ruby 3.2.2) on macOS.
- Ruby **standard library only** — no gems to install.
- A [Kaitoi Studio](https://studio.kaitoi.io) account with an API key. Runs
  cost Kaitoi credits.

---

## Architecture

```
kaitoi_sketchup.rb            # SketchupExtension registration only
kaitoi_sketchup/
├─ loader.rb                  # requires everything, installs the menu
├─ settings.rb                # ~/.kaitoi_sketchup/config.json (created 0600)
├─ history.rb                 # history.json, atomic writes
├─ render.rb                  # capture, pin binding, runs, downloads
├─ api/                       # REST: client, files, runs, node_types,
│                             #   projects, templates, errors
├─ mcp/
│  ├─ client.rb               # JSON-RPC 2.0 over Streamable HTTP
│  └─ oauth.rb                # OAuth 2.1 + PKCE, dynamic registration
├─ agent/
│  ├─ session.rb              # one conversation: chat, run, collect
│  ├─ api.rb                  # the Kaitoio.* console API
│  └─ self_test.rb            # image -> video, timer-driven
├─ graph/builder.rb           # inline graph for one-node runs
├─ model/exporters.rb         # save .skp, export scene PNGs
├─ extensions/                # menu and its commands
└─ ui/                        # dialog, agent_dialog, credentials_dialog
   └─ html/                   # index / agent / credentials .html .css .js
```

`api` knows nothing about SketchUp; `render` is the only module that touches
both. The Agent sits on `mcp` and reuses `render` for capture and download.

### SketchUp scripting notes

Learned on SketchUp 2026 and handled in the code:

- A plugin must call `Sketchup.register_extension` to appear in Extension
  Manager. Requiring files directly from `Plugins/` works but leaves the
  extension invisible and un-disableable, so `kaitoi_sketchup.rb` does nothing
  but register, and `loader.rb` holds the real entry point.
- Background Ruby threads are not scheduled reliably; anything long is polled
  with `UI.start_timer` on the main thread.
- `UI.inputbox` is fixed-width and truncates its labels, so a long token or
  endpoint cannot be read back. Credentials use an `HtmlDialog` instead.
- The embedded browser has no H.264 codec: video never plays in-panel and is
  opened in the OS player.
- `load`-ing a file again redefines its constants and Ruby warns about every
  one, which buries the log. `Kaitoio.reload!` silences warnings for its
  duration.
- `Sketchup::Model::SAVE_VERSION` does not exist; one-argument `model.save`
  writes the current format.
- Ruby version tracks the SketchUp release (2021 → 2.7, 2026 → 3.2.2), so
  `**hash` with String keys is only safe on 3.0+.

---

## Troubleshooting

- **No `Plugins > Kaitoio` menu** — the extension is disabled in Extension
  Manager, or `kaitoi_sketchup.rb` is not directly inside `Plugins/`. It must
  sit beside the `kaitoi_sketchup/` folder, not inside it.
- **`INSUFFICIENT_SCOPE` or `invalid_token` from the Agent** — MCP is a
  separate API. A REST key will not work there; mint an MCP token in Studio
  under **Settings → MCP**, or press **Connect** for OAuth.
- **Every REST call 404s on `/api/v1/api/v1/...`** — `base_url` is the origin
  only; `/api/v1` comes from `api_path`. The two are joined idempotently now,
  so pasting the full URL is harmless.
- **The Agent says several nodes matched** — the query was too generic
  ("image to image" matches five). Pick one from the list it offers, or name
  the model.
- **A node refuses the capture** — it wants something other than an image (a
  `3d` mesh, for instance). Pick an image-input node.
- **Changes to plugin files do nothing** — SketchUp loads Ruby once at
  startup. Restart it, or `Kaitoio.reload!` from the Ruby Console.

---

## Limitations

- Results are files, not geometry: nothing is imported back into the SketchUp
  model.
- The plugin keeps its own credentials in `~/.kaitoi_sketchup/config.json`.
  Other Kaitoi plugins share `~/.kaitoi/credentials.json`; this one does not
  read it yet.
- The **Templates** tab is hidden. Its markup and Ruby paths are retained —
  re-enable by uncommenting the `#tab-templates` section and its tab button in
  `ui/html/index.html`.
- `Kaitoio.ask` and `Kaitoio.confirm` block SketchUp until the run finishes; a
  console script cannot receive a timer callback. Use the Agent panel for long
  runs.
- Neither panel pre-checks the credit balance.

---

## Development

```bash
node test/panel_smoke.js   # runs each panel's JS against a stub DOM
ruby test/self_calls.rb    # flags self-calls nothing defines
bash tools/build_rbz.sh    # package for Extension Manager
```

`ruby -c` only parses. `panel_smoke.js` executes the panel JS, fires the
buttons and asserts the expected `sketchup.*` callback fires; `self_calls.rb`
catches a call site whose method was never defined.

The Ruby Console API is the other way in:

```ruby
Kaitoio.help          # list the API
Kaitoio.capture       # capture the viewport and attach it
Kaitoio.ask("make this photoreal, golden hour")   # -> downloaded file path
Kaitoio.mcp_status    # server info and tool count
Kaitoio.self_test!    # viewport -> image -> video, end to end
Kaitoio.reload!       # reload plugin Ruby after editing
```

SketchUp's own **AI Assistant** cannot be connected to Kaitoi — it ships
encrypted and signed, and the SketchUp Ruby API documents no assistant or agent
interface for extensions. The reverse works: its `RUBY_AGENT` writes and runs
Ruby, so asking it to *"run `Kaitoio.ask(\"...\")` in Ruby"* drives this plugin.

---

## Links

- **Product:** [studio.kaitoi.io](https://studio.kaitoi.io)
- **Company:** [kaitoi.io/labs](https://kaitoi.io/labs)
- **API docs:** [api.studio.kaitoi.io/api/v1/docs](https://api.studio.kaitoi.io/api/v1/docs)
- **MCP server:** [github.com/kaitoi-labs/kaitoi-mcp](https://github.com/kaitoi-labs/kaitoi-mcp)
- **Discord:** [discord.gg/3A5YfXnCH](https://discord.gg/3A5YfXnCH)

## About Kaitoi Labs

Kaitoi Labs, Inc. is a San Francisco–based team building hybrid intelligence
tools for creative production, with a background spanning AI, filmmaking, VFX,
and product design.

## License

The contents of this repository are released under the
[Apache License, Version 2.0](./LICENSE). Access to Kaitoi Studio and its API
is governed by the Kaitoi Studio terms of service. SketchUp is a trademark of
Trimble Inc.
