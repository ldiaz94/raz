# Prints a raz module of reals that are hard to read exactly: the
# extremes, halves between neighbours, and many random ones.
import random
random.seed(7)
v = ["0.0", "1.0", "0.1", "4.9E-324", "2.4703282292062327E-324", "2.4703282292062328E-324",
     "2.2250738585072014E-308", "2.2250738585072011E-308", "1.7976931348623157E308",
     "9007199254740993.0", "9007199254740992.5", "9007199254740993.5", "0.000001E+3",
     "123456789012345678901234567890.0E-10", "1.0E-400", "0.5E1", "5.0E-1"]
for _ in range(3000):
    d = random.randint(1, 10 ** random.randint(1, 30))
    e = random.randint(-320, 300)
    s = str(d)
    v.append(s[0] + "." + (s[1:] or "0") + "E" + ("%+d" % e if random.random() < .5 else str(e)))
for _ in range(500):
    v.append("%d.%d" % (random.randint(0, 10 ** 6), random.randint(0, 10 ** 12)))
print("module Reals;\nvar x: F64;\nbegin")
for s in v:
    print("    x := " + s + ";")
print("end Reals.")
