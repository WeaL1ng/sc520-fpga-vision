import sys, os
sys.path.insert(0, r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract')
from extract_docx import extract
p = r'C:\Users\28226\Desktop\fpga比赛\HX1P35A_Contest_202606\2_Example\33_ethernet_udp_led\uisrc\05_doc\ethernet_udp_led.docx'
txt = extract(p)
open(os.path.join(r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract','DX_ethernet_udp_led.txt'),'w',encoding='utf-8').write(txt)
print(txt[:3000])
