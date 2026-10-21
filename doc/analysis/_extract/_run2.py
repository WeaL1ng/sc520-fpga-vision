import sys, os, glob
sys.path.insert(0, r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract')
from extract_docx import extract
outdir = r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract'
base = r'C:\Users\28226\Desktop\fpga比赛'
for p in glob.glob(os.path.join(base, '**', '*.docx'), recursive=True):
    name = os.path.basename(p)
    if name.startswith('DX_'):
        continue
    tag = 'DX_' + os.path.splitext(name)[0] + '.txt'
    dst = os.path.join(outdir, tag)
    if os.path.exists(dst):
        continue
    try:
        txt = extract(p)
    except Exception as e:
        txt = 'ERROR %r' % (e,)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(txt)
    print('%-45s %7d  <- %s' % (tag, len(txt), p.replace(base, '.')))
