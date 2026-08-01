#!/usr/bin/env python3
"""
Held-out evaluation for the Pulse expense parser.

  python eval_expense.py --model fused/pulse-0.6b-4bit --test data/test.jsonl

Reports:
  json_valid            % of outputs that parse as JSON and match the schema
  intent_acc            % correct `intent`
  slot_exact            % where EVERY item slot (amount,currency,category,when) matches
  txn_acc               PRIMARY METRIC: intent + amount + currency + when all correct
                        (category excluded -- it is subjective)
  amount_acc / currency_acc / category_acc / when_acc   per-field
  unclear_p / unclear_r precision & recall of the "ask for clarification" behaviour
  p50/p95 latency, tokens/sec
"""
import argparse, json, time, sys
from collections import Counter

from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

INTENTS = {"expense", "income", "query", "delete", "chitchat", "unclear"}
CURRENCIES = {"UZS", "RUB", "USD", "EUR", "KZT", None}


def schema_ok(o):
    if not isinstance(o, dict):
        return False
    if o.get("intent") not in INTENTS:
        return False
    if o.get("confidence") not in {"high", "medium", "low"}:
        return False
    items = o.get("items")
    if not isinstance(items, list):
        return False
    for it in items:
        if not isinstance(it, dict):
            return False
        if not isinstance(it.get("amount"), (int, float)):
            return False
        if it.get("currency") not in CURRENCIES:
            return False
        if not isinstance(it.get("when"), str):
            return False
    return True


def norm_items(o):
    """Order-insensitive canonical form of the item list."""
    return sorted(
        (float(i.get("amount", 0)), i.get("currency"), i.get("category"),
         i.get("when"))
        for i in o.get("items", []) if isinstance(i, dict)
    )


def extract_json(text):
    """Tolerant extraction: first balanced {...} block."""
    s = text.find("{")
    if s < 0:
        return None
    depth, instr, esc = 0, False, False
    for i in range(s, len(text)):
        c = text[i]
        if instr:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                instr = False
            continue
        if c == '"':
            instr = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[s:i + 1])
                except Exception:
                    return None
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter-path", default=None)
    ap.add_argument("--test", default="data/test.jsonl")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-tokens", type=int, default=192)
    ap.add_argument("--dump", default=None, help="write per-example errors here")
    a = ap.parse_args()

    model, tok = load(a.model, adapter_path=a.adapter_path)
    sampler = make_sampler(temp=0.0)          # greedy: extraction is not creative

    rows = [json.loads(l) for l in open(a.test, encoding="utf-8")]
    if a.limit:
        rows = rows[:a.limit]

    c = Counter()
    lat, errs = [], []
    for r in rows:
        msgs = r["messages"]
        gold = json.loads(msgs[-1]["content"])
        prompt = tok.apply_chat_template(msgs[:-1], add_generation_prompt=True,
                                         tokenize=False,
                                         enable_thinking=False)
        t0 = time.perf_counter()
        out = generate(model, tok, prompt=prompt, max_tokens=a.max_tokens,
                       sampler=sampler, verbose=False)
        lat.append(time.perf_counter() - t0)

        pred = extract_json(out)
        c["n"] += 1
        if pred is None or not schema_ok(pred):
            errs.append({"in": msgs[1]["content"], "gold": gold, "raw": out})
            continue
        c["json_valid"] += 1

        gi, pi = gold.get("intent"), pred.get("intent")
        c["intent_ok"] += gi == pi

        g_items, p_items = norm_items(gold), norm_items(pred)
        c["slot_exact"] += g_items == p_items
        c["count_ok"] += len(g_items) == len(p_items)

        # field-level over aligned items (only when counts match)
        if len(g_items) == len(p_items):
            for g, p in zip(g_items, p_items):
                c["fields"] += 1
                c["amount_ok"] += g[0] == p[0]
                c["currency_ok"] += g[1] == p[1]
                c["category_ok"] += g[2] == p[2]
                c["when_ok"] += g[3] == p[3]

        txn = (gi == pi and len(g_items) == len(p_items) and
               all(g[0] == p[0] and g[1] == p[1] and g[3] == p[3]
                   for g, p in zip(g_items, p_items)))
        c["txn_ok"] += txn
        if not txn:
            errs.append({"in": msgs[1]["content"], "gold": gold, "pred": pred})

        c["g_unclear"] += gi == "unclear"
        c["p_unclear"] += pi == "unclear"
        c["tp_unclear"] += (gi == "unclear" and pi == "unclear")

    n = c["n"] or 1
    f = c["fields"] or 1
    lat.sort()
    print(json.dumps({
        "n": c["n"],
        "json_valid":   round(100 * c["json_valid"] / n, 2),
        "intent_acc":   round(100 * c["intent_ok"] / n, 2),
        "item_count_acc": round(100 * c["count_ok"] / n, 2),
        "slot_exact":   round(100 * c["slot_exact"] / n, 2),
        "txn_acc":      round(100 * c["txn_ok"] / n, 2),
        "amount_acc":   round(100 * c["amount_ok"] / f, 2),
        "currency_acc": round(100 * c["currency_ok"] / f, 2),
        "category_acc": round(100 * c["category_ok"] / f, 2),
        "when_acc":     round(100 * c["when_ok"] / f, 2),
        "unclear_p":    round(100 * c["tp_unclear"] / max(c["p_unclear"], 1), 2),
        "unclear_r":    round(100 * c["tp_unclear"] / max(c["g_unclear"], 1), 2),
        "latency_p50_s": round(lat[len(lat) // 2], 3) if lat else None,
        "latency_p95_s": round(lat[int(len(lat) * .95)], 3) if lat else None,
    }, indent=2))

    if a.dump:
        with open(a.dump, "w", encoding="utf-8") as fh:
            for e in errs:
                fh.write(json.dumps(e, ensure_ascii=False) + "\n")
        print(f"{len(errs)} errors -> {a.dump}", file=sys.stderr)


if __name__ == "__main__":
    main()
