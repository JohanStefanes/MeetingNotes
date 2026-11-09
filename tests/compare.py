"""Compare a meeting transcript with the text that was read aloud.

    python3 tests/compare.py tests/texte/02-fachbegriffe.txt ~/Meetings/2026-11-08_1015_test-2.md
    python3 tests/compare.py --selftest

Prints the word error rate (WER: substituted + missing + extra words, divided by the words of the text), the text
with the mistakes marked inline ([-gesagt-]{+erkannt+}), and terms worth adding to ~/Meetings/Wörterbuch.txt.
Spelling-only differences don't count: case, punctuation, ß/ss, hyphens and number separators (48'500 = 48500).
"""
import re
import sys


def transcript(md):
    """Spoken text of a meeting file: the Transcript section without timestamps and speaker names."""
    m = re.search(r"\n## Transcript\n(.*?)(?=\n## |\Z)", md, re.S)
    body = m.group(1) if m else md
    body = re.sub(r"\[\d\d:\d\d:\d\d\]\s*", " ", body)
    body = re.sub(r"\*\*[^*]{1,40}:\*\*|\bSprecher \d+:", " ", body)
    return body


def reference(text):
    """Read-aloud text without comment lines and dialog roles ("DU: ", "ANNA: ")."""
    lines = [l for l in text.splitlines() if not l.startswith("#")]
    return "\n".join(re.sub(r"^[A-ZÄÖÜ]+:\s*", "", l) for l in lines)


def words(text):
    """Normalized words, each with its original spelling for display."""
    text = re.sub(r"(?<=\d)['’](?=\d)", "", text)             # 48'500 → 48500
    out = []
    for raw in re.findall(r"\d+(?:[.,:]\d+)*|[\w]+(?:-[\w]+)*", text):
        for part in raw.split("-"):                           # Refresh-Token = Refresh Token
            norm = part.lower().replace("ß", "ss")
            if norm:
                out.append((norm, part))
    return out


def align(ref, hyp):
    """Word-level edit distance with backtrace → list of (op, ref_word, hyp_word), op in = sub del ins."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            same = ref[i - 1][0] == hyp[j - 1][0]
            d[i][j] = min(d[i - 1][j - 1] + (0 if same else 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
    ops, i, j = [], n, m
    while i or j:
        if i and j and d[i][j] == d[i - 1][j - 1] + (ref[i - 1][0] != hyp[j - 1][0]):
            ops.append(("=" if ref[i - 1][0] == hyp[j - 1][0] else "sub", ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", ref[i - 1], None))
            i -= 1
        else:
            ops.append(("ins", None, hyp[j - 1]))
            j -= 1
    return ops[::-1]


def report(ref_text, hyp_text):
    ref, hyp = words(ref_text), words(hyp_text)
    ops = align(ref, hyp)
    errors = sum(op != "=" for op, _, _ in ops)
    wer = errors / max(len(ref), 1)
    marked, pairs = [], []
    k = 0
    while k < len(ops):   # group a run of mistakes into one [-…-]{+…+} block
        if ops[k][0] == "=":
            marked.append(ops[k][1][1]); k += 1
            continue
        said, heard = [], []
        while k < len(ops) and ops[k][0] != "=":
            _, r, h = ops[k]
            if r: said.append(r[1])
            if h: heard.append(h[1])
            k += 1
        marked.append((f"[-{' '.join(said)}-]" if said else "") + (f"{{+{' '.join(heard)}+}}" if heard else ""))
        pairs.append((" ".join(said), " ".join(heard)))
    # names and jargon (capitalised mid-sentence, digits, or mixed case) that came out wrong → dictionary candidates
    vocab = sorted({w for s, _ in pairs for w in s.split()
                    if re.search(r"[A-Z].*[A-Z]|\d|^[A-Z][a-z]+[A-Z]", w) or w in {"jks", "Claude", "Dion", "Lena"}})
    return wer, errors, len(ref), " ".join(marked), pairs, vocab


def main(ref_path, md_path):
    with open(ref_path, encoding="utf-8") as f:
        ref_text = reference(f.read())
    with open(md_path, encoding="utf-8") as f:
        hyp_text = transcript(f.read())
    wer, errors, total, marked, pairs, vocab = report(ref_text, hyp_text)
    print(f"WER {wer:.1%}  ({errors} Fehler auf {total} Wörter)\n")
    print(marked, "\n")
    if pairs:
        print("Fehler (gesagt → erkannt):")
        for said, heard in pairs:
            print(f"  {said or '∅'} → {heard or '∅'}")
    if vocab:
        print("\nKandidaten fürs Wörterbuch:", ", ".join(vocab))


def selftest():
    assert transcript("# M\n\n## Transcript\n\n[00:00:01] **Johan:** Hallo  \n[00:00:04] Sprecher 2: Welt  \n\n## Meine Notizen\n\nx") \
        .split() == ["Hallo", "Welt"]
    assert [w for w, _ in words("Der Refresh-Token kostet 48'500 Franken, Straße 2,4!")] == \
        ["der", "refresh", "token", "kostet", "48500", "franken", "strasse", "2,4"]
    wer, errors, total, marked, pairs, vocab = report("Wir deployen OpenTwin auf Vercel heute",
                                                      "wir deployen open twin auf vercel")
    assert (errors, total) == (3, 6) and pairs == [("OpenTwin", "open twin"), ("heute", "")], pairs
    assert marked == "Wir deployen [-OpenTwin-]{+open twin+} auf Vercel [-heute-]" and vocab == ["OpenTwin"]
    assert report("Gleich.", "gleich")[:2] == (0.0, 0)
    assert reference("# Kommentar\nDU: Hallo Anna.\nANNA: Hi.") == "Hallo Anna.\nHi."
    print("compare selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif len(sys.argv) == 3:
        main(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
