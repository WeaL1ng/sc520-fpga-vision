import sys, os
sys.path.insert(0, r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract')
from extract_docx import extract
outdir = r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract'
targets = [
 r'C:\Users\28226\Desktop\fpga比赛\2025安路赛题二相关Q&A.docx',
 r'C:\Users\28226\Desktop\fpga比赛\2026安路赛题一、二相关Q&A.docx',
 r'C:\Users\28226\Desktop\fpga比赛\设计参考文档\lab_ex_1.docx',
 r'C:\Users\28226\Desktop\fpga比赛\设计参考文档\lab_ex_2.docx',
 r'C:\Users\28226\Desktop\fpga比赛\设计参考文档\lab_ex_3.docx',
 r'C:\Users\28226\Desktop\fpga比赛\设计参考文档\lab_ex_4.docx',
 r'C:\Users\28226\Desktop\fpga比赛\设计参考文档\lab_ex_5.docx',
 r'C:\Users\28226\Desktop\fpga比赛\安路HX1P35A比赛文档2026 (1)\全国大学生嵌入式芯片与系统设计竞赛''2026选题指南_康芯.docx',
 r'C:\Users\28226\Desktop\fpga比赛\HX1P35安装驱动文档\安路TD开发工具软件安装教程.docx',
]
for t in targets:
    if not os.path.exists(t):
        print('MISSING:', t); continue
    base = os.path.splitext(os.path.basename(t))[0]
    try:
        txt = extract(t)
    except Exception as e:
        txt = 'ERROR %r' % (e,)
    p = os.path.join(outdir, 'DX_' + base + '.txt')
    with open(p, 'w', encoding='utf-8') as f:
        f.write(txt)
    print('%-60s %8d chars' % (base, len(txt)))
