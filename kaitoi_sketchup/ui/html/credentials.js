/* Credentials editor. Secrets are typed here and sent to Ruby; stored values
 * are only ever shown as a hint, never sent back to the panel. */
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  function bind(id, ev, fn) { var e = $(id); if (e) e.addEventListener(ev, fn); }
  function val(id) { var e = $(id); return e ? e.value : ''; }
  function setVal(id, v) { var e = $(id); if (e) e.value = v === null || v === undefined ? '' : String(v); }
  function setText(id, v) { var e = $(id); if (e) e.textContent = v === null || v === undefined ? '' : String(v); }

  var handlers = {};
  function on(c, fn) { handlers[c] = fn; }
  window.kaitoi = {
    receive: function (c, p) { var f = handlers[c]; if (f) { try { f(p); } catch (e) { console.error(c, e); } } },
    focusSection: focusSection
  };

  function call(channel, payload) {
    if (!window.sketchup || typeof window.sketchup[channel] !== 'function') return;
    if (payload === undefined) window.sketchup[channel]();
    else window.sketchup[channel](JSON.stringify(payload));
  }

  function errText(v) {
    if (v === null || v === undefined) return 'unknown error';
    if (typeof v === 'string') return v;
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  }

  function status(id, msg, isError) {
    var el = $(id);
    if (!el) return;
    el.textContent = msg || '';
    el.className = 'status' + (isError ? ' err' : (msg ? ' ok' : ''));
  }

  function focusSection(which) {
    var api = $('sec-api'), mcp = $('sec-mcp');
    if (api) api.classList.toggle('focused', which === 'api');
    if (mcp) mcp.classList.toggle('focused', which === 'mcp');
    var target = which === 'mcp' ? $('mcp-token') : $('api-key');
    if (target) target.focus();
  }

  // Reveal what was typed, so a pasted token can actually be checked.
  Array.prototype.forEach.call(document.querySelectorAll('.reveal'), function (btn) {
    btn.addEventListener('click', function () {
      var input = $(btn.getAttribute('data-for'));
      if (!input) return;
      var hidden = input.type === 'password';
      input.type = hidden ? 'text' : 'password';
      btn.textContent = hidden ? 'Hide' : 'Show';
    });
  });

  function renderApiBase() {
    var base = val('base-url').replace(/\/+$/, '');
    var path = val('api-path').replace(/\/+$/, '');
    // Mirrors Settings.api_base: appending an api_path the base already ends
    // with would produce /api/v1/api/v1.
    var joined = (!path || base.slice(-path.length) === path) ? base : base + path;
    setText('api-base', joined || '(not set)');
  }
  bind('base-url', 'input', renderApiBase);
  bind('api-path', 'input', renderApiBase);

  on('creds_boot', function (res) {
    if (!res.ok) return status('api-status', errText(res.error), true);
    var d = res.data;
    setText('api-key-hint', d.apiKeySet ? d.apiKeyHint : '(not set)');
    setText('mcp-token-hint', d.mcpTokenSet ? d.mcpTokenHint : '(not set)');
    setVal('base-url', d.baseUrl);
    setVal('api-path', d.apiPath);
    setVal('mcp-url', d.mcpUrl);
    setText('config-path', d.configPath);
    setText('oauth-state', d.mcpTokenSet
      ? 'Using the stored MCP token.'
      : (d.oauthSignedIn ? 'No token set — signed in with OAuth.'
                         : 'No token set and not signed in — the Agent cannot connect yet.'));
    renderApiBase();
    focusSection(d.focus);
  });

  bind('save', 'click', function () {
    status('api-status', 'saving…');
    call('creds_save', {
      apiKey:   val('api-key'),
      mcpToken: val('mcp-token'),
      baseUrl:  val('base-url'),
      apiPath:  val('api-path'),
      mcpUrl:   val('mcp-url')
    });
  });

  on('creds_save', function (res) {
    if (!res.ok) return status('api-status', errText(res.error), true);
    var d = res.data;
    setVal('api-key', '');
    setVal('mcp-token', '');
    setText('api-key-hint', d.apiKeySet ? d.apiKeyHint : '(not set)');
    setText('mcp-token-hint', d.mcpTokenSet ? d.mcpTokenHint : '(not set)');
    setText('api-base', d.apiBase);
    status('api-status', d.saved.length ? 'saved: ' + d.saved.join(', ') : 'nothing changed');
  });

  bind('test-api', 'click', function () {
    status('api-status', 'testing…');
    call('creds_test_api');
  });
  on('creds_test_api', function (res) {
    status('api-status', res.ok ? 'connected to ' + res.data.base : errText(res.error), !res.ok);
  });

  bind('test-mcp', 'click', function () {
    status('mcp-status', 'testing…');
    call('creds_test_mcp');
  });
  on('creds_test_mcp', function (res) {
    if (!res.ok) return status('mcp-status', errText(res.error), true);
    var d = res.data;
    var name = (d.server && d.server.name) || 'server';
    status('mcp-status', 'connected via ' + d.mode + ' — ' + name + ', ' + d.tools + ' tools');
  });

  bind('open-config', 'click', function () { call('creds_open_config'); });

  call('creds_boot');
})();
