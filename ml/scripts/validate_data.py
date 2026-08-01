#!/usr/bin/env python3
"""Validate the gold lexicons and corpora.

These files are consumed by two independent things: the Swift parser at runtime and the LoRA
fine-tuning pipeline. A malformed line or an unknown category would fail loudly in one and silently
poison the other, so both are checked here, in CI, on every push.
"""

from __future__ import annotations

import json
import pathlib
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[2]
LEXICON_DIR = ROOT / "ml" / "data" / "lexicon"
CORPUS_DIR = ROOT / "ml" / "data" / "corpus"

# Must stay identical to TransactionCategory in Packages/PulseKit/Sources/PulseCore.
EXPENSE_CATEGORIES = {
    "groceries", "dining", "cafe_coffee", "transport", "fuel", "rent", "utilities", "health",
    "education", "clothing", "entertainment", "gifts", "travel", "communication", "subscriptions",
    "family", "household", "beauty", "pets", "charity", "fees", "other",
}
INCOME_CATEGORIES = {
    "salary", "freelance", "business", "gift_received", "refund", "investment", "other_income",
}
CATEGORIES = EXPENSE_CATEGORIES | INCOME_CATEGORIES

CURRENCIES = {
    "UZS", "USD", "EUR", "RUB", "KZT", "KGS", "TJS", "TRY", "GBP", "AED", "CNY", "JPY", "KRW",
}

EXPECTED_KEYS = {
    "kind", "amount", "currency", "category", "merchant", "note", "date", "confidence",
}

WEEKDAYS = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}

errors: list[str] = []
warnings: list[str] = []


# Sentinels the Uzbek lexicon uses where the others write null. Both say "this looks like a date but
# must not become one"; FUTURE and RECURRING additionally mean the event has not happened.
DATE_SENTINELS = {"FUTURE", "RECURRING", "UNSUPPORTED", "AMBIGUOUS", "VAGUE"}


def valid_lexicon_date(value: str) -> bool:
    """Dates as written in a lexicon, which is more permissive than the model's wire format."""
    if value.upper() in DATE_SENTINELS:
        return True
    # "<N> kun oldin" is a template the parser pairs with a preceding number.
    if value.startswith("<") or "<N>" in value:
        return True
    # A bare weekday means the most recent one — you log what you already spent.
    if value.lower() in WEEKDAYS:
        return True
    return valid_date(value)


def valid_date(value: str) -> bool:
    """The strict wire format the model must emit."""
    if value in {"today", "yesterday", "day_before_yesterday"}:
        return True
    for prefix in ("last_", "this_"):
        if value.startswith(prefix) and value[len(prefix):] in WEEKDAYS:
            return True
    if value.endswith("_days_ago"):
        head = value[: -len("_days_ago")]
        return head.isdigit()
    parts = value.split("-")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        _, month, day = (int(p) for p in parts)
        return 1 <= month <= 12 and 1 <= day <= 31
    return False


def check_lexicons() -> None:
    files = sorted(LEXICON_DIR.glob("*.json"))
    if not files:
        errors.append(f"no lexicon files found in {LEXICON_DIR}")
        return

    for path in files:
        if path.name == "merged.json":
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"{path.name}: invalid JSON — {exc}")
            continue

        where = path.name
        if not isinstance(data.get("language"), str):
            errors.append(f"{where}: missing 'language'")

        for entry in data.get("magnitude_words", []):
            if not isinstance(entry.get("surface"), str):
                errors.append(f"{where}: magnitude_words entry without a surface")
            if not isinstance(entry.get("multiplier"), (int, float)):
                errors.append(f"{where}: magnitude '{entry.get('surface')}' has a non-numeric multiplier")

        for entry in data.get("number_words", []):
            if not isinstance(entry.get("value"), (int, float)):
                errors.append(f"{where}: number '{entry.get('surface')}' has a non-numeric value")

        for entry in data.get("currency_words", []):
            iso = entry.get("iso")
            if iso is not None and iso not in CURRENCIES:
                warnings.append(f"{where}: currency word '{entry.get('surface')}' maps to unsupported {iso}")

        for group in data.get("category_keywords", []):
            category = group.get("category")
            if category not in CATEGORIES:
                errors.append(f"{where}: unknown category '{category}'")
            if not isinstance(group.get("keywords"), list):
                errors.append(f"{where}: category '{category}' has no keyword list")

        for entry in data.get("date_expressions", []):
            meaning = entry.get("meaning")
            # null is meaningful: it marks a phrase that must NOT become a date. So are the sentinels.
            if meaning is not None and not valid_lexicon_date(meaning):
                errors.append(f"{where}: date expression '{entry.get('surface')}' has invalid meaning '{meaning}'")

        for entry in data.get("merchants", []):
            category = entry.get("category")
            if category is not None and category not in CATEGORIES:
                errors.append(f"{where}: merchant '{entry.get('surface')}' has unknown category '{category}'")

    print(f"checked {len(files)} lexicon file(s)")


