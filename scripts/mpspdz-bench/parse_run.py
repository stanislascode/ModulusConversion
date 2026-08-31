import re, sys
t = open(sys.argv[1], errors='replace').read()
m = re.search(r'Time1 = ([\d.e+-]+) seconds \(([\d.e+-]+) MB, (\d+) rounds', t)
e = re.search(r'mismatches: (-?\d+)', t)
print('RUN_S=%s; RUN_MB=%s; RUN_ROUNDS=%s; RUN_ERR=%s' % (
    m.group(1) if m else 0, m.group(2) if m else 0,
    m.group(3) if m else 0, e.group(1) if e else -1))
