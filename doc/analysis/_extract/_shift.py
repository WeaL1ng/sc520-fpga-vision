import re, os
src = os.path.join(r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract','PDF_SC500CS_数据手册_V1.8.txt')
txt = open(src, encoding='utf-8').read()
def shift(m):
    c = m.group(0)
    o = ord(c)
    return chr(o-29) if 29 <= o-29 < 127 else '?'
# The PDF's simple font uses a +29 code offset; undo it for ASCII glyph runs.
out = re.sub(r'[\x21-\x7e]', shift, txt)
# collapse the per-glyph spaces that the extractor emitted
out2 = re.sub(r'(?<=\S) (?=\S)', '', out)
open(os.path.join(r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract','PDF_SC500CS_shifted.txt'),'w',encoding='utf-8').write(out2)
print('written', len(out2))