def check_corpora() -> None:
    files = sorted(p for p in CORPUS_DIR.glob("*.jsonl") if p.name != "all.jsonl")
    if not files:
        errors.append(f"no corpus files found in {CORPUS_DIR}")
        return

    total = 0
    seen_text: dict[str, str] = {}
    inconsistent: list[str] = []
    stats = {
        "kind": Counter(), "category": Counter(), "currency": Counter(),
        "lang": Counter(), "script": Counter(), "difficulty": Counter(),
    }

    for path in files:
        for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            raw = raw.strip()
            if not raw:
                continue
            total += 1
            where = f"{path.name}:{line_number}"

            try:
                row = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"{where}: invalid JSON — {exc}")
                continue

            text = row.get("text")
            if not isinstance(text, str) or not text.strip():
                errors.append(f"{where}: missing text")
                continue

            expected = row.get("expected")
            if not isinstance(expected, dict):
                errors.append(f"{where}: missing 'expected' object")
                continue

            missing = EXPECTED_KEYS - expected.keys()
            if missing:
                errors.append(f"{where}: expected is missing {sorted(missing)}")

            kind = expected.get("kind")
            if kind not in {"expense", "income"}:
                errors.append(f"{where}: bad kind '{kind}'")

            # A reject row (confidence exactly 0.0) blanks every slot and pins category to "other"
            # whichever way the sentence leaned, so the kind/category pairing rule does not apply.
            is_reject = expected.get("confidence") == 0.0

            category = expected.get("category")
            if category is not None:
                if category not in CATEGORIES:
                    errors.append(f"{where}: unknown category '{category}'")
                elif is_reject:
                    if category != "other":
                        errors.append(f"{where}: reject row must use category 'other', got '{category}'")
                elif kind == "income" and category not in INCOME_CATEGORIES:
                    errors.append(f"{where}: income labelled with expense category '{category}'")
                elif kind == "expense" and category not in EXPENSE_CATEGORIES:
                    errors.append(f"{where}: expense labelled with income category '{category}'")

            currency = expected.get("currency")
            if currency is not None and currency not in CURRENCIES:
                errors.append(f"{where}: unsupported currency '{currency}'")

            if is_reject and expected.get("amount") is not None:
                errors.append(f"{where}: reject row must blank the amount")

            amount = expected.get("amount")
            if amount is not None:
                if not isinstance(amount, (int, float)):
                    errors.append(f"{where}: non-numeric amount {amount!r}")
                elif amount < 0:
                    errors.append(f"{where}: negative amount — direction belongs in 'kind'")

            date = expected.get("date")
            if date is not None and not valid_date(date):
                errors.append(f"{where}: invalid date '{date}'")

            confidence = expected.get("confidence")
            if not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
                errors.append(f"{where}: confidence out of range: {confidence!r}")

            # The same utterance labelled two different ways teaches the model to contradict itself.
            key = text.strip().lower()
            fingerprint = json.dumps(expected, sort_keys=True, ensure_ascii=False)
            if key in seen_text and seen_text[key] != fingerprint:
                inconsistent.append(f"{where}: '{text}' labelled differently than an earlier occurrence")
            seen_text.setdefault(key, fingerprint)

            stats["kind"][kind] += 1
            stats["category"][category] += 1
            stats["currency"][currency] += 1
            stats["lang"][row.get("lang")] += 1
            stats["script"][row.get("script")] += 1
            stats["difficulty"][row.get("difficulty")] += 1

    errors.extend(inconsistent)

    print(f"checked {total} corpus utterances across {len(files)} file(s)")
    print(f"  kind:       {dict(stats['kind'])}")
    print(f"  language:   {dict(stats['lang'])}")
    print(f"  script:     {dict(stats['script'])}")
    print(f"  difficulty: {dict(stats['difficulty'])}")
    print(f"  categories: {len(stats['category'])} distinct")


def main() -> int:
    check_lexicons()
    check_corpora()

    for warning in warnings:
        print(f"warning: {warning}")

    if errors:
        print(f"\n{len(errors)} error(s):", file=sys.stderr)
        for error in errors[:60]:
            print(f"  {error}", file=sys.stderr)
        if len(errors) > 60:
            print(f"  ... and {len(errors) - 60} more", file=sys.stderr)
        return 1

    print("\nall gold data valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
