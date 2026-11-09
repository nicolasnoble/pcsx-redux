// The rich editor of the Translate web view (translate-web.lua inlines this
// file). It shows the editable text form of VP.text.toEditable with every
// control code as a chip: a contenteditable=false span holding the exact
// {tag} text, so a chip is deleted whole and cannot be edited by accident,
// and the spellchecker skips it. serialize() gives back the same {tag} text,
// with literal braces doubled again, so the form still posts the text form
// that VP.text.fromEditable parses.
var VPRich = (function () {
  'use strict';

  // Splits text form into { text } runs (braces undoubled) and { tag } codes,
  // in the order VP.text.fromEditable reads them. Returns { segments } or
  // { error, at }.
  function parse(text) {
    var out = [], buf = '', i = 0;
    while (i < text.length) {
      var c = text[i];
      if (c === '{' && text[i + 1] === '{') { buf += '{'; i += 2; }
      else if (c === '}' && text[i + 1] === '}') { buf += '}'; i += 2; }
      else if (c === '}') { return { error: 'A lone } (write }} for the character)', at: i }; }
      else if (c === '{') {
        var close = text.indexOf('}', i);
        if (close < 0) return { error: 'Unclosed {', at: i };
        if (buf) { out.push({ text: buf }); buf = ''; }
        out.push({ tag: text.slice(i, close + 1) });
        i = close + 1;
      } else { buf += c; i++; }
    }
    if (buf) out.push({ text: buf });
    return { segments: out };
  }

  function escapeText(s) { return s.replace(/[{}]/g, '$&$&'); }

  function chip(tag) {
    var span = document.createElement('span');
    span.className = 'chip' + (tag === '{new}' ? ' chip-new' : '');
    span.contentEditable = 'false';
    span.setAttribute('data-tag', tag);
    span.title = tag;
    span.textContent = tag.slice(1, -1);
    return span;
  }

  // The end marker keeps a trailing newline visible; serialize skips it.
  function endMarker() {
    var br = document.createElement('br');
    br.setAttribute('data-end', '');
    return br;
  }

  function nodes(segments) {
    return segments.map(function (s) { return s.tag ? chip(s.tag) : document.createTextNode(s.text); });
  }

  // Fills el with the chips and text of `text`. Returns null, or the parse
  // error (el is then left unchanged).
  function render(el, text) {
    var p = parse(text);
    if (p.error) return p;
    el.textContent = '';
    nodes(p.segments).forEach(function (n) { el.appendChild(n); });
    el.appendChild(endMarker());
    return null;
  }

  function serialize(el) {
    var out = '';
    function walk(node) {
      for (var n = node.firstChild; n; n = n.nextSibling) {
        if (n.nodeType === 3) { out += escapeText(n.data); continue; }
        if (n.nodeType !== 1) continue;
        if (n.hasAttribute('data-tag')) { out += n.getAttribute('data-tag'); continue; }
        if (n.tagName === 'BR') { if (!n.hasAttribute('data-end')) out += '\n'; continue; }
        // A block the browser made on its own: it starts a line.
        if (/^(DIV|P)$/.test(n.tagName) && out !== '' && out[out.length - 1] !== '\n') out += '\n';
        walk(n);
      }
    }
    walk(el);
    return out;
  }

  function insertNodes(list) {
    var sel = window.getSelection();
    if (!sel.rangeCount) return;
    var r = sel.getRangeAt(0);
    r.deleteContents();
    var last = null;
    for (var i = list.length - 1; i >= 0; i--) { r.insertNode(list[i]); if (!last) last = list[i]; }
    if (last) {
      r.setStartAfter(last);
      r.collapse(true);
      sel.removeAllRanges();
      sel.addRange(r);
    }
  }

  // Makes `el` an editor bound to `textarea`: every edit writes the text form
  // back into it, so the form posts what the chips say.
  function attach(el, textarea) {
    if (el.vpSync) return el.vpSync;
    function sync() {
      if (!el.lastChild || !el.lastChild.hasAttribute || !el.lastChild.hasAttribute('data-end')) el.appendChild(endMarker());
      textarea.value = serialize(el);
      textarea.dispatchEvent(new Event('input'));
    }
    el.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter') {
        ev.preventDefault();
        insertNodes([document.createTextNode('\n')]);
        sync();
      }
    });
    // Pasted text form becomes chips; anything else is pasted as characters.
    el.addEventListener('paste', function (ev) {
      ev.preventDefault();
      var t = (ev.clipboardData || window.clipboardData).getData('text/plain').replace(/\r\n/g, '\n');
      var p = parse(t);
      var hasTag = p.segments && p.segments.some(function (s) { return s.tag; });
      insertNodes(hasTag ? nodes(p.segments) : [document.createTextNode(t)]);
      sync();
    });
    el.addEventListener('drop', function (ev) { ev.preventDefault(); });
    el.addEventListener('input', sync);
    el.vpSync = sync;
    return sync;
  }

  // Wires the page: every .rich-pair holds a textarea and a .rich div, and
  // #rich-toggle switches all of them between plain text and chips. The mode
  // is remembered in localStorage.
  function setup() {
    var pairs = Array.prototype.slice.call(document.querySelectorAll('.rich-pair'));
    var toggle = document.getElementById('rich-toggle');
    var msg = document.getElementById('rich-message');
    function show(rich) {
      if (rich) {
        for (var i = 0; i < pairs.length; i++) {
          var ta = pairs[i].querySelector('textarea');
          var e = parse(ta.value);
          if (e.error) {
            if (msg) msg.textContent = 'Cannot show chips: ' + e.error + ' at character ' + (e.at + 1) + '.';
            rich = false;
            break;
          }
        }
      }
      pairs.forEach(function (p) {
        var ta = p.querySelector('textarea'), div = p.querySelector('.rich');
        if (rich) { render(div, ta.value); div.style.display = ''; ta.style.display = 'none'; }
        else { div.style.display = 'none'; ta.style.display = ''; }
      });
      if (rich && msg) msg.textContent = '';
      if (toggle) toggle.checked = rich;
      try { localStorage.setItem('vp-rich', rich ? '1' : '0'); } catch (e) { }
    }
    pairs.forEach(function (p) {
      var ta = p.querySelector('textarea'), div = p.querySelector('.rich');
      if (!ta.readOnly) {
        var sync = attach(div, ta);
        var form = ta.form;
        if (form && !div.vpSubmit) {
          div.vpSubmit = true;
          form.addEventListener('submit', function () { if (div.style.display !== 'none') sync(); });
        }
      }
    });
    if (toggle && !toggle.vpBound) { toggle.vpBound = true; toggle.addEventListener('change', function () { show(toggle.checked); }); }
    var stored = null;
    try { stored = localStorage.getItem('vp-rich'); } catch (e) { }
    show(stored !== '0');
  }

  return { parse: parse, render: render, serialize: serialize, attach: attach, setup: setup };
})();
if (typeof document !== 'undefined' && document.readyState !== 'loading') { if (document.querySelector('.rich-pair')) VPRich.setup(); }
else if (typeof document !== 'undefined') document.addEventListener('DOMContentLoaded', function () { if (document.querySelector('.rich-pair')) VPRich.setup(); });
