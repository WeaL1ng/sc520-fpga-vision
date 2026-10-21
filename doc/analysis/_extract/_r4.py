import sys, os
sys.path.insert(0, r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract')
from extract_docx import extract
p = r'C:\Users\28226\Desktop\fpga比赛\HX1P35A_Contest_202606\9_康芯开发板使用手册及实验平台\HX1P35B开发板引脚分配汇总.docx'
txt = extract(p)
open(os.path.join(r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract','DX_HX1P35B引脚分配汇总.txt'),'w',encoding='utf-8').write(txt)
print(txt)
