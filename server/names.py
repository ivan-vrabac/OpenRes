"""Company name rules (owner 2026-10-23): no rude names, no impersonation, no characters that could
break the game. 3-25 characters (owner 2026-11-02): letters of real alphabets, Chinese, Japanese and Korean,
digits and . , [ ] ( ) - and single spaces. No emoji, symbols or huge signs (a list of what is allowed,
because cuneiform and the like count as "letters" to Unicode too).

Rude words are found even when written with digits or symbols (n1gg3r, f.u.c.k, sh!t) or with
repeated letters (fuuuck): the name is lower-cased, look-alike characters are mapped to letters,
separators removed and repeated letters collapsed before the check. Long words are matched
anywhere in the name; short ones only as a whole word (so "scunthorpe"-style names survive).
"""
from __future__ import annotations

import re
import unicodedata

MIN_LEN, MAX_LEN = 3, 25
RULE = f"{MIN_LEN}-{MAX_LEN} letters, digits, spaces and . , [ ] ( ) -"
SYMBOLS = " .,[]()-"
# (first, last, script)
ALPHABETS = (
    (0x00C0, 0x024F, "latin"), (0x1E00, 0x1EFF, "latin"), (0x0370, 0x03FF, "greek"), (0x0400, 0x04FF, "cyrillic"),
    (0x05D0, 0x05EA, "hebrew"), (0x0620, 0x063F, "arabic"), (0x0641, 0x064A, "arabic"), (0x066E, 0x06D3, "arabic"),
    (0x0900, 0x097F, "devanagari"), (0x0E01, 0x0E3A, "thai"), (0x0E40, 0x0E4E, "thai"), (0x3040, 0x30FF, "kana"),
    (0x3400, 0x4DBF, "han"), (0x4E00, 0x9FFF, "han"), (0xAC00, 0xD7A3, "hangul"),
)


def _script(c: str) -> str | None:
    if "a" <= c.lower() <= "z" and c.isascii():
        return "latin"
    n = ord(c)
    for lo, hi, name in ALPHABETS:
        if lo <= n <= hi:
            return name
    return None


def _allowed(c: str) -> bool:
    if c in SYMBOLS or (c.isascii() and c.isdigit()):
        return True
    script, cat = _script(c), unicodedata.category(c)
    return script is not None and (cat[0] == "L" or (cat[0] == "M" and script in ("devanagari", "thai")))
LEET = str.maketrans({"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "9": "g",
                      "@": "a", "$": "s", "!": "i", "|": "i", "+": "t"})
# matched anywhere (after normalising)
ANYWHERE = (
    "nigger", "niger", "nigga", "niga", "faggot", "fagot", "retard", "cunt", "fuck", "fuk", "shit", "bitch",
    "whore", "slut", "rapist", "rape", "nazi", "hitler", "heil", "porn", "penis", "vagina", "pussy",
    "asshole", "bastard", "wank", "jizz", "dildo", "blowjob", "boner", "cock", "dick", "tits", "boob",
    "pedo", "paedo", "molest", "incest", "genocide", "terrorist", "jihad", "hamas", "holocaust",
    "kurac", "kurca", "picka", "pizda", "jebem", "jebi", "jebo", "peder", "kurva", "govno", "sranje",
    "cigan", "debil", "kreten", "idiot", "moron", "suicide", "killyourself", "kys",
    # impersonating the game or its staff
    "moderator", "gamemaster", "openresteam",
)
# matched as a whole word only
WHOLE = ("fag", "cum", "sex", "anal", "ass", "hoe", "tit", "nig", "kill", "die", "mod", "gm",
         "system", "server", "null", "undefined", "none", "admin", "official", "support", "staff", "kkk")


def _norm(s: str) -> str:
    s = s.lower().translate(LEET)
    return re.sub(r"(.)\1{2,}", r"\1", s)        # fuuuck → fuck (runs of 3+; doubles stay: glass, kitty)


def _stacked(name: str) -> bool:
    """Marks piled on one letter: the tall glitchy text."""
    run = 0
    for c in name:
        run = run + 1 if unicodedata.category(c)[0] == "M" else 0
        if run > 2:
            return True
    return False


def name_problem(name: str) -> str | None:
    """None if the name is fine, else a message for the player."""
    name = unicodedata.normalize("NFC", name or "")
    if not MIN_LEN <= len(name) <= MAX_LEN or not all(_allowed(c) for c in name):
        return f"Name: {RULE}"
    if _stacked(name):
        return f"Name: {RULE}"
    # Latin next to its look-alikes is how a name pretends to be another one
    if len({_script(c) for c in name} & {"latin", "greek", "cyrillic"}) > 1:
        return "Use one alphabet in your company name"
    if "  " in name or name != name.strip():
        return "No double spaces or spaces at the start or end"
    if not any(c.isalpha() for c in name):
        return "The name needs at least one letter"
    if re.search(r"[.,\[\]()\-]{3,}", name):
        return "Too many symbols in a row"
    flat = _norm(re.sub(r"[^a-z0-9@$!|+]", "", name.lower()))      # separators out first: n.i.g.g.a
    tokens = {t for t in re.split(r"[^a-z]+", _norm(name)) if t}
    if any(w in flat for w in _ANYWHERE_N) or tokens & _WHOLE_N or "kkk" in name.lower():
        return ("This name is not allowed. Rude or misleading names are not accepted, and accounts "
                "with such names can be banned or deleted.")
    return None


_ANYWHERE_N = tuple(_norm(w) for w in ANYWHERE)     # words normalised like names (repeats collapsed)
_WHOLE_N = {_norm(w) for w in WHOLE}
