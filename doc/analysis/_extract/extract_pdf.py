# -*- coding: utf-8 -*-
"""Minimal dependency-free PDF text extractor.

Decompresses FlateDecode content streams and pulls text-showing operands
(Tj, TJ, ', ").  Handles both literal strings and hex strings, and applies
ToUnicode CMaps when the PDF embeds simple bfchar/bfrange mappings.
This is deliberately best-effort: it is meant for pulling table/paragraph
text out of vendor datasheets, not for layout fidelity.
"""
import re, sys, zlib, os


def _streams(data):
    """Yield decoded content streams in file order."""
    for m in re.finditer(rb'stream\r?\n', data):
        start = m.end()
        end = data.find(b'endstream', start)
        if end == -1:
            continue
        raw = data[start:end]
        if raw.endswith(b'\r\n'):
            raw = raw[:-2]
        elif raw.endswith(b'\n') or raw.endswith(b'\r'):
            raw = raw[:-1]
        try:
            yield zlib.decompress(raw)
        except Exception:
            continue


def _to_unicode_maps(data):
    """Collect bfchar/bfrange mappings from ToUnicode CMaps found in the file."""
    cmap = {}
    for cm in re.finditer(rb'beginbfchar(.*?)endbfchar', data, re.S):
        body = cm.group(1)
        for pair in re.finditer(rb'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>', body):
            src = int(pair.group(1), 16)
            dsthex = pair.group(2).decode()
            try:
                dst = ''.join(chr(int(dsthex[i:i + 4], 16)) for i in range(0, len(dsthex), 4))
            except Exception:
                continue
            cmap[src] = dst
    for cm in re.finditer(rb'beginbfrange(.*?)endbfrange', data, re.S):
        body = cm.group(1)
        for r in re.finditer(rb'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>', body):
            lo = int(r.group(1), 16); hi = int(r.group(2), 16); dst = int(r.group(3), 16)
            for i in range(lo, min(hi, lo + 4096) + 1):
                cmap[i] = chr(dst + (i - lo))
    return cmap


_ESC = {b'n': '\n', b'r': '\r', b't': '\t', b'b': '\b', b'f': '\f',
        b'(': '(', b')': ')', b'\\': '\\'}


def _unescape_literal(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i:i + 1]
        if c == b'\\' and i + 1 < len(s):
            nxt = s[i + 1:i + 2]
            if nxt in _ESC:
                out.append(_ESC[nxt]); i += 2; continue
            m = re.match(rb'[0-7]{1,3}', s[i + 1:i + 4])
            if m:
                out.append(chr(int(m.group(0), 8))); i += 1 + len(m.group(0)); continue
            i += 2; continue
        out.append(c.decode('latin-1')); i += 1
    return ''.join(out)


def _decode_hexstring(h, cmap):
    h = re.sub(rb'[^0-9A-Fa-f]', b'', h).decode()
    if len(h) % 2:
        h += '0'
    if cmap:
        out = []
        # try 2-byte codes first (typical for CID fonts)
        if len(h) % 4 == 0:
            for i in range(0, len(h), 4):
                code = int(h[i:i + 4], 16)
                out.append(cmap.get(code, ''))
            if any(out):
                return ''.join(out)
        out = []
        for i in range(0, len(h), 2):
            code = int(h[i:i + 2], 16)
            out.append(cmap.get(code, chr(code) if 32 <= code < 127 else ''))
        return ''.join(out)
    try:
        b = bytes.fromhex(h)
    except Exception:
        return ''
    return b.decode('latin-1')


_TOKEN = re.compile(rb'''
    \((?:\\.|[^\\()])*\)          # literal string
  | <[0-9A-Fa-f\s]*>              # hex string
  | \bTj\b | \bTJ\b | \bTd\b | \bTD\b | \bT\*\b | \bET\b | \bBT\b
''', re.X | re.S)


def extract_text(path, max_chars=None):
    data = open(path, 'rb').read()
    cmap = _to_unicode_maps(data)
    chunks = []
    for stream in _streams(data):
        if b'Tj' not in stream and b'TJ' not in stream:
            continue
        buf = []
        for m in _TOKEN.finditer(stream):
            tok = m.group(0)
            if tok.startswith(b'('):
                buf.append(_unescape_literal(tok[1:-1]))
            elif tok.startswith(b'<'):
                buf.append(_decode_hexstring(tok[1:-1], cmap))
            elif tok in (b'Td', b'TD', b'T*', b'ET'):
                buf.append('\n')
            elif tok == b'TJ':
                pass
        text = ''.join(buf)
        text = re.sub(r'\n{2,}', '\n', text)
        if text.strip():
            chunks.append(text)
        if max_chars and sum(len(c) for c in chunks) > max_chars:
            break
    return '\n\n========== PAGE BREAK ==========\n\n'.join(chunks)


if __name__ == '__main__':
    for src in sys.argv[1:]:
        try:
            txt = extract_text(src)
        except Exception as e:
            txt = 'ERROR %r' % (e,)
        dst = os.path.splitext(src)[0] + '.pdftxt.txt'
        with open(dst, 'w', encoding='utf-8') as f:
            f.write(txt)
        print('%-50s %8d chars -> %s' % (os.path.basename(src), len(txt), os.path.basename(dst)))
        print(txt[:600].replace('\n', ' | ')[:600])
        print('-' * 100)
