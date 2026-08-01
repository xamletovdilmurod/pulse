#!/usr/bin/env python3
"""Generate the LoRA training set for Pulse's expense-extraction model.

682 hand-authored gold utterances is a good benchmark but a thin training set, so this script
recombines the *same lexicons the humans drew on* into thousands of additional examples with exactly
known labels. Every generated utterance is assembled from real vocabulary — real magnitude words, real
category keywords, real merchants, real date expressions in both Uzbek scripts — so the model sees the
distribution it will actually meet, not translationese.

Two rules keep the result honest:

1. **The gold corpus is never trained on.** It is held out entirely as the test set. Training on your
   benchmark tells you only that the model memorised it.
2. **Labels are computed, not guessed.** The generator knows the ground truth because it chose it
   before rendering the text, so there is no labelling noise at all in the synthetic half.

Usage:
    python3 ml/scripts/generate_training_data.py [--count 6000] [--seed 20260802]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[2]
LEXICON_DIR = ROOT / "ml" / "data" / "lexicon"
CORPUS_DIR = ROOT / "ml" / "data" / "corpus"
OUT_DIR = ROOT / "ml" / "data" / "generated"

# The instruction the model is trained against. Kept short: every token of it is paid for on every
# single inference, on a phone, and the task is learned from the examples rather than the prose.
SYSTEM_PROMPT = (
    "Extract the transaction from the user's message as JSON with keys: "
    "kind, amount, currency, category, merchant, note, date, confidence. "
    "The user writes in Uzbek, Russian, or English. "
    "Use null for anything not stated. Do not guess."
)

EXPENSE_CATEGORIES = [
    "groceries", "dining", "cafe_coffee", "transport", "fuel", "rent", "utilities", "health",
    "education", "clothing", "entertainment", "gifts", "travel", "communication", "subscriptions",
    "family", "household", "beauty", "pets", "charity", "fees", "other",
]
INCOME_CATEGORIES = [
    "salary", "freelance", "business", "gift_received", "refund", "investment", "other_income",
]

# Fractional sub-units. A hundredth of a currency, never the currency itself.
SUBUNIT_WORDS = {
    "cent", "cents", "penny", "pence", "tiyin", "тийин",
    "копейка", "копейки", "копеек", "коп", "kopek", "kopeck",
}

# Realistic so'm price bands per category, in thousands. Generating a 300-so'm rent or a
# 40-million-so'm coffee would teach the model that amounts are unrelated to what was bought.
PRICE_BANDS_THOUSANDS = {
    "groceries": (15, 400), "dining": (25, 200), "cafe_coffee": (10, 80),
    "transport": (8, 80), "fuel": (50, 500), "rent": (2000, 12000),
    "utilities": (50, 900), "health": (30, 1500), "education": (200, 15000),
    "clothing": (80, 2000), "entertainment": (30, 400), "gifts": (50, 1500),
    "travel": (500, 20000), "communication": (20, 200), "subscriptions": (15, 150),
    "family": (100, 3000), "household": (30, 800), "beauty": (40, 400),
    "pets": (30, 300), "charity": (50, 1000), "fees": (10, 500), "other": (20, 500),
    "salary": (3000, 25000), "freelance": (500, 15000), "business": (1000, 50000),
    "gift_received": (100, 5000), "refund": (30, 800), "investment": (500, 20000),
    "other_income": (100, 3000),
}


def load_lexicons() -> dict[str, dict]:
    out = {}
    for path in sorted(LEXICON_DIR.glob("*.json")):
        if path.name == "merged.json":
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        out[data["language"]] = data
    return out


# Words that already carry a preposition or a verb cannot be dropped into a frame that supplies its
# own, or the result is "за на день рождения" and "получил отменили заказ" — text no speaker would
# produce, which is worse than no example at all.
LEADING_PARTICLES = {
    "на", "за", "в", "во", "с", "со", "по", "из", "от", "для", "до", "у", "к", "о", "об",
    "uchun", "ga", "da", "dan", "bilan",
    "on", "at", "for", "to", "of", "the", "a", "an", "in", "with",
}

# Past-tense endings in Russian and Uzbek. These are actions, and a frame wants a thing.
VERB_ENDINGS = (
    "ил", "ила", "или", "ыл", "ыла", "ели", "ала", "ять", "ать", "ить",
    "dim", "ldim", "tim", "yapman", "yapti", "moqda",
)


def is_frame_safe(keyword: str) -> bool:
    words = keyword.lower().split()
    if not words or len(words) > 2:
        return False
    if words[0] in LEADING_PARTICLES:
        return False
    # Checked only on Cyrillic/Uzbek forms: English "clothing" and "building" are perfectly good nouns.
    return not any(
        w.endswith(VERB_ENDINGS) and not w.isascii() or w.endswith(("dim", "ldim", "yapman"))
        for w in words
    )


def index_by_category(lexicon: dict) -> dict[str, list[str]]:
    # Anything the lexicon also lists as a spending or earning marker is a verb, whatever category it
    # was filed under. Dropping those catches the cases the ending heuristic misses ("выиграл") without
    # risking real nouns that merely end like verbs ("канал", "материал").
    verbs = {
        e["surface"].lower()
        for key in ("expense_markers", "income_markers")
        for e in lexicon.get(key, [])
        if e.get("surface")
    }

    out: dict[str, list[str]] = {}
    # Income categories live in their own section: the same surface can mean different things on the
    # two sides of the ledger, so they are listed separately rather than merged by the author.
    for group in lexicon.get("category_keywords", []) + lexicon.get("income_category_keywords", []):
        keywords = [
            k for k in group.get("keywords", [])
            if k and "<" not in k and is_frame_safe(k) and k.lower() not in verbs
        ]
        if keywords:
            out.setdefault(group["category"], []).extend(keywords)
    return out


def magnitudes(lexicon: dict, multiplier: int) -> list[str]:
    return [
        e["surface"] for e in lexicon.get("magnitude_words", [])
        if e.get("multiplier") == multiplier and "<" not in e["surface"]
    ]


def dated(lexicon: dict) -> list[tuple[str, str]]:
    """Date surfaces with a concrete meaning, excluding templates and negative entries."""
    out = []
    for entry in lexicon.get("date_expressions", []):
        meaning = entry.get("meaning")
        surface = entry.get("surface", "")
        if not meaning or "<" in surface:
            continue
        if meaning.upper() in {"FUTURE", "RECURRING", "UNSUPPORTED", "AMBIGUOUS", "VAGUE"}:
            continue
        if meaning.lower() in {
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
        }:
            meaning = f"last_{meaning.lower()}"
        out.append((surface, meaning))
    return out


def markers(lexicon: dict, key: str) -> list[str]:
    return [e["surface"] for e in lexicon.get(key, []) if "<" not in e.get("surface", "")]


def merchants(lexicon: dict) -> list[tuple[str, str, str]]:
    out = []
    for entry in lexicon.get("merchants", []):
        # A null canonical marks a payment rail, not a shop.
        if entry.get("canonical") and entry.get("category"):
            out.append((entry["surface"], entry["canonical"], entry["category"]))
    return out


# Sentence frames per language. `{a}` amount, `{c}` category word, `{d}` date, `{v}` verb,
# `{m}` merchant. Uzbek frames carry the case suffixes the language actually uses.
FRAMES = {
    "uz": [
        "{c}ga {a} {v}", "{c}ga {a}", "{a} {c}ga", "{d} {c}ga {a}", "{c}da {a} {v}",
        "{a} {c} oldim", "{c} uchun {a}", "{d} {c} uchun {a}", "{m}dan {c} {a}",
        "{m}da {a} {v}", "{c}ga {a} ketdi", "{d} {m}dan {a}",
    ],
    "ru": [
        "{v} {a} на {c}", "{c} {a}", "{a} на {c}", "{d} {v} {a} на {c}", "за {c} {a}",
        "{v} за {c} {a}", "{m} {a}", "{d} {c} {a}", "в {m} {a}", "{c} {a} {d}",
    ],
    "en": [
        "spent {a} on {c}", "{c} {a}", "add expense {a} {c}", "paid {a} for {c}",
        "{d} spent {a} on {c}", "{a} at {m}", "log {a} {c}", "bought {c} {a}",
        "{v} {a} on {c} {d}",
    ],
}

INCOME_FRAMES = {
    "uz": ["{c} {a} oldim", "{a} {c} tushdi", "{d} {c} {a}", "{c}dan {a} keldi"],
    "ru": ["{v} {a}", "{c} {a} пришла", "{d} {v} {a}", "получил {c} {a}"],
    "en": ["got {a} {c}", "received {a}", "{c} {a}", "{d} got {a} {c}"],
}


def render_amount(rng: random.Random, thousands: int, lexicon: dict, lang: str) -> tuple[str, float, str | None]:
    """Render an amount, returning (text, true value in major units, currency or None)."""
    style = rng.random()

    # Foreign currency, stated explicitly. Kept a minority, as it is in real usage.
    if style < 0.12:
        foreign = [
            e for e in lexicon.get("currency_words", [])
            if e.get("iso") in {"USD", "RUB", "EUR"}
            and "<" not in e["surface"]
            # Sub-unit words name a hundredth, so "15.99 cents" is not 15.99 dollars. Excluded rather
            # than special-cased: nobody logs an expense in cents anyway.
            and e["surface"].lower() not in SUBUNIT_WORDS
        ]
        if foreign:
            word = rng.choice(foreign)
            value = rng.choice([5, 10, 12, 15, 20, 25, 50, 100, 200, 500])
            if rng.random() < 0.25:
                cents = rng.choice([25, 50, 75, 99])
                return f"{value}.{cents} {word['surface']}", value + cents / 100, word["iso"]
            # The currency word goes before the number about as often as after it — "usd 45",
            # "$45", "45 usd" are all ordinary. Training only the trailing form taught the model to
            # miss the currency entirely when it led.
            surface = word["surface"]
            if surface in {"$", "€", "£"} or rng.random() < 0.35:
                joiner = "" if surface in {"$", "€", "£"} else " "
                return f"{surface}{joiner}{value}", float(value), word["iso"]
            return f"{value} {surface}", float(value), word["iso"]

    thousand_words = magnitudes(lexicon, 1000)
    million_words = magnitudes(lexicon, 1000000)

    # Millions, for rent, tuition and salaries.
    if thousands >= 1000 and million_words and rng.random() < 0.6:
        millions = round(thousands / 1000, 1)
        text = f"{millions:g} {rng.choice(million_words)}"
        return text, millions * 1_000_000, None

    # Digits plus a magnitude word — the most common form by far.
    if thousand_words and rng.random() < 0.62:
        return f"{thousands} {rng.choice(thousand_words)}", thousands * 1000.0, None

    # Bare thousands written out in full: "45000" or "45 000".
    if rng.random() < 0.5:
        value = thousands * 1000
        text = f"{value:,}".replace(",", " ") if rng.random() < 0.5 else str(value)
        return text, float(value), None

    # The implied magnitude: "obedga 50" meaning fifty thousand. Uzbek and Russian only.
    if lang in {"uz", "ru"} and thousands < 1000:
        return str(thousands), thousands * 1000.0, None

    value = thousands * 1000
    return str(value), float(value), None


def generate(count: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    lexicons = load_lexicons()
    langs = [lang for lang in ("uz", "ru", "en") if lang in lexicons]
    if not langs:
        raise SystemExit("no per-language lexicons found")

    by_lang_categories = {lang: index_by_category(lexicons[lang]) for lang in langs}
    by_lang_dates = {lang: dated(lexicons[lang]) for lang in langs}
    by_lang_merchants = {lang: merchants(lexicons[lang]) for lang in langs}
    by_lang_expense_verbs = {lang: markers(lexicons[lang], "expense_markers") for lang in langs}
    by_lang_income_verbs = {lang: markers(lexicons[lang], "income_markers") for lang in langs}

    rows: list[dict] = []
    seen: set[str] = set()
    attempts = 0

    # Uzbek is weighted highest: it is the primary language, the hardest for a pretrained model, and
    # the one with the least support to borrow from.
    lang_weights = {"uz": 0.45, "ru": 0.33, "en": 0.22}
    weights = [lang_weights.get(lang, 0.1) for lang in langs]

    while len(rows) < count and attempts < count * 40:
        attempts += 1
        lang = rng.choices(langs, weights=weights)[0]
        lexicon = lexicons[lang]

        is_income = rng.random() < 0.14
        pool = INCOME_CATEGORIES if is_income else EXPENSE_CATEGORIES
        available = [c for c in pool if by_lang_categories[lang].get(c)]
        if not available:
            continue
        category = rng.choice(available)

        low, high = PRICE_BANDS_THOUSANDS[category]
        thousands = rng.randint(low, high)

        amount_text, amount_value, currency = render_amount(rng, thousands, lexicon, lang)
        category_word = rng.choice(by_lang_categories[lang][category])

        frames = (INCOME_FRAMES if is_income else FRAMES)[lang]
        frame = rng.choice(frames)

        merchant_name = None
        merchant_text = ""
        if "{m}" in frame:
            candidates = [m for m in by_lang_merchants[lang] if m[2] == category]
            if not candidates:
                continue
            surface, canonical, _ = rng.choice(candidates)
            merchant_text, merchant_name = surface, canonical

        date_value = None
        date_text = ""
        if "{d}" in frame:
            if not by_lang_dates[lang]:
                continue
            date_text, date_value = rng.choice(by_lang_dates[lang])

        verbs = by_lang_income_verbs[lang] if is_income else by_lang_expense_verbs[lang]
        verb_text = rng.choice(verbs) if ("{v}" in frame and verbs) else ""
        if "{v}" in frame and not verb_text:
            continue

        text = frame.format(
            a=amount_text, c=category_word, d=date_text, v=verb_text, m=merchant_text
        )
        text = " ".join(text.split()).strip().lower()
        if not text or text in seen:
            continue
        seen.add(text)

        # A little realistic noise: people do not punctuate or capitalise when muttering at a phone,
        # and dictation drops the apostrophes Uzbek Latin depends on.
        if lang == "uz" and rng.random() < 0.18:
            text = text.replace("'", "")

        rows.append({
            "text": text,
            "lang": lang,
            "source": "synthetic",
            "expected": {
                "kind": "income" if is_income else "expense",
                "amount": round(amount_value, 2),
                "currency": currency,
                "category": category,
                "merchant": merchant_name,
                "note": None,
                "date": date_value,
                "confidence": 0.95,
            },
        })

    return rows


# Utterances that must NOT become transactions. Without these the model learns that every input is a
# transaction and never refuses — measured at 0/14 on the first fine-tune, which would mean every
# question a user asks silently corrupts their ledger.
REJECT_FRAMES = {
    "uz": [
        "{q} sarfladim", "{q} pul {q2}", "bu oy {q} ketdi", "{q}",
        "{i} {a} to'lashim kerak", "{i} {a} olaman", "{c}ga {a} {i}",
        "{n} sotib olmadim", "{c}ga pul sarflamadim", "hech narsa olmadim",
        "{t} {a}", "{c} {a} {n}",
    ],
    "ru": [
        "{q} я потратил на {c}", "{q} осталось", "{q} денег у меня", "{q}",
        "{i} {a} на {c}", "{i} купить {c}", "{n} покупал {c}",
        "{n} потратил ни копейки", "{c} стоит {a}?", "{t} {a}",
    ],
    "en": [
        "{q} did i spend on {c}", "{q} is my balance", "{q} last week expenses", "{q}",
        "{i} spend {a} on {c}", "{i} buy {c}", "{n} buy the {c}",
        "i earn {a} a month", "how much is {c}", "{t} {a}",
    ],
}

# App commands and standing statements, which are the same in every language for our purposes.
REJECT_LITERALS = {
    "uz": ["oxirgi xarajatni o'chir", "hisobimda qancha bor", "byudjetni ko'rsat",
           "korzinkada ishlayman", "narxlar qimmat bo'lib ketdi"],
    "ru": ["удали последнюю трату", "покажи расходы за неделю", "какой у меня баланс",
           "я работаю в корзинке", "цены выросли"],
    "en": ["delete the last expense", "show me last week expenses", "what is my balance",
           "i work at korzinka", "prices went up"],
}


def marker_surfaces(lexicon: dict, key: str) -> list[str]:
    """Whole-word markers only. Suffix patterns like '-madim / -medim' cannot stand alone."""
    if key in {"hedge_words", "transfer_markers"}:
        entries = (lexicon.get(key) or {}).get("entries", [])
    else:
        entries = lexicon.get(key, [])
    out = []
    for entry in entries:
        surface = (entry.get("surface") or "").strip()
        if not surface or surface.startswith("-") or "<" in surface or "/" in surface:
            continue
        out.append(surface)
    return out


def generate_rejects(count: int, rng, lexicons: dict, by_lang_categories: dict) -> list[dict]:
    rows, seen = [], set()
    langs = [l for l in ("uz", "ru", "en") if l in lexicons]
    attempts = 0

    while len(rows) < count and attempts < count * 60:
        attempts += 1
        lang = rng.choice(langs)
        lexicon = lexicons[lang]

        if rng.random() < 0.25:
            text = rng.choice(REJECT_LITERALS[lang])
        else:
            queries = marker_surfaces(lexicon, "query_markers")
            intents = marker_surfaces(lexicon, "intent_markers")
            negations = marker_surfaces(lexicon, "negation_markers")
            transfers = marker_surfaces(lexicon, "transfer_markers")
            if not (queries and intents and negations):
                continue

            frame = rng.choice(REJECT_FRAMES[lang])
            categories = by_lang_categories[lang]
            available = [c for c in EXPENSE_CATEGORIES if categories.get(c)]
            if not available:
                continue
            category_word = rng.choice(categories[rng.choice(available)])

            thousands = rng.randint(10, 900)
            amount_text, _, _ = render_amount(rng, thousands, lexicon, lang)

            text = frame.format(
                q=rng.choice(queries), q2=rng.choice(queries),
                i=rng.choice(intents), n=rng.choice(negations),
                t=rng.choice(transfers) if transfers else rng.choice(negations),
                a=amount_text, c=category_word,
            )

        text = " ".join(text.split()).strip().lower()
        if not text or text in seen:
            continue
        seen.add(text)

        rows.append({
            "text": text,
            "lang": lang,
            "source": "synthetic-reject",
            "expected": {
                # The corpus convention: every slot blanked, category pinned to "other", confidence 0.
                "kind": "expense",
                "amount": None, "currency": None, "category": "other",
                "merchant": None, "note": None, "date": None,
                "confidence": 0.0,
            },
        })
    return rows


def load_gold() -> list[dict]:
    rows = []
    for path in sorted(CORPUS_DIR.glob("*.jsonl")):
        if path.name == "all.jsonl":
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                row = json.loads(line)
                row["source"] = "gold"
                rows.append(row)
    return rows


def as_chat(row: dict) -> dict:
    """mlx-lm's chat format. The completion is compact JSON — every space costs tokens on a phone."""
    target = json.dumps(row["expected"], ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return {
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": row["text"]},
            {"role": "assistant", "content": target},
        ]
    }


