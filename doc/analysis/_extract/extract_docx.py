# -*- coding: utf-8 -*-
"""Extract text (and tables) from .docx by reading the OOXML zip directly.
No third-party deps. Handles w:p paragraphs, w:tbl tables, w:drawing anchors."""
import sys, os, zipfile, re
import xml.etree.ElementTree as ET

W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
A = '{http://schemas.openxmlformats.org/drawingml/2006/main}'
R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'


def para_text(p):
    parts = []
    for node in p.iter():
        tag = node.tag
        if tag == W + 't':
            parts.append(node.text or '')
        elif tag == W + 'tab':
            parts.append('\t')
        elif tag == W + 'br':
            parts.append('\n')
        elif tag == A + 'blip':
            parts.append('[[IMAGE]]')
        elif tag == W + 'drawing':
            pass
    return ''.join(parts)


def tbl_text(tbl):
    rows = []
    for tr in tbl.findall(W + 'tr'):
        cells = []
        for tc in tr.findall(W + 'tc'):
            txt = ' '.join(para_text(p).strip() for p in tc.findall(W + 'p'))
            cells.append(re.sub(r'\s+', ' ', txt).strip())
        rows.append(' | '.join(cells))
    return rows


def body_iter(el, out):
    for child in el:
        if child.tag == W + 'p':
            t = para_text(child).rstrip()
            if t.strip():
                out.append(t)
        elif child.tag == W + 'tbl':
            out.append('--- TABLE ---')
            out.extend(tbl_text(child))
            out.append('--- /TABLE ---')
        elif child.tag == W + 'sdt':
            content = child.find(W + 'sdtContent')
            if content is not None:
                body_iter(content, out)
        else:
            body_iter(child, out)


def extract(path):
    out = [f'########## FILE: {os.path.basename(path)} ##########']
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if 'word/document.xml' not in names:
            return f'!! no document.xml in {path}'
        xml = z.read('word/document.xml')
        root = ET.fromstring(xml)
        body = root.find(W + 'body')
        if body is not None:
            body_iter(body, out)
    return '\n'.join(out)


if __name__ == '__main__':
    for src in sys.argv[1:]:
        dst = src + '.txt'
        try:
            txt = extract(src)
        except Exception as e:
            txt = f'!! ERROR {src}: {e!r}'
        with open(dst, 'w', encoding='utf-8') as f:
            f.write(txt)
        print(f'{os.path.basename(src)} -> {len(txt)} chars')
