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

  var handlers = {};
  var state = { busy: false, attached: null, pendingCost: null };

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
        'authorization. Click Connect to sign in to ' + d.mcpUrl + ' in your browser.');
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
    say('tool', 'mcp', 'ready — ' + (s.name || 'server') + ' ' + (s.version || ''));
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
    var t = val('input').trim();
    if (!t && !confirmCost) return;
    if (!confirmCost) { say('user', 'you', t); $('input').value = ''; }
    busy(true);
    setStatus('thinking…');
    call('agent_send', {
      text: t || (state.pendingCost && state.pendingCost.text) || '',
      useCapture: $('use-capture').checked,
      confirmCost: !!confirmCost,
      idempotencyKey: idempotencyKey || ''
    });
  }

  bind('send', 'click', function () { send(false); });
  bind('input', 'keydown', function (e) {
    // Enter sends; Shift+Enter makes a newline.
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(false); }
  });

  on('agent_send', function (res) {
    if (!res.ok) { busy(false); setStatus(errText(res.error), true); return say('err', 'mcp', errText(res.error)); }
    var d = res.data;
    if (d.text) say('tool', 'mcp', d.text.length > 600 ? d.text.slice(0, 600) + '…' : d.text);

    if (d.kind === 'cost') {
      busy(false);
      return askCost(d);
    }
    if (d.kind === 'pending') {
      setStatus('running (' + text(d.status || 'queued') + ')…');
      return;
    }
    setStatus('');
  });

  // Costly nodes must be confirmed explicitly, with the same idempotency key
  // so a retry cannot launch a second paid run.
  function askCost(d) {
    state.pendingCost = { text: val('input'), key: d.idempotencyKey };
    var box = document.createElement('div');
    box.className = 'cost';
    var p = document.createElement('div');
    p.textContent = 'This run costs credits: ' + text(JSON.stringify(d.preview));
    var btn = document.createElement('button');
    btn.textContent = 'Confirm and run';
    btn.addEventListener('click', function () {
      btn.disabled = true;
      send(true, d.idempotencyKey);
    });
    box.appendChild(p);
    box.appendChild(btn);
    $('transcript').appendChild(box);
    $('transcript').scrollTop = $('transcript').scrollHeight;
  }

  on('agent_status', function (res) {
    if (!res.ok) return;
    setStatus('status: ' + text(res.data.status));
  });

  on('agent_output', function (res) {
    busy(false);
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
    $('attached').textContent = '';
    call('agent_reset');
  });
  on('agent_reset', function () { setStatus('new session'); call('agent_boot'); });

  call('agent_boot');
})();
