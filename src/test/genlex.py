# Writes into the directory given a file for each message the scanner
# makes, with the places diag shows them in: after a tab, in a long
# line, after characters of several bytes, in a CRLF file.
import sys
d = sys.argv[1]
cases = {
    "slip1": "x == y;\n", "slip2": "a && b;\n", "slip3": "a || b;\n", "slip4": "a != b;\n", "slip5": "!a;\n",
    "str": "x := \"abc\n", "chr": "x := 'a\n", "chr2": "x := 'ab';\n", "chr3": "x := '';\n",
    "esc": "x := \"\\q\";\n", "esc2": "x := 'a\\x41';\n", "esc3": "x := \"\\x4\";\n",
    "esc4": "x := \"\\u41\";\n", "esc5": "x := \"\\u{110000}\";\n", "esc6": "x := \"\\u{D800}\";\n",
    "esc7": "x := \"\\u{1234567}\";\n", "esc8": "x := \"\\u{}\";\n", "esc9": "x := \"\\u{41\";\n",
    "esc10": "x := \"\\u{1F600}\\u{e9}\\x00\\xff\\n\\t\\r\\0\\\\\\'\\\"\";\n",
    "cmt": "x := 1; (* open (* nested *)\n", "nul": "x := 1;\0 y;\n", "hexbad": "x := 12AB;\n",
    "hexbig": "x := 1FFFFFFFFFFFFFFFFH;\n", "hexok": "x := 0FFFFFFFFFFFFFFFFH; y := 7FFFFFFFFFFFFFFFH;\n",
    "decbig": "x := 9223372036854775808;\n", "decmax": "x := 9223372036854775807;\n",
    "realhex": "x := 1A.5;\n", "realexp": "x := 1.5E;\n", "realexp2": "x := 1.5E+;\n", "realbig": "x := 1.0E309;\n",
    "realmax": "x := 1.7976931348623159E308;\n", "reallong": "x := " + "1" * 254 + ".5;\n",
    "digname": "x := 12abc;\n", "uni": "x := \u00e9;\n", "badutf": b"x := \"a\xc3(\";\n", "badutf2": b"x := \"\xed\xa0\x80\";\n",
    "badutf3": b"x := \"\xc0\x80\";\n", "badutf4": b"x := \"\xf5\x80\x80\x80\";\n", "badutf5": b"x := \"\xe2\x82\";\n",
    "okutf": "x := \"h\u00e9llo \u20ac \U0001F600\"; y := '\u00e9'; (* \u00e9 *)\n",
    "unexp": "x := @;\n", "long": "x := " + "a + " * 60 + "@;\n", "longmid": "x := " + "a + " * 40 + "@ " + "+ b" * 40 + ";\n",
    "tab": "\t\tx := @;\n", "multi": "x := \"\u00e9\u00e9\u00e9\" + @;\n", "ident64": "x" * 64 + ";\n", "ident63": "x" * 63 + ";\n",
    "bigstr": "x := \"" + "a" * 70000 + "\";\n", "empty": "", "nonl": "x := y",
    "ops": "+ - * / = # < <= > >= := : ; , . .. ... ( ) [ ] { } ^ & ~ | _ __ _a\n",
    "words": "and begin break by code const defer div do else elsif end extern for forward if import in link match mod module not of or packed proc record repeat return set shl shr then to try type until var variant VOLATILE while xor Volatile\n",
}
for k, v in cases.items():
    open(f"{d}/{k}.raz", "wb").write(v.encode("utf-8", "surrogateescape") if isinstance(v, str) else v)
open(f"{d}/crlf.raz", "wb").write(b"x := 1;\r\ny := @;\r\n")
