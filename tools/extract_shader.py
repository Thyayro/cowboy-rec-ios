import re, sys
s = open("Sources/LutBaker.swift", encoding="utf-8").read()
m = re.search(r"static let shader = \"\"\"\n(.*?)\n  \"\"\"", s, re.S)
open(sys.argv[1], "w").write(m.group(1))
