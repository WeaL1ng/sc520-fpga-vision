import sys, os
sys.path.insert(0, r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract')
from extract_pdf import extract_text
targets = [
 r'C:\Users\28226\Desktop\fpga比赛\SWUG111_TangDynasty调试工具使用指南_v1.0.pdf',
 r'C:\Users\28226\Desktop\fpga比赛\HX1P35安装驱动文档\PH1P35烧写程序的使用方法.pdf',
 r'C:\Users\28226\Desktop\fpga比赛\HX1P35安装驱动文档\Win10、Win11解决驱动签名问题.pdf',
]
for t in targets:
    if not os.path.exists(t): print('MISSING', t); continue
    try: txt = extract_text(t)
    except Exception as e: txt = 'ERROR %r' % (e,)
    dst = os.path.join(r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract', 'PDF_' + os.path.splitext(os.path.basename(t))[0] + '.txt')
    open(dst, 'w', encoding='utf-8').write(txt)
    print('OK %-45s %8d chars' % (os.path.basename(t), len(txt)))
