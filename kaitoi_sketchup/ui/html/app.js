/* Kaitoio SketchUp panel.
 *
 * This file makes no HTTP calls. It invokes Ruby action callbacks via
 * window.sketchup.*, and Ruby answers by calling window.kaitoi.receive().
 * The API key therefore never reaches the browser context.
 */
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };

  // Sections can be hidden (e.g. Templates), so every DOM touch is null-safe.
  function bind(id, ev, fn) { var e = $(id); if (e) e.addEventListener(ev, fn); }
  function val(id) { var e = $(id); return e ? e.value : ''; }
  function setVal(id, v) { var e = $(id); if (e) e.value = v; }
  function dis(id, b) { var e = $(id); if (e) e.disabled = b; }
  var handlers = {};
  var state = {
    capturePath: null,
    tplCapturePath: null,
    nodeCursor: null,
    nodes: [],
    templates: [],
    selectedNode: null,      // remembered across panel reopen
    selectedTemplate: null,
    runningIn: null   // 'render' | 'templates' | null
  };

  // ---- bridge -----------------------------------------------------------

  function call(channel, payload) {
    if (!window.sketchup || typeof window.sketchup[channel] !== 'function') {
      return setStatus('render-status', 'Bridge unavailable: ' + channel, true);
    }
    if (payload === undefined) window.sketchup[channel]();
    else window.sketchup[channel](JSON.stringify(payload));
  }

  window.kaitoi = {
    receive: function (channel, payload) {
      var fn = handlers[channel];
      if (fn) { try { fn(payload); } catch (e) { console.error(channel, e); } }
    }
  };

  function on(channel, fn) { handlers[channel] = fn; }

  function setStatus(id, msg, isError) {
    var el = $(id);
    if (!el) return;
    el.textContent = msg || '';
    el.className = 'status' + (isError ? ' err' : (msg ? ' ok' : ''));
  }

  function text(v) { return v === null || v === undefined ? '' : String(v); }

  // Errors can arrive as a string or a structured object; never render
  // an object straight into the status line ("[object Object]").
  function errText(v) {
    if (v === null || v === undefined) return 'unknown error';
    if (typeof v === 'string') return v;
    if (typeof v === 'object') {
      var m = v.message || v.detail || v.error;
      if (m) return (v.code ? v.code + ': ' : '') + m;
      try { return JSON.stringify(v); } catch (e) { return String(v); }
    }
    return String(v);
  }

  // ---- tabs -------------------------------------------------------------

  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (btn) {
    btn.addEventListener('click', function () {
      Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
        b.classList.toggle('is-active', b === btn);
      });
      var name = btn.getAttribute('data-tab');
      Array.prototype.forEach.call(document.querySelectorAll('.panel'), function (p) {
        p.classList.toggle('is-active', p.id === 'tab-' + name);
      });
      if (name === 'generations') call('list_history');
      if (name === 'templates' && !state.templates.length) loadTemplates();
    });
  });

  // ---- boot -------------------------------------------------------------

  on('boot', function (res) {
    if (!res.ok) return setStatus('prefs-status', errText(res.error), true);
    var d = res.data;
    $('version').textContent = 'v' + d.version;
    setConn(d.configured, d.configured ? 'configured' : 'not configured');
    fillPrefs(d.settings, d.downloadDir);
    renderHistory(d.history || []);
    restoreLastUsed(d.settings);
    if (d.configured) loadNodeTypes(true);
  });

  function setConn(ok, label) {
    var el = $('conn');
    el.textContent = label || (ok ? 'connected' : 'not configured');
    el.className = 'pill ' + (ok ? 'pill-ok' : 'pill-warn');
  }

  // Re-apply the node/template selection and prompts the user last had.
  function restoreLastUsed(s) {
    if (!s) return;
    state.selectedNode     = s.last_node_type || null;
    state.selectedTemplate = s.last_template_id || null;
    if (s.last_prompt) setVal('prompt', s.last_prompt);
    if (s.last_template_prompt) setVal('tpl-prompt', s.last_template_prompt);
  }

  // Fire-and-forget persistence, debounced so typing doesn't write per keystroke.
  var rememberTimer = null;
  function remember(patch) {
    clearTimeout(rememberTimer);
    rememberTimer = setTimeout(function () { call('remember', patch); }, 500);
  }

  function fillPrefs(s, downloadDir) {
    if (!s) return;
    $('key-hint').textContent = s.api_key_set ? '(' + s.api_key_hint + ' stored)' : '(not set)';
    $('base-url').value = text(s.base_url);
    $('web-url').value  = text(s.web_url);
    $('api-path').value = text(s.api_path);
    $('timeout').value  = text(s.request_timeout_seconds);
    $('retries').value  = text(s.max_retries);
    $('poll').value     = text(s.poll_interval_seconds);
    $('max-edge').value = text(s.capture_max_edge);
    $('dl-dir').value   = text(s.download_dir || downloadDir);
  }

  // ---- node types -------------------------------------------------------

  function loadNodeTypes(reset) {
    if (reset) { state.nodes = []; state.nodeCursor = null; }
    call('list_node_types', { limit: 100, cursor: state.nodeCursor, search: $('node-filter').value });
  }

  on('list_node_types', function (res) {
    if (!res.ok) return setStatus('render-status', errText(res.error), true);
    var d = res.data || {};
    var items = d.data || d.items || d.nodeTypes || [];
    state.nodes = state.nodes.concat(items);
    state.nodeCursor = d.nextCursor || d.cursor || null;
    $('node-more').disabled = !state.nodeCursor;

    var sel = $('node-type');
    var want = sel.value || state.selectedNode;
    sel.innerHTML = '';
    var found = false;
    state.nodes.forEach(function (n) {
      var id = n.type || n.nodeType || n.id;
      if (id === want) found = true;
      var o = document.createElement('option');
      o.value = id;
      o.textContent = (n.title ? n.title + '  —  ' : '') + id;
      sel.appendChild(o);
    });
    // The catalog is paginated and filterable, so the remembered node may not
    // be on this page; keep it selectable rather than silently losing it.
    if (want && !found) {
      var o = document.createElement('option');
      o.value = want;
      o.textContent = want + '   (last used)';
      sel.insertBefore(o, sel.firstChild);
    }
    if (want) sel.value = want;
    setStatus('render-status', state.nodes.length + ' node types loaded');
  });

  var filterTimer = null;
  $('node-filter').addEventListener('input', function () {
    clearTimeout(filterTimer);
    filterTimer = setTimeout(function () { loadNodeTypes(true); }, 250);
  });
  $('node-more').addEventListener('click', function () { loadNodeTypes(false); });

  $('node-type').addEventListener('change', function () {
    state.selectedNode = this.value;
    remember({ last_node_type: this.value });
  });
  $('prompt').addEventListener('input', function () {
    remember({ last_prompt: this.value });
  });
  bind('tpl-prompt', 'input', function () {
    remember({ last_template_prompt: this.value });
  });

  // ---- capture ----------------------------------------------------------

  $('capture').addEventListener('click', function () {
    setStatus('render-status', 'capturing…');
    state.captureTarget = 'render';
    call('capture');
  });
  bind('tpl-capture', 'click', function () {
    setStatus('tpl-status', 'capturing…');
    state.captureTarget = 'templates';
    call('capture');
  });

  on('capture', function (res) {
    var toTpl = state.captureTarget === 'templates';
    var statusId = toTpl ? 'tpl-status' : 'render-status';
    if (!res.ok) return setStatus(statusId, errText(res.error), true);

    var d = res.data;
    if (toTpl) state.tplCapturePath = d.path; else state.capturePath = d.path;
    showImage(toTpl ? 'tpl-capture-slot' : 'capture-slot', d.dataUri);
    setStatus(statusId, 'captured ' + d.width + '×' + d.height);

    if (state.pendingGenerate) { state.pendingGenerate = false; doGenerate(); }
    if (state.pendingTplRun)   { state.pendingTplRun = false;   doTemplateRun(); }
  });

  function showImage(slotId, dataUri) {
    var slot = $(slotId);
    if (!slot) return;
    slot.innerHTML = '';
    if (!dataUri) { slot.className = 'slot empty'; slot.textContent = 'no image'; return; }
    slot.className = 'slot';
    var img = document.createElement('img');
    img.src = dataUri;
    slot.appendChild(img);
  }

  // SketchUp's embedded browser ships no H.264 codec, so video cannot play
  // in-panel. Show a click-to-open poster instead.
  function showVideo(slotId, entry) {
    var slot = $(slotId);
    if (!slot) return;
    slot.className = 'slot';
    slot.innerHTML = '';
    var wrap = document.createElement('div');
    wrap.className = 'video-poster';
    var p = document.createElement('div');
    p.textContent = 'Video ready (' + text(entry.contentType) + ') — cannot play in-panel.';
    var btn = document.createElement('button');
    btn.textContent = 'Open in player';
    btn.addEventListener('click', function () { call('open_file', { path: entry.path }); });
    wrap.appendChild(p);
    wrap.appendChild(btn);
    slot.appendChild(wrap);
  }

  // ---- generate ---------------------------------------------------------

  $('generate').addEventListener('click', function () {
    if (!state.capturePath) {           // auto-capture, then continue
      state.pendingGenerate = true;
      state.captureTarget = 'render';
      setStatus('render-status', 'capturing…');
      return call('capture');
    }
    doGenerate();
  });

  function doGenerate() {
    var nodeType = $('node-type').value;
    if (!nodeType) return setStatus('render-status', 'Pick a node type first', true);
    busy('render', true);
    resetEvents();
    setStatus('render-status', 'submitting…');
    call('generate', { nodeType: nodeType, prompt: $('prompt').value, imagePath: state.capturePath });
  }

  on('generate', function (res) {
    if (!res.ok) { busy('render', false); return setStatus('render-status', errText(res.error), true); }
    setStatus('render-status', 'run ' + res.data.id + ' — ' + res.data.status);
  });

  // ---- templates --------------------------------------------------------

  function loadTemplates() { call('list_templates', { search: val('tpl-filter') }); }
  bind('tpl-reload', 'click', loadTemplates);

  var tplTimer = null;
  bind('tpl-filter', 'input', function () {
    clearTimeout(tplTimer);
    tplTimer = setTimeout(loadTemplates, 250);
  });

  on('list_templates', function (res) {
    if (!res.ok) return setStatus('tpl-status', errText(res.error), true);
    var d = res.data || {};
    state.templates = d.data || d.items || d.templates || [];
    var sel = $('tpl-select');
    if (!sel) return;
    sel.innerHTML = '';
    var runnable = 0;
    state.templates.forEach(function (t) {
      var o = document.createElement('option');
      var eps = t.endpoints || [];
      var ok = t.hasEndpoint !== false && eps.length > 0;
      o.value = t.templateId;
      o.setAttribute('data-endpoint', ok ? (eps[0].endpointId || '') : '');
      if (ok) runnable++;
      o.textContent = text(t.name || t.templateId) + (ok ? '' : '  (no endpoint)');
      o.disabled = !ok;
      sel.appendChild(o);
    });
    if (state.selectedTemplate) {
      var match = Array.prototype.filter.call(sel.options, function (o) {
        return o.value === state.selectedTemplate && !o.disabled;
      });
      if (match.length) sel.value = state.selectedTemplate;
    }
    setStatus('tpl-status', state.templates.length + ' templates, ' + runnable + ' runnable');
  });

  bind('tpl-select', 'change', function () {
    state.selectedTemplate = this.value;
    remember({ last_template_id: this.value });
  });

  bind('tpl-run', 'click', function () {
    if (!state.tplCapturePath) {
      state.pendingTplRun = true;
      state.captureTarget = 'templates';
      setStatus('tpl-status', 'capturing…');
      return call('capture');
    }
    doTemplateRun();
  });

  function doTemplateRun() {
    var sel = $('tpl-select');
    if (!sel || !sel.value) return setStatus('tpl-status', 'Pick a runnable template', true);
    busy('templates', true);
    setStatus('tpl-status', 'submitting…');
    var opt = sel.options[sel.selectedIndex];
    call('run_template', {
      templateId: sel.value,
      endpointId: opt.getAttribute('data-endpoint') || '',
      templateName: opt.textContent,
      prompt: val('tpl-prompt'),
      imagePath: state.tplCapturePath
    });
  }

  on('run_template', function (res) {
    if (!res.ok) { busy('templates', false); return setStatus('tpl-status', errText(res.error), true); }
    setStatus('tpl-status', 'run ' + text(res.data.id || res.data.taskId) + ' submitted');
  });

  // ---- run lifecycle ----------------------------------------------------

  function busy(where, isBusy) {
    state.runningIn = isBusy ? where : null;
    dis('generate', isBusy);
    dis('tpl-run', isBusy);
    dis('cancel', !(isBusy && where === 'render'));
    dis('tpl-cancel', !(isBusy && where === 'templates'));
  }

  on('run_status', function (res) {
    if (!res.ok) return;
    var id = state.runningIn === 'templates' ? 'tpl-status' : 'render-status';
    setStatus(id, 'status: ' + text(res.data.status));
  });

  // One line, updated in place. Nodes emit the same event repeatedly while
  // queued, so identical consecutive lines fold into a "x N" counter rather
  // than scrolling the panel.
  function eventLine(ev) {
    var pct = (ev.progress !== undefined && ev.progress !== null)
      ? ' ' + Math.round(ev.progress * 100) + '%' : '';
    return (text(ev.type || ev.kind) + pct + ' ' + text(ev.message || '')).trim();
  }

  function resetEvents() {
    state.lastEvent = null;
    state.lastEventCount = 0;
    $('render-events').textContent = '';
  }

  on('run_events', function (res) {
    if (!res.ok) return;
    (res.data || []).forEach(function (ev) {
      var line = eventLine(ev);
      if (!line) return;
      if (line === state.lastEvent) { state.lastEventCount++; }
      else { state.lastEvent = line; state.lastEventCount = 1; }
    });
    if (!state.lastEvent) return;
    var el = $('render-events');
    el.textContent = state.lastEvent;
    if (state.lastEventCount > 1) {
      var span = document.createElement('span');
      span.className = 'count';
      span.textContent = '  x' + state.lastEventCount;
      el.appendChild(span);
    }
  });

  on('run_done', function (res) {
    var where = state.runningIn || 'render';
    var statusId = where === 'templates' ? 'tpl-status' : 'render-status';
    var slotId   = where === 'templates' ? 'tpl-result-slot' : 'result-slot';
    busy(where, false);

    if (!res.ok) return setStatus(statusId, errText(res.error), true);

    var entry = res.data.entry;
    if (!entry) return setStatus(statusId, 'Run finished with no file output', true);

    if (res.data.dataUri) showImage(slotId, res.data.dataUri);
    else showVideo(slotId, entry);

    var credits = entry.creditsUsed !== undefined && entry.creditsUsed !== null
      ? ' — ' + entry.creditsUsed + ' credits' : '';
    setStatus(statusId, 'done: ' + entry.path + credits);
    renderHistory(res.data.history || []);
  });

  bind('cancel', 'click', function () { call('cancel_run', {}); });
  bind('tpl-cancel', 'click', function () { call('cancel_run', {}); });
  on('cancel_run', function (res) {
    if (!res.ok) setStatus('render-status', errText(res.error), true);
  });

  // ---- generations ------------------------------------------------------

  function renderHistory(items) {
    var body = $('hist-body');
    body.innerHTML = '';
    if (!items || !items.length) {
      var tr = document.createElement('tr');
      var td = document.createElement('td');
      td.colSpan = 5;
      td.className = 'muted';
      td.textContent = 'no generations yet';
      tr.appendChild(td);
      body.appendChild(tr);
      return;
    }
    items.forEach(function (it) {
      var tr = document.createElement('tr');
      tr.appendChild(cell(text(it.at).replace('T', ' ').replace(/\..*$/, '')));
      tr.appendChild(cell(text(it.kind)));
      tr.appendChild(cell(text(it.label)));
      var p = cell(text(it.prompt));
      p.className = 'prompt';
      tr.appendChild(p);

      var td = document.createElement('td');
      var a = document.createElement('a');
      a.textContent = it.path ? basename(it.path) : '—';
      if (it.path) {
        a.addEventListener('click', function () { call('open_file', { path: it.path }); });
      }
      td.appendChild(a);
      tr.appendChild(td);
      body.appendChild(tr);
    });
  }

  function cell(v) { var td = document.createElement('td'); td.textContent = v; return td; }
  function basename(p) { return String(p).split(/[\\/]/).pop(); }

  on('list_history',  function (res) { if (res.ok) renderHistory(res.data); });
  on('clear_history', function (res) { if (res.ok) renderHistory([]); });
  $('hist-reload').addEventListener('click', function () { call('list_history'); });
  $('hist-clear').addEventListener('click', function () { call('clear_history'); });

  // ---- preferences ------------------------------------------------------

  $('save-prefs').addEventListener('click', function () {
    setStatus('prefs-status', 'saving…');
    call('save_settings', {
      api_key: $('api-key').value,               // blank = keep stored key
      base_url: $('base-url').value,
      web_url: $('web-url').value,
      api_path: $('api-path').value,
      request_timeout_seconds: Number($('timeout').value) || 120,
      max_retries: Number($('retries').value) || 0,
      poll_interval_seconds: Number($('poll').value) || 2,
      capture_max_edge: Number($('max-edge').value) || 1024,
      download_dir: $('dl-dir').value
    });
  });

  on('save_settings', function (res) {
    if (!res.ok) return setStatus('prefs-status', errText(res.error), true);
    $('api-key').value = '';
    fillPrefs(res.data);
    setStatus('prefs-status', 'saved');
    loadNodeTypes(true);
  });

  $('test-conn').addEventListener('click', function () {
    setStatus('prefs-status', 'testing…');
    call('test_connection');
  });
  on('test_connection', function (res) {
    setConn(res.ok, res.ok ? 'connected' : 'error');
    setStatus('prefs-status', res.ok ? 'connected to ' + res.data.base : errText(res.error), !res.ok);
  });

  $('credits').addEventListener('click', function () { call('check_credits'); });
  on('check_credits', function (res) {
    if (!res.ok) return setStatus('prefs-status', errText(res.error), true);
    var d = res.data || {};
    var cents = d.balanceCents;
    setStatus('prefs-status', 'balance: ' + (cents !== undefined ? cents + ' cents' : JSON.stringify(d)) +
      (d.updatedAt ? ' (updated ' + d.updatedAt + ')' : ''));
  });

  $('open-log').addEventListener('click', function () { call('open_log'); });

  // ---- go ---------------------------------------------------------------
  call('boot');
})();
