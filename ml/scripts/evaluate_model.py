#!/usr/bin/env python3
"""Evaluate a fine-tuned model on the held-out gold corpus.

Reports the same per-field metrics as the Swift benchmark
(`swift test --filter CorpusEvaluation`) so the model and the deterministic parser can be compared
directly, on identical data. That comparison is the whole point: the model only earns its place on the
phone where it beats a parser that costs nothing to run.

The test set is the hand-authored gold corpus, which the generator never trains on.

Usage:
    ml/.venv/bin/python ml/scripts/evaluate_model.py \
        --model mlx-community/Qwen3-0.6B-bf16 --adapter ml/out/qwen3-0.6b-lora [--limit 300]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import time
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[2]
TEST_FILE = ROOT / "ml" / "data" / "generated" / "test.labelled.jsonl"

SYSTEM_PROMPT = (
    "Extract the transaction from the user's message as JSON with keys: "
    "kind, amount, currency, category, merchant, note, date, confidence. "
    "The user writes in Uzbek, Russian, or English. "
    "Use null for anything not stated. Do not guess."
)


def extract_json(text: str) -> dict | None:
    """Pull the first JSON object out of a completion.

    Small instruct models pad their output — a stray sentence, a code fence, or (for Qwen3) a thinking
    block. On a phone we would rather salvage a good object from untidy output than discard the parse,
    so this scans for the first balanced brace pair instead of demanding the whole string be JSON.
    """
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start : index + 1])
                except json.JSONDecodeError:
                    return None
    return None


def close_enough(got, want) -> bool:
    if got is None or want is None:
        return got is None and want is None
    if isinstance(want, (int, float)) and isinstance(got, (int, float)):
        return abs(float(got) - float(want)) < 0.01
    return str(got).strip().lower() == str(want).strip().lower()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="mlx-community/Qwen3-0.6B-bf16")
    parser.add_argument("--adapter", default=None, help="LoRA adapter directory")
    parser.add_argument("--limit", type=int, default=0, help="evaluate only the first N rows")
    parser.add_argument("--max-tokens", type=int, default=160)
    parser.add_argument("--show", type=int, default=15, help="how many failures to print")
    args = parser.parse_args()

    from mlx_lm import generate, load
    from mlx_lm.sample_utils import make_sampler

    print(f"loading {args.model}" + (f" + adapter {args.adapter}" if args.adapter else ""))
    model, tokenizer = load(args.model, adapter_path=args.adapter)
    sampler = make_sampler(temp=0.0)  # greedy: extraction has one right answer

    rows = [json.loads(line) for line in TEST_FILE.read_text(encoding="utf-8").splitlines() if line.strip()]
    if args.limit:
        rows = rows[: args.limit]

    fields = ["kind", "amount", "currency", "category", "date"]
    correct = Counter()
    attempted = Counter()
    exact = 0
    malformed = 0
    rejects_right = 0
    rejects_total = 0
    failures: list[str] = []
    latencies: list[float] = []

    for row in rows:
        want = row["expected"]
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": row["text"]},
        ]
        try:
            prompt = tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, enable_thinking=False
            )
        except TypeError:
            # Older templates do not take enable_thinking.
            prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)

        started = time.perf_counter()
        out = generate(
            model, tokenizer, prompt=prompt, max_tokens=args.max_tokens,
            sampler=sampler, verbose=False,
        )
        latencies.append(time.perf_counter() - started)

        got = extract_json(out)
        if got is None:
            malformed += 1
            if len(failures) < args.show:
                failures.append(f'  MALFORMED  "{row["text"]}" -> {out[:90]!r}')
            continue

        # Non-transactions are marked by confidence 0.0 in the corpus; check the model also refuses.
        if want.get("confidence") == 0.0:
            rejects_total += 1
            if float(got.get("confidence") or 1.0) < 0.25:
                rejects_right += 1
            elif len(failures) < args.show:
                failures.append(
                    f'  NOT-A-TRANSACTION accepted  "{row["text"]}" conf={got.get("confidence")}'
                )
            continue

        row_ok = True
        for field in fields:
            if field == "amount" and want.get(field) is None and got.get(field) is None:
                continue
            attempted[field] += 1
            if close_enough(got.get(field), want.get(field)):
                correct[field] += 1
            else:
                row_ok = False
        if row_ok:
            exact += 1
        elif len(failures) < args.show:
            summary = {f: (want.get(f), got.get(f)) for f in fields if not close_enough(got.get(f), want.get(f))}
            failures.append(f'  "{row["text"]}" -> {summary}')

    scored = len(rows) - rejects_total
    print(f"\n┌─ Fine-tuned model vs gold corpus ({len(rows)} utterances)")
    for field in fields:
        n = attempted[field]
        rate = correct[field] / n if n else 0
        print(f"│  {field:<10} {correct[field]:>4}/{n:<4} ({rate*100:>3.0f}%)")
    print(f"│  {'all fields':<10} {exact:>4}/{scored:<4} ({exact/max(scored,1)*100:>3.0f}%)")
    if rejects_total:
        print(f"│  rejects non-transactions  {rejects_right}/{rejects_total} "
              f"({rejects_right/rejects_total*100:.0f}%)")
    print(f"│  malformed JSON  {malformed}/{len(rows)}")
    if latencies:
        latencies.sort()
        print(f"│  latency  median {latencies[len(latencies)//2]*1000:.0f} ms  "
              f"p90 {latencies[int(len(latencies)*0.9)]*1000:.0f} ms  (on this Mac, not the phone)")
    print("└─ sample failures")
    print("\n".join(failures) if failures else "  (none)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