def write_jsonl(path: pathlib.Path, rows: list[dict]) -> None:
    path.write_text(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=6000, help="synthetic examples to generate")
    parser.add_argument("--seed", type=int, default=20260802)
    args = parser.parse_args()

    synthetic = generate(args.count, args.seed)

    # ~12% rejects. The gold corpus is 5.5% rejects, but refusing needs a stronger signal than
    # accepting does: the cost of a missed refusal is a fabricated ledger entry the user never notices.
    rng_rejects = random.Random(args.seed + 1)
    lexicons = load_lexicons()
    by_lang_categories = {l: index_by_category(lexicons[l]) for l in lexicons}
    rejects = generate_rejects(
        max(400, int(args.count * 0.12)), rng_rejects, lexicons, by_lang_categories
    )
    synthetic += rejects

    gold = load_gold()

    rng = random.Random(args.seed)
    rng.shuffle(synthetic)

    # The gold corpus is the test set and is never trained on. Validation comes out of the synthetic
    # pool so that it matches the training distribution, which is what makes the loss curve readable.
    holdout = max(200, len(synthetic) // 20)
    valid_rows = synthetic[:holdout]
    train_rows = synthetic[holdout:]
    test_rows = gold

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    write_jsonl(OUT_DIR / "train.jsonl", [as_chat(r) for r in train_rows])
    write_jsonl(OUT_DIR / "valid.jsonl", [as_chat(r) for r in valid_rows])
    write_jsonl(OUT_DIR / "test.jsonl", [as_chat(r) for r in test_rows])
    # Keep the labelled originals alongside, for error analysis after evaluation.
    write_jsonl(OUT_DIR / "train.labelled.jsonl", train_rows)
    write_jsonl(OUT_DIR / "test.labelled.jsonl", test_rows)

    langs = Counter(r["lang"] for r in train_rows)
    kinds = Counter(r["expected"]["kind"] for r in train_rows)
    cats = Counter(r["expected"]["category"] for r in train_rows)
    currencies = Counter(r["expected"]["currency"] for r in train_rows)

    print(f"wrote {OUT_DIR.relative_to(ROOT)}/")
    print(f"  train {len(train_rows):>5}  (synthetic)")
    print(f"  valid {len(valid_rows):>5}  (synthetic)")
    print(f"  test  {len(test_rows):>5}  (gold, never trained on)")
    print(f"  rejects in train: {sum(1 for r in train_rows if r['source'] == 'synthetic-reject')}")
    print(f"  language:   {dict(langs)}")
    print(f"  kind:       {dict(kinds)}")
    print(f"  currency:   {dict(currencies)}")
    print(f"  categories: {len(cats)} distinct, "
          f"least common {min(cats.values())}, most common {max(cats.values())}")

    if len(train_rows) < args.count * 0.5:
        print("\nwarning: generator produced far fewer rows than requested — check frame coverage",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
