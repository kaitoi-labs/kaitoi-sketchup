/* Kaitoi Agent panel.
 *
 * No HTTP here. Messages go to Ruby action callbacks; Ruby answers through
 * window.kaitoi.receive(), so the API key stays in Ruby.
 */
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  function bind(id, ev, fn) { var e = $(id); if (e) e.addEventListener(ev, fn); }
  function val(id) { var e = $(id); return e ? e.value : ''; }
  function setVal(id, v) { var e = $(id); if (e) e.value = (v === null || v === undefined) ? '' : String(v); }
  function setText(id, v) { var e = $(id); if (e) e.textContent = (v === null || v === undefined) ? '' : String(v); }

  var handlers = {};
  var state = { busy: false, attached: null, pendingCost: null, allowCost: false,
                lastSent: null, costButtons: null, progress: null };

  function call(channel, payload) {
    if (!window.sketchup || typeof window.sketchup[channel] !== 'function') {
      return say('err', 'bridge', 'Bridge unavailable: ' + channel);
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
  function on(c, fn) { handlers[c] = fn; }

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

  function text(v) { return v === null || v === undefined ? '' : String(v); }

  // ---- transcript -------------------------------------------------------

  function say(cls, who, body) {
    var t = $('transcript');
    var p = document.createElement('p');
    p.className = 'msg ' + cls;
    if (who) {
      var s = document.createElement('span');
      s.className = 'who';
      s.textContent = who + ':';
      p.appendChild(s);
    }
    p.appendChild(document.createTextNode(' ' + text(body)));
    t.appendChild(p);
    t.scrollTop = t.scrollHeight;
    return p;
  }

  // A live block in the transcript: node, percent, newest event, elapsed,
  // and the MCP tool currently running.
  function progressBox() {
    if (state.progress && state.progress.box) return state.progress;
    var box = document.createElement('div');
    box.className = 'progress';
    var head = document.createElement('div');
    head.className = 'head';
    var title = document.createElement('span');
    title.textContent = 'working…';
    var elapsed = document.createElement('span');
    elapsed.className = 'elapsed';
    head.appendChild(title); head.appendChild(elapsed);
    var bar = document.createElement('div');
    bar.className = 'bar';
    var fill = document.createElement('span');
    bar.appendChild(fill);
    var line = document.createElement('div');
    line.className = 'line';
    var tool = document.createElement('div');
    tool.className = 'tool';
    box.appendChild(head); box.appendChild(bar); box.appendChild(line); box.appendChild(tool);
    $('transcript').appendChild(box);
    $('transcript').scrollTop = $('transcript').scrollHeight;
    state.progress = { box: box, title: title, elapsed: elapsed, fill: fill, line: line, tool: tool };
    return state.progress;
  }

  function updateProgress(d) {
    var p = progressBox();
    if (d.node) p.title.textContent = text(d.node);
    else if (d.status) p.title.textContent = text(d.status);
    if (d.percent !== undefined && d.percent !== null) {
      p.fill.style.width = Math.max(0, Math.min(100, d.percent)) + '%';
    }
    if (d.elapsed !== undefined && d.elapsed !== null) {
      p.elapsed.textContent = d.elapsed + 's' +
        (d.percent ? ' · ' + d.percent + '%' : '') +
        (d.status ? ' · ' + text(d.status) : '');
    }
    if (d.message) p.line.textContent = text(d.message);
  }

  function setToolLine(tool, phase, detail) {
    var p = progressBox();
    var suffix = detail ? ' — ' + text(detail) : '';
    p.tool.textContent = (phase === 'done' ? '✓ ' : phase === 'error' ? '✗ ' : '▸ ') +
      text(tool) + suffix;
  }

  function endProgress() {
    state.progress = null;   // leave the finished block in the log
  }

  function setStatus(msg, isError) {
    var el = $('agent-status');
    el.textContent = msg || '';
    el.className = 'status' + (isError ? ' err' : (msg ? ' ok' : ''));
  }

  function setConn(ok, label) {
    var el = $('conn');
    el.textContent = label || (ok ? 'connected' : 'not connected');
    el.className = 'pill ' + (ok ? 'pill-ok' : 'pill-warn');
  }

  function busy(b) {
    state.busy = b;
    var send = $('send'); if (send) send.disabled = b;
    var cap = $('capture'); if (cap) cap.disabled = b;
  }

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

  // SketchUp's embedded browser has no H.264 codec, so video opens outside.
  function showFile(slotId, entry) {
    var slot = $(slotId);
    if (!slot) return;
    slot.className = 'slot';
    slot.innerHTML = '';
    var wrap = document.createElement('div');
    wrap.className = 'video-poster';
    wrap.appendChild(document.createTextNode(text(entry.contentType) + ' ready — cannot preview in-panel.'));
    var btn = document.createElement('button');
    btn.textContent = 'Open file';
    btn.addEventListener('click', function () { call('agent_open_file', { path: entry.path }); });
    wrap.appendChild(document.createElement('br'));
    wrap.appendChild(btn);
    slot.appendChild(wrap);
  }

  // ---- boot -------------------------------------------------------------

  on('agent_boot', function (res) {
    if (!res.ok) return setStatus(errText(res.error), true);
    var d = res.data;
    $('version').textContent = 'v' + d.version;
    state.attached = d.attached || null;
    $('attached').textContent = state.attached ? '(attached)' : '';
    state.authMode = d.authMode;
    $('signout').hidden = !(d.authMode === 'oauth' && d.signedIn);

    if (!d.signedIn) {
      setConn(false, 'not signed in');
      $('connect').hidden = false;
      say('tool', 'mcp', 'The MCP API is separate from the REST API and needs its own ' +
        'credential for ' + d.mcpUrl + '. Either mint a token in Kaitoi Studio → ' +
        'Settings → MCP and paste it into Preferences → MCP token, or click Connect ' +
        'to authorize in your browser.');
      return;
    }
    $('connect').hidden = true;
    say('tool', 'mcp', 'connecting to ' + d.mcpUrl + ' …');
    call('agent_connect');
  });

  bind('connect', 'click', function () {
    $('connect').disabled = true;
    setStatus('opening browser for sign-in…');
    say('tool', 'mcp', 'waiting for browser authorization…');
    call('agent_signin');
  });

  bind('signout', 'click', function () {
    call('agent_signout');
  });
  on('agent_signout', function () {
    setConn(false, 'signed out');
    say('tool', 'mcp', 'signed out');
    call('agent_boot');
  });

  on('agent_signin', function (res) {
    if (!res.ok) {
      $('connect').disabled = false;
      setStatus(errText(res.error), true);
      say('err', 'mcp', errText(res.error));
    }
  });

  on('agent_signin_done', function (res) {
    $('connect').disabled = false;
    if (!res.ok) {
      setStatus(errText(res.error), true);
      return say('err', 'mcp', errText(res.error));
    }
    $('connect').hidden = true;
    setStatus('signed in');
    say('tool', 'mcp', 'authorized');
    call('agent_connect');
  });

  on('agent_connect', function (res) {
    if (!res.ok) {
      setConn(false, 'error');
      $('connect').hidden = false;
      return say('err', 'mcp', errText(res.error));
    }
    $('signout').hidden = state.authMode !== 'oauth';
    var s = res.data.server || {};
    setConn(true, 'connected');
    say('tool', 'mcp', 'ready — ' + (s.name || 'server') + ' ' + (s.version || '') +
      ' · ' + text(res.data.toolCount) + ' tools');
    if (res.data.canRun === false) {
      say('err', 'mcp', 'This server exposes no run_node_by_search tool; generation is unavailable.');
    }
  });

  // ---- capture ----------------------------------------------------------

  bind('capture', 'click', function () {
    setStatus('capturing and uploading…');
    busy(true);
    call('agent_capture');
  });

  on('agent_capture', function (res) {
    busy(false);
    if (!res.ok) { setStatus(errText(res.error), true); return say('err', 'capture', errText(res.error)); }
    var d = res.data;
    state.attached = d.filename;
    $('attached').textContent = '(' + d.filename + ')';
    showImage('capture-slot', d.dataUri);
    setStatus('captured ' + d.width + '×' + d.height);
    say('tool', 'capture', 'viewport attached as ' + d.filename);
  });

  // ---- send -------------------------------------------------------------

  function send(confirmCost, idempotencyKey) {
    var t;
    if (confirmCost) {
      // The input was cleared when the message was first sent, so a cost
      // confirmation has to replay the text we actually sent.
      t = state.lastSent || '';
      if (!t) { setStatus('nothing to re-send', true); return; }
    } else {
      t = val('input').trim();
      if (!t) return;
      state.lastSent = t;
      say('user', 'you', t);
      setVal('input', '');
    }
    busy(true);
    setStatus('thinking…');
    call('agent_send', {
      text: t,
      useCapture: $('use-capture').checked,
      confirmCost: !!confirmCost,
      allowCost: !!state.allowCost,
      idempotencyKey: idempotencyKey || ''
    });
  }

  bind('send', 'click', function () { send(false); });
  bind('input', 'keydown', function (e) {
    // Enter sends; Shift+Enter makes a newline.
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(false); }
  });

  on('agent_send', function (res) {
    if (!res.ok) {
      busy(false);
      endProgress();
      releaseCostButtons();
      setStatus(errText(res.error), true);
      return say('err', 'mcp', errText(res.error));
    }
    var d = res.data;

    if (d.kind === 'cost') {
      busy(false);
      return askCost(d);
    }

    if (d.kind === 'choose') {
      busy(false);
      endProgress();
      return askChoice(d);
    }

    // Conversational reply from the chat node.
    if (d.reply) say('agent', 'kaitoi', d.reply);

    if (d.generate) {
      say('tool', 'run', d.generate.query + (d.generate.prompt ? ' — "' + d.generate.prompt + '"' : ''));
      // The search can match several nodes; show which one was actually used.
      var sel = d.run && d.run.selectedNode;
      if (sel && sel.from !== 'user') {
        say('tool', 'node', text(sel.title || sel.nodeType) +
          (sel.confidence ? ' · confidence ' + Number(sel.confidence).toFixed(2) : '') +
          (sel.from === 'ambiguous' ? ' — best of several close matches' : ''));
      }
      updateProgress({ status: 'starting', percent: 0, elapsed: 0,
                       message: d.generate.prompt || d.generate.query });
      return;                       // agent_status / agent_output follow
    }

    busy(false);
    endProgress();
    setStatus('');
  });

  // Costly nodes must be confirmed explicitly, with the same idempotency key
  // so a retry cannot launch a second paid run.
  // The raw preview is a nested object; a chat line should not be a JSON dump.
  function summarizeCost(preview) {
    if (!preview || typeof preview !== 'object') return text(preview);
    // Real shape: { requiresConfirmation, nodeType, providers:[{label,cost,costType}] }
    var providers = preview.providers;
    if (Object.prototype.toString.call(providers) === '[object Array]' && providers.length) {
      var parts = providers.map(function (p) {
        var cost = (p.cost === undefined || p.cost === null) ? '?' : p.cost;
        return text(p.label || p.name) + ' ' + cost + (p.costType ? ' ' + p.costType : '');
      });
      return parts.join(', ');
    }
    var c = preview.credits || preview.totalCredits || preview.estimatedCredits;
    if (c !== undefined && c !== null) return c + ' credits';
    try { return JSON.stringify(preview).slice(0, 160); } catch (e) { return 'unknown'; }
  }

  function releaseCostButtons() {
    (state.costButtons || []).forEach(function (b) { if (b) b.disabled = false; });
  }

  // Nothing matched the query semantically, so the user picks rather than
  // the agent guessing and spending credits on it.
  function askChoice(d) {
    say('tool', 'mcp', 'Several nodes matched "' + text(d.query) + '" and none clearly. Pick one:');
    var box = document.createElement('div');
    box.className = 'cost';
    var head = document.createElement('div');
    head.textContent = 'Choose a node';
    box.appendChild(head);
    var row = document.createElement('div');
    row.className = 'buttons';
    (d.candidates || []).forEach(function (c) {
      var b = document.createElement('button');
      b.className = 'ghost';
      b.textContent = text(c.title || c.nodeType) +
        (c.confidence ? ' · ' + Number(c.confidence).toFixed(2) : '');
      b.title = text(c.nodeType);
      b.addEventListener('click', function () {
        Array.prototype.forEach.call(row.children, function (x) { x.disabled = true; });
        say('tool', 'node', text(c.title || c.nodeType) + ' — chosen by you');
        busy(true);
        setStatus('running ' + text(c.title || c.nodeType) + '…');
        call('agent_run_node', { nodeType: c.nodeType });
      });
      row.appendChild(b);
    });
    box.appendChild(row);
    $('transcript').appendChild(box);
    $('transcript').scrollTop = $('transcript').scrollHeight;
  }

  function askCost(d) {
    state.pendingCost = { text: state.lastSent, key: d.idempotencyKey };
    var box = document.createElement('div');
    box.className = 'cost';
    var p = document.createElement('div');
    p.textContent = 'This costs credits: ' + summarizeCost(d.preview);
    var detail = document.createElement('div');
    detail.className = 'detail';
    try { detail.textContent = JSON.stringify(d.preview); } catch (e) { detail.textContent = ''; }
    var btn = document.createElement('button');
    btn.textContent = 'Confirm and run';
    btn.addEventListener('click', function () {
      btn.disabled = true;
      once.disabled = true;
      send(true, d.idempotencyKey);
    });
    var once = document.createElement('button');
    once.textContent = 'Allow for this session';
    once.className = 'ghost';
    once.addEventListener('click', function () {
      once.disabled = true;
      btn.disabled = true;
      state.allowCost = true;
      call('agent_allow_cost');
      send(true, d.idempotencyKey);
    });
    state.costButtons = [btn, once];
    var row = document.createElement('div');
    row.className = 'buttons';
    row.appendChild(btn);
    row.appendChild(once);
    box.appendChild(p);
    if (detail.textContent) box.appendChild(detail);
    box.appendChild(row);
    $('transcript').appendChild(box);
    $('transcript').scrollTop = $('transcript').scrollHeight;
  }

  on('agent_tool', function (res) {
    if (!res.ok) return;
    var d = res.data;
    setToolLine(d.tool, d.phase, d.detail);
    if (d.phase === 'start') setStatus('running ' + text(d.tool) + '…');
  });

  on('agent_status', function (res) {
    if (!res.ok) return;
    updateProgress(res.data);
    setStatus('status: ' + text(res.data.status) +
      (res.data.percent ? ' · ' + res.data.percent + '%' : ''));
  });

  on('agent_output', function (res) {
    busy(false);
    endProgress();
    if (!res.ok) { setStatus(errText(res.error), true); return say('err', 'run', errText(res.error)); }
    var d = res.data;
    if (d.kind === 'media' && d.entry) {
      if (d.dataUri) showImage('result-slot', d.dataUri);
      else showFile('result-slot', d.entry);
      say('agent', 'kaitoi', 'saved ' + d.entry.path);
      setStatus('done');
    } else {
      say('agent', 'kaitoi', d.text || '(no output)');
      setStatus('');
    }
  });

  bind('reset', 'click', function () {
    $('transcript').innerHTML = '';
    showImage('capture-slot', null);
    showImage('result-slot', null);
    $('capture-slot').textContent = 'no capture yet';
    $('result-slot').textContent = 'no result yet';
    state.attached = null;
    state.pendingCost = null;
    state.allowCost = false;
    state.lastSent = null;
    state.costButtons = null;
    state.progress = null;
    $('attached').textContent = '';
    call('agent_reset');
  });
  on('agent_reset', function () { setStatus('new session'); call('agent_boot'); });

  call('agent_boot');
})();
