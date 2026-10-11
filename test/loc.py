"""Counts the lines of the compiler's units, or of raz modules: all of
them, and the lines of code, those that are neither blank nor only
comment. In raz, { and } are literals, not comments."""
import re, sys

total = code = 0
for path in sys.argv[1:]:
    text = open(path).read()
    comment = r"\(\*.*?\*\)" if path.endswith(".raz") else r"\{[^}]*\}|\(\*.*?\*\)"
    bare = re.sub(comment, "", text, flags=re.S)
    n = text.count("\n")
    c = sum(1 for line in bare.split("\n") if line.strip())
    print(f"{path:18} {n:6} {c:6}")
    total += n
    code += c
print(f"{'total':18} {total:6} {code:6}")
