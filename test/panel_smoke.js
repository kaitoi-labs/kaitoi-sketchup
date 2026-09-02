// Executes a panel's JS against a stubbed DOM built from its real HTML.
// node --check only parses; this catches undefined references and broken
// handlers at runtime, which is how `setVal` slipped through.
const fs = require('fs');
const path = require('path');

function makeEl(id) {
  const el = {
    id, value: '', textContent: '', innerHTML: '', className: '', type: 'text',
    checked: true, disabled: false, hidden: false, scrollTop: 0, scrollHeight: 0,
    style: {}, options: [], selectedIndex: 0, children: [],
    _handlers: {},
    classList: { toggle(){}, add(){}, remove(){}, contains(){ return false; } },
    addEventListener(ev, fn) { (this._handlers[ev] = this._handlers[ev] || []).push(fn); },
    removeEventListener(){}, appendChild(c){ this.children.push(c); return c; },
    insertBefore(c){ this.children.unshift(c); return c; },
    setAttribute(k, v){ this['_attr_' + k] = v; },
    getAttribute(k){ return this['_attr_' + k]; },
    focus(){}, click(){ this.fire('click'); },
    fire(ev, arg) { (this._handlers[ev] || []).forEach(fn => fn.call(this, arg || { preventDefault(){}, key: '' })); }
  };
  return el;
}

function run(htmlPath, jsPath, label, interactions) {
  const html = fs.readFileSync(htmlPath, 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  const ids = [...html.matchAll(/id="([^"]+)"/g)].map(m => m[1]);
  const els = new Map(ids.map(id => [id, makeEl(id)]));

  const calls = [];
  const doc = {
    getElementById: id => els.get(id) || null,
    createElement: tag => makeEl('created:' + tag),
    createTextNode: t => ({ textContent: t }),
    querySelectorAll: sel => {
      // .reveal buttons live in credentials.html
      if (sel.indexOf('reveal') !== -1) return ids.filter(i => /key|token/.test(i)).map(i => els.get(i));
      if (sel.indexOf('.tab') !== -1) return [];
      if (sel.indexOf('.panel') !== -1) return [];
      return [];
    }
  };
  const sketchup = new Proxy({}, {
    get: (_, name) => (payload) => calls.push({ name: String(name), payload }),
    has: () => true
  });

  const sandbox = {
    document: doc, window: {}, console: { error(){}, log(){}, warn(){} },
    setTimeout: (fn) => { fn(); return 0; }, clearTimeout(){}, Math, JSON, Date, String, Number,
    Object, Array, RegExp, Error
  };
  sandbox.window.sketchup = sketchup;
  sandbox.window.document = doc;

  const vm = require('vm');
  const ctx = vm.createContext(sandbox);
  let ok = true, err = null;
  try {
    vm.runInContext(fs.readFileSync(jsPath, 'utf8'), ctx, { filename: path.basename(jsPath) });
  } catch (e) { ok = false; err = e; }

  console.log(`\n== ${label}`);
  if (!ok) { console.log(`   LOAD FAILED: ${err.name}: ${err.message}`); return false; }
  console.log(`   loaded ok; boot called: ${calls.map(c => c.name).join(', ') || '(none)'}`);

  let pass = true;
  (interactions || []).forEach(step => {
    const before = calls.length;
    let thrown = null;
    try { step.run(els, sandbox); } catch (e) { thrown = e; }
    const fired = calls.slice(before).map(c => c.name);
    if (thrown) { console.log(`   FAIL  ${step.name}: ${thrown.name}: ${thrown.message}`); pass = false; }
    else if (step.expect && !fired.includes(step.expect)) {
      console.log(`   FAIL  ${step.name}: expected ${step.expect}, got [${fired.join(', ') || 'nothing'}]`); pass = false;
    } else {
      console.log(`   ok    ${step.name} -> ${fired.join(', ') || '(no call)'}`);
    }
  });
  return pass;
}

const H = path.join(__dirname, '..', 'kaitoi_sketchup', 'ui', 'html');
let allPass = true;

allPass &= run(H + '/agent.html', H + '/agent.js', 'agent.js', [
  { name: 'type + Send', expect: 'agent_send', run: (els) => {
      els.get('input').value = 'can you create an illustration';
      els.get('send').fire('click');
  }},
  { name: 'input cleared after send', run: (els) => {
      if (els.get('input').value !== '') throw new Error('input not cleared: ' + JSON.stringify(els.get('input').value));
  }},
  { name: 'Capture view', expect: 'agent_capture', run: (els) => els.get('capture').fire('click') },
  { name: 'New session', expect: 'agent_reset', run: (els) => els.get('reset').fire('click') },
]);

allPass &= run(H + '/index.html', H + '/app.js', 'app.js', [
  { name: 'Generate', expect: 'capture', run: (els) => els.get('generate').fire('click') },
  { name: 'Save prefs', expect: 'save_settings', run: (els) => els.get('save-prefs').fire('click') },
  { name: 'Test connection', expect: 'test_connection', run: (els) => els.get('test-conn').fire('click') },
]);

allPass &= run(H + '/credentials.html', H + '/credentials.js', 'credentials.js', [
  { name: 'Save', expect: 'creds_save', run: (els) => els.get('save').fire('click') },
  { name: 'Test REST', expect: 'creds_test_api', run: (els) => els.get('test-api').fire('click') },
  { name: 'Test MCP', expect: 'creds_test_mcp', run: (els) => els.get('test-mcp').fire('click') },
]);

console.log(allPass ? '\nALL PANELS PASS' : '\nFAILURES ABOVE');
process.exit(allPass ? 0 : 1);
