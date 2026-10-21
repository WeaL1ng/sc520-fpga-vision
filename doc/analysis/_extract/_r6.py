import sys, os
sys.path.insert(0, r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract')
from extract_docx import extract
p = r'C:\Users\28226\Desktop\fpga比赛\HX1P35A_Contest_202606\2_Example\示例介绍\31_北斗GPS模块定位显示实验.docx'
txt = extract(p)
open(os.path.join(r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract','DX_31_北斗GPS模块定位显示实验.txt'),'w',encoding='utf-8').write(txt)
print(txt)
