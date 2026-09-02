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

1. **Copy the `kaitoi_sketchup/` folder** into your SketchUp `Plugins`
   directory:
   - macOS: `~/Library/Application Support/SketchUp <year>/SketchUp/Plugins/`
   - Windows: `%APPDATA%\SketchUp <year>\SketchUp\Plugins\`

   Final layout:
   ```
   Plugins/
     kaitoi_sketchup/
       kaitoi_sketchup.rb
       kaitoi_sketchup/
         api/...
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
   `Plugins > Kaitoio > Set API Key...`, or the **Preferences** tab of the
   panel. The key is saved to `~/.kaitoi_sketchup/config.json` (mode `0600`).

4. **Open the panel:** `Plugins > Kaitoio > Open Panel...`

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
  Open Panel...
  ─────
  Set API Key...
```

The Panel is the recommended way to work; the menu just opens it and offers a
quick API-key entry.

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
      └─ html/
         ├─ index.html
         ├─ style.css
         └─ app.js            # vanilla JS, talks to Ruby via
                              #   window.sketchup.* action callbacks
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
- The plugin targets SketchUp 2017+ (uses `UI::HtmlDialog`,
  `Net::HTTP`, `Digest`, `JSON`, `URI` from the Ruby stdlib).

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
