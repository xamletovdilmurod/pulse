# Pulse

An iOS money-management app that makes spending *feel* like spending again.

## Why

Paying by card removes the physical friction of handing over cash. The brain registers less loss, feels
less stress, and spends more. Pulse exists to put that friction back — with tactile animations and
haptics that make an outgoing amount land as something you felt, not a number in a list.

Logging has to be effortless or it doesn't happen, so you can just say what you spent, in **Uzbek,
Russian, or English** — including the way people actually talk:

```
obedga 50 ketdi                  →  50 000 UZS · dining
таксига 25 тыщ                   →  25 000 UZS · transport
kecha dorixonada 75 ming         →  75 000 UZS · health, yesterday
двадцать пять тысяч на такси     →  25 000 UZS · transport
add outcome 12 dollars for coffee →  12 USD · cafe & coffee
```

Financial data never leaves the phone: everything runs on-device.

## How it works

Language understanding is layered, so the app is useful before any model exists and degrades gracefully
when the model is unsure.

1. **Normalization** — unifies the six apostrophe characters Uzbek Latin depends on, transliterates Uzbek
   Cyrillic (`сўм` → `so'm`), and recovers from dictation artifacts.
2. **Deterministic parser** — a lexicon-driven grammar covering amounts, magnitude words
   (`ming`/`минг`/`тыс`/`k`), compound numerals (`двадцать пять тысяч` → 25 000), fractional coefficients
   (`yarim million` → 500 000), currencies, relative dates, merchants, and categories. Microseconds, no
   model, fully offline.
3. **Fine-tuned on-device LLM** *(in progress)* — a small multilingual model LoRA-tuned locally with MLX,
   handling the long tail the grammar can't.

Every layer emits the same `ParsedTransaction` with a confidence score. High confidence saves directly;
middling confidence pre-fills a confirmation; low confidence is refused outright — a question like
"сколько я потратил на еду" must never become a transaction.

### Current accuracy

The deterministic layer alone, measured against 682 hand-authored gold utterances
(`swift test --filter CorpusEvaluation`):

| Field | Accuracy |
|---|---|
| Amount | 95% |
| Income vs expense | 98% |
| Date | 92% |
| Currency | 91% |
| Category | 88% |
| Rejects non-transactions | 75% |

By difficulty: easy 96%, medium 88%, hard 71%.

## Repository layout

```
Pulse/                       iOS app target (SwiftUI, iOS 26)
Packages/PulseKit/
  Sources/PulseCore          Money, Currency, Transaction, categories
  Sources/PulseParse         normalization, lexicon, amount + expense parsing
  Sources/PulseUI            design system and screens
  Sources/PulseAI            on-device inference
ml/data/lexicon/*.json       money vocabulary per language
ml/data/corpus/*.jsonl       gold utterances with expected parses
ml/scripts/validate_data.py  integrity checks, run in CI
project.yml                  XcodeGen spec — the Xcode project is generated, not committed
```

`PulseCore` and `PulseParse` deliberately have no UI or platform dependencies, so the money logic and the
parser test on macOS in milliseconds with no simulator in the loop.

## Money is never a `Double`

Amounts are integer counts of minor units with the currency attached. Mixing currencies in arithmetic is
a compile-time-adjacent error (it traps); conversion is always explicit and the FX rate is frozen onto the
transaction, so last year's lunch doesn't change price when the exchange rate moves.

The so'm gets a small special case: ISO 4217 gives UZS two minor units (tiyin), which have been worthless
for decades and which nobody writes. Pulse stores per the standard and displays whole so'm.

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Pulse.xcodeproj
```

Logic tests, no simulator needed:

```sh
cd Packages/PulseKit && swift test
```

Gold-data integrity:

```sh
python3 ml/scripts/validate_data.py
```

## Status

Working: money model, ledger, text normalization, deterministic uz/ru/en parser, app builds and signs
for device.

In progress: on-device LLM fine-tuning, the animation system, voice input.
