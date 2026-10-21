src = r'C:\Users\28226\Desktop\fpga比赛\doc\analysis\_extract\PDF_SC500CS_数据手册_V1.8.txt'
t = open(src, encoding='utf-8').read()
i = t.find('6 P D U W 6 H Q V')
print('index of SmartSens-looking string:', i)
if i > 0:
    print(repr(t[i-200:i+400]))
# count how many single-ASCII-char runs exist
import re
runs = re.findall(r'(?:[\x21-\x7e]\s){6,}', t)
print('single-char runs:', len(runs))
print('sample:', repr(runs[1][:120]) if len(runs)>1 else 'n/a')
