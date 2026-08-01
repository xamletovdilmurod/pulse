#!/usr/bin/env python3
"""
Synthetic training-data generator for Pulse expense NLU.
Emits chat-format JSONL for mlx_lm.lora:  <out>/{train,valid,test}.jsonl
"""
import json, random, os, sys

SYSTEM = (
    "You are Pulse, an expense parser. Convert the user's message into JSON "
    "matching the Pulse schema. Output JSON only."
)

ITEMS = [
    ("food", ["obed", "tushlik", "nonushta", "kechki ovqat", "somsa", "lag'mon",
              "kabob", "choy", "kofe", "shashlik", "osh", "pizza", "burger"],
             ["обед", "тушлик", "нонушта", "сомса", "лағмон", "кабоб", "чой",
              "кофе", "ош", "пицца"],
             ["обед", "завтрак", "ужин", "кофе", "шаурма", "пицца", "бургер",
              "ланч", "перекус", "чай"],
             ["lunch", "breakfast", "dinner", "coffee", "pizza", "burger",
              "sandwich", "snack", "brunch"]),
    ("groceries", ["bozor", "oziq-ovqat", "non", "sut", "go'sht", "meva",
                   "sabzavot", "makaron"],
                  ["бозор", "озиқ-овқат", "нон", "сут", "гўшт", "мева"],
                  ["продукты", "магазин", "хлеб", "молоко", "мясо", "овощи"],
                  ["groceries", "supermarket", "bread", "milk", "vegetables"]),
    ("transport", ["taksi", "avtobus", "metro", "yandex taxi", "marshrutka"],
                  ["такси", "автобус", "метро", "маршрутка"],
                  ["такси", "автобус", "метро", "маршрутка", "яндекс такси", "убер"],
                  ["taxi", "uber", "bus", "metro", "subway", "ride"]),
    ("fuel", ["benzin", "yoqilg'i", "gaz", "metan"],
             ["бензин", "ёқилғи", "газ"],
             ["бензин", "заправка", "топливо", "газ"],
             ["gas", "petrol", "fuel", "gasoline", "charging"]),
    ("shopping", ["kiyim", "krossovka", "futbolka", "telefon", "quloqchin"],
                 ["кийим", "кроссовка", "футболка", "телефон"],
                 ["одежда", "кроссовки", "футболка", "телефон", "наушники"],
                 ["clothes", "sneakers", "t-shirt", "phone", "headphones"]),
    ("health", ["dorixona", "dori", "shifokor", "tish doktori", "analiz"],
               ["дорихона", "дори", "шифокор"],
               ["аптека", "лекарства", "врач", "стоматолог", "анализы"],
               ["pharmacy", "medicine", "doctor", "dentist", "clinic"]),
    ("bills", ["internet", "svet", "gaz puli", "suv", "mobil aloqa", "kommunal"],
              ["интернет", "свет", "сув", "коммунал"],
              ["интернет", "свет", "коммуналка", "вода", "мобильная связь"],
              ["internet", "electricity", "water bill", "phone bill", "utilities"]),
    ("entertainment", ["kino", "konsert", "o'yin", "bilyard", "netflix"],
                      ["кино", "концерт", "ўйин"],
                      ["кино", "концерт", "игра", "нетфликс", "боулинг"],
                      ["movie", "concert", "game", "netflix", "spotify"]),
    ("education", ["kurs", "kitob", "repetitor", "ingliz tili kursi"],
                  ["курс", "китоб", "репетитор"],
                  ["курсы", "книга", "репетитор", "учебник"],
                  ["course", "book", "tutor", "textbook", "udemy"]),
    ("rent", ["ijara", "kvartira puli", "arenda"],
             ["ижара", "квартира пули"],
             ["аренда", "квартплата", "съём"],
             ["rent", "apartment rent"]),
    ("travel", ["samolyot bileti", "poyezd", "mehmonxona", "safar"],
               ["самолёт билети", "поезд", "меҳмонхона"],
               ["билет на самолёт", "поезд", "отель", "гостиница"],
               ["flight", "train ticket", "hotel", "airbnb"]),
    ("gifts", ["sovg'a", "tug'ilgan kun sovg'asi", "gul"],
              ["совға", "гул"],
              ["подарок", "цветы"],
              ["gift", "flowers", "present"]),
]

MERCHANTS = ["Korzinka", "Makro", "Havas", "Evos", "Chopar", "Yandex Go",
             "Uzum", "Click", "Payme", "Starbucks", "Пятёрочка", "Магнит",
             "Wildberries", "Ozon", "Amazon", "Uber", "Bolt"]

CUR = {
    "UZS": {"uz_latin": ["so'm", "som", "sum", "so‘m", ""],
            "uz_cyr": ["сўм", "сум", ""],
            "ru": ["сум", "сумов", "сўм", ""],
            "en": ["soum", "sum", "UZS", "so'm"]},
    "RUB": {"uz_latin": ["rubl", "rublya"], "uz_cyr": ["рубл"],
            "ru": ["рублей", "руб", "р", "рубля", "₽"], "en": ["rubles", "RUB"]},
    "USD": {"uz_latin": ["dollar", "usd", "$", "baks"], "uz_cyr": ["доллар", "бакс"],
            "ru": ["долларов", "баксов", "$", "usd"],
            "en": ["dollars", "bucks", "$", "USD"]},
    "EUR": {"uz_latin": ["yevro", "evro"], "uz_cyr": ["евро"],
            "ru": ["евро", "€"], "en": ["euros", "EUR", "€"]},
    "KZT": {"uz_latin": ["tenge"], "uz_cyr": ["тенге"],
            "ru": ["тенге", "тг"], "en": ["tenge", "KZT"]},
}

MAG = {
    "uz_latin": [("ming", 1_000), ("minglik", 1_000), ("k", 1_000),
                 ("million", 1_000_000), ("mln", 1_000_000)],
    "uz_cyr": [("минг", 1_000), ("млн", 1_000_000), ("миллион", 1_000_000)],
    "ru": [("тысяч", 1_000), ("тыс", 1_000), ("тыщи", 1_000), ("тыщ", 1_000),
           ("к", 1_000), ("косарь", 1_000), ("млн", 1_000_000), ("миллиона", 1_000_000)],
    "en": [("thousand", 1_000), ("k", 1_000), ("grand", 1_000),
           ("million", 1_000_000), ("m", 1_000_000)],
}

WHEN = {
    "today": {"uz_latin": ["bugun", ""], "uz_cyr": ["бугун", ""],
              "ru": ["сегодня", ""], "en": ["today", ""]},
    "yesterday": {"uz_latin": ["kecha"], "uz_cyr": ["кеча"],
                  "ru": ["вчера"], "en": ["yesterday"]},
    "day_before_yesterday": {"uz_latin": ["avvalgi kuni", "kechadan oldin"],
                             "uz_cyr": ["кечадан олдин"], "ru": ["позавчера"],
                             "en": ["day before yesterday"]},
    "last_monday": {"uz_latin": ["o'tgan dushanba"], "uz_cyr": ["ўтган душанба"],
                    "ru": ["в прошлый понедельник"], "en": ["last monday"]},
    "last_friday": {"uz_latin": ["o'tgan juma"], "uz_cyr": ["ўтган жума"],
                    "ru": ["в прошлую пятницу"], "en": ["last friday"]},
    "last_saturday": {"uz_latin": ["o'tgan shanba"], "uz_cyr": ["ўтган шанба"],
                      "ru": ["в прошлую субботу"], "en": ["last saturday"]},
    "last_week": {"uz_latin": ["o'tgan hafta"], "uz_cyr": ["ўтган ҳафта"],
                  "ru": ["на прошлой неделе"], "en": ["last week"]},
    "last_month": {"uz_latin": ["o'tgan oy"], "uz_cyr": ["ўтган ой"],
                   "ru": ["в прошлом месяце"], "en": ["last month"]},
}

INCOME_TRIGGER = {
    "uz_latin": ["oylik oldim", "maosh tushdi", "ishlab topdim", "daromad",
                 "pul tushdi", "bonus oldim"],
    "uz_cyr": ["ойлик олдим", "маош тушди", "пул тушди", "бонус олдим"],
    "ru": ["получил зарплату", "пришла зарплата", "заработал",
           "прилетел бонус", "вернули долг", "доход"],
    "en": ["got paid", "received salary", "earned", "got a bonus",
           "income", "refund came in"],
}

EXP_VERB = {
    "uz_latin": ["{amt} {cur} {sarf}", "{item}ga {amt} {cur} ketdi",
                 "{item} uchun {amt} {cur}", "{amt} {cur} {item}ga sarfladim",
                 "{item}, {amt} {cur}", "{item}ga {amt} {cur} to'ladim"],
    "uz_cyr": ["{item} учун {amt} {cur}", "{item}га {amt} {cur} кетди",
               "{amt} {cur} {item}га сарфладим", "{item}, {amt} {cur}"],
    "ru": ["потратил {amt} {cur} на {item}", "{item} {amt} {cur}",
           "на {item} ушло {amt} {cur}", "заплатил {amt} {cur} за {item}",
           "{amt} {cur} за {item}", "минус {amt} {cur}, {item}"],
    "en": ["spent {amt} {cur} on {item}", "add outcome {amt} {cur} for {item}",
           "{item} {amt} {cur}", "paid {amt} {cur} for {item}",
           "{amt} {cur} on {item}"],
}

LANGS = ["uz_latin", "uz_cyr", "ru", "en"]
ITEM_IDX = {"uz_latin": 1, "uz_cyr": 2, "ru": 3, "en": 4}


def fmt_amount(value, lang, rng):
    """Return (surface_string, normalized_value).

    NOTE: the decimal-magnitude branch ("1.2 million", "1,5 тыс", "2.5k") is
    ESSENTIAL -- without it the model reads "1.2 million" as 12_000_000.
    """
    mags = MAG[lang]
    style = rng.random()
    # --- decimal magnitude: "1.2 million soum", "1,5 тыс", "2.5k"
    if style < 0.15 and value >= 1_000:
        mult = 1_000_000 if value >= 1_000_000 else 1_000
        word, _ = rng.choice([m for m in mags if m[1] == mult])
        whole = rng.randrange(1, 9)
        frac = rng.randrange(1, 10)
        dec = rng.choice([".", ","])
        new_val = int((whole + frac / 10) * mult)
        sep = "" if word in ("k", "к") else " "
        return f"{whole}{dec}{frac}{sep}{word}", new_val
    if style < 0.50 and value >= 1000 and value % 1000 == 0:
        word, _ = rng.choice([m for m in mags if m[1] == 1_000])
        sep = "" if word in ("k", "к") else " "
        return f"{value // 1000}{sep}{word}", value
    if style < 0.60 and value >= 1_000_000 and value % 1_000_000 == 0:
        word, _ = rng.choice([m for m in mags if m[1] == 1_000_000])
        return f"{value // 1_000_000} {word}", value
    if style < 0.75 and value >= 10000:
        sep = rng.choice([" ", ",", ".", ""])
        return f"{value:,}".replace(",", sep), value
    return str(value), value


def pick_amount(cur, rng):
    if cur == "UZS":
        return rng.choice([rng.randrange(5, 200) * 1000,
                           rng.randrange(1, 15) * 100_000,
                           rng.randrange(1, 6) * 1_000_000])
    if cur == "RUB":
        return rng.choice([rng.randrange(50, 5000), rng.randrange(1, 30) * 1000])
    if cur in ("USD", "EUR"):
        return rng.choice([rng.randrange(1, 200), rng.randrange(1, 20) * 100])
    return rng.randrange(100, 50000)


def noisy(s, rng):
    r = rng.random()
    if r < 0.10:
        s = s.lower()
    elif r < 0.13:
        s = s.upper()
    if rng.random() < 0.08:
        s = s.replace("'", rng.choice(["‘", "`", "’", ""]))
    # Typo noise, but NEVER inside a digit run -- dropping a digit silently
    # changes the gold amount and creates unlearnable label noise.
    if rng.random() < 0.05 and len(s) > 4:
        cand = [i for i, ch in enumerate(s)
                if not ch.isdigit()
                and not (i > 0 and s[i - 1].isdigit())
                and not (i + 1 < len(s) and s[i + 1].isdigit())]
        if cand:
            i = rng.choice(cand)
            s = s[:i] + s[i + 1:]
    if rng.random() < 0.06:
        s = s.rstrip(".") + rng.choice(["", ".", "!", " ..."])
    return s


def make_item(rng, lang):
    row = rng.choice(ITEMS)
    cat = row[0]
    surface = rng.choice(row[ITEM_IDX[lang]] or row[4])
    cur = rng.choices(["UZS", "RUB", "USD", "EUR", "KZT"],
                      weights=[60, 18, 15, 4, 3])[0]
    val = pick_amount(cur, rng)
    amt_s, amt_n = fmt_amount(val, lang, rng)
    cur_s = rng.choice(CUR[cur][lang])
    return cat, surface, cur, cur_s, amt_s, amt_n


def build_expense(rng):
    lang = rng.choice(LANGS)
    cat, surface, cur, cur_s, amt_s, amt_n = make_item(rng, lang)
    text = rng.choice(EXP_VERB[lang]).format(
        amt=amt_s, cur=cur_s, item=surface,
        sarf=rng.choice(["sarfladim", "ketdi", "chiqdi"]))
    text = " ".join(text.split())
    when = "today"
    if rng.random() < 0.30:
        when = rng.choice([w for w in WHEN if w != "today"])
        w_s = rng.choice(WHEN[when][lang])
        text = rng.choice([f"{w_s} {text}", f"{text} {w_s}"]).strip()
    merchant = None
    if rng.random() < 0.22:
        merchant = rng.choice(MERCHANTS)
        text = f"{text} ({merchant})" if rng.random() < .4 else f"{text} {merchant}"
    obj = {"intent": "expense", "confidence": "high" if cur_s else "medium",
           "items": [{"amount": amt_n, "currency": cur, "category": cat,
                      "merchant": merchant, "note": surface, "when": when}],
           "clarification": None}
    return noisy(text, rng), obj


def build_income(rng):
    lang = rng.choice(LANGS)
    trig = rng.choice(INCOME_TRIGGER[lang])
    cur = rng.choices(["UZS", "USD", "RUB"], weights=[65, 20, 15])[0]
    val = pick_amount(cur, rng) * (10 if cur == "UZS" else 1)
    amt_s, amt_n = fmt_amount(val, lang, rng)
    cur_s = rng.choice(CUR[cur][lang])
    text = " ".join(f"{trig} {amt_s} {cur_s}".split())
    when = "today"
    if rng.random() < 0.35:
        when = rng.choice([w for w in WHEN if w != "today"])
        text = f"{rng.choice(WHEN[when][lang])} {text}".strip()
    obj = {"intent": "income", "confidence": "high" if cur_s else "medium",
           "items": [{"amount": amt_n, "currency": cur, "category": "salary",
                      "merchant": None, "note": trig, "when": when}],
           "clarification": None}
    return noisy(text, rng), obj


def build_multi(rng):
    """Multi-item. A leading date adverb MUST propagate to every item --
    without these examples the model tags item #2 as `today`."""
    lang = rng.choice(LANGS)
    n = rng.choice([2, 2, 3])
    when = "today"
    prefix = ""
    if rng.random() < 0.45:
        when = rng.choice([w for w in WHEN if w != "today"])
        prefix = rng.choice(WHEN[when][lang]) + " "
    parts, items = [], []
    for _ in range(n):
        cat, surface, cur, cur_s, amt_s, amt_n = make_item(rng, lang)
        parts.append(" ".join(f"{surface} {amt_s} {cur_s}".split()))
        items.append({"amount": amt_n, "currency": cur, "category": cat,
                      "merchant": None, "note": surface, "when": when})
    joiner = {"uz_latin": [" va ", ", "], "uz_cyr": [" ва ", ", "],
              "ru": [" и ", ", "], "en": [" and ", ", "]}[lang]
    text = (prefix + rng.choice(joiner).join(parts)).strip()
    return noisy(text, rng), {"intent": "expense", "confidence": "high",
                              "items": items, "clarification": None}


def build_codeswitch(rng):
    l1, l2 = rng.sample(LANGS, 2)
    cat, surface, cur, cur_s, amt_s, amt_n = make_item(rng, l2)
    frame = {"uz_latin": "{item}ga {amt} {cur} ketdi",
             "uz_cyr": "{item}га {amt} {cur} кетди",
             "ru": "потратил {amt} {cur} на {item}",
             "en": "spent {amt} {cur} on {item}"}[l1]
    text = " ".join(frame.format(item=surface, amt=amt_s, cur=cur_s).split())
    return noisy(text, rng), {
        "intent": "expense", "confidence": "high" if cur_s else "medium",
        "items": [{"amount": amt_n, "currency": cur, "category": cat,
                   "merchant": None, "note": surface, "when": "today"}],
        "clarification": None}


AMBIG = [
    ("15 ming", "Nimaga sarfladingiz?"),
    ("300", "Что это за сумма и на что?"),
    ("kofe", "Qancha pul sarfladingiz?"),
    ("кофе", "Сколько потратили?"),
    ("coffee", "How much did you spend?"),
    ("такси вчера", "Сколько стоило такси?"),
    ("taksi kecha", "Qancha to'ladingiz?"),
    ("lunch", "How much was lunch?"),
    ("50", "50 of what, and on what?"),
    ("нужно купить хлеб", "Это уже потрачено или планируете?"),
    ("non olishim kerak", "Bu xarajat qilinganmi yoki rejami?"),
    ("qancha pul sarfladim bu oyda?", None),
    ("сколько я потратил на еду?", None),
    ("how much did I spend this week?", None),
    ("salom", None), ("привет", None), ("hello", None), ("rahmat", None),
    ("удали последнюю запись", None), ("oxirgi yozuvni o'chir", None),
]


# Procedural OOD / low-confidence generators. A fixed 20-line AMBIG list is
# NOT enough: the model then answers "мм... наверное 40" with a hallucinated
# income record. These must be ~15% of the corpus and must be DIVERSE.
FILLER = {
    "uz_latin": ["hmm", "ehhh", "aaa", "shu", "nima edi", "yo'q, shoshma",
                 "bilmadim", "taxminan", "qarasam"],
    "uz_cyr": ["ҳмм", "аaa", "билмадим", "тахминан", "нима эди"],
    "ru": ["мм", "эээ", "наверное", "не помню", "хз", "погоди", "как бы",
           "короче", "ну"],
    "en": ["hmm", "uh", "maybe", "not sure", "idk", "wait", "like", "well"],
}
ASK_AMOUNT = {"uz_latin": "Qancha pul sarfladingiz?", "uz_cyr": "Қанча пул сарфладингиз?",
              "ru": "Сколько потратили?", "en": "How much did you spend?"}
ASK_WHAT = {"uz_latin": "Nimaga sarfladingiz?", "uz_cyr": "Нимага сарфладингиз?",
            "ru": "На что потратили?", "en": "What was it for?"}
ASK_CUR = {"uz_latin": "Qaysi valyutada?", "uz_cyr": "Қайси валютада?",
           "ru": "В какой валюте?", "en": "Which currency?"}


def build_ood(rng):
    """Procedurally generated ambiguous / non-transaction input."""
    lang = rng.choice(LANGS)
    kind = rng.choice(["filler_number", "item_only", "amount_only",
                       "no_currency_ambig", "future", "chitchat"])
    f = rng.choice(FILLER[lang])
    if kind == "filler_number":
        n = rng.randrange(2, 500)
        text = f"{f}... {rng.choice(['', f])} {n}".strip()
        return noisy(text, rng), {"intent": "unclear", "confidence": "low",
                                  "items": [], "clarification": ASK_WHAT[lang]}
    if kind == "item_only":
        row = rng.choice(ITEMS)
        text = f"{rng.choice(row[ITEM_IDX[lang]] or row[4])}"
        if rng.random() < 0.4:
            text = f"{f} {text}"
        return noisy(text, rng), {"intent": "unclear", "confidence": "low",
                                  "items": [], "clarification": ASK_AMOUNT[lang]}
    if kind == "amount_only":
        val = rng.choice([rng.randrange(10, 999), rng.randrange(1, 90) * 1000])
        amt_s, _ = fmt_amount(val, lang, rng)
        return noisy(amt_s, rng), {"intent": "unclear", "confidence": "low",
                                   "items": [], "clarification": ASK_WHAT[lang]}
    if kind == "no_currency_ambig":
        row = rng.choice(ITEMS)
        surface = rng.choice(row[ITEM_IDX[lang]] or row[4])
        text = f"{surface} 200"
        return noisy(text, rng), {"intent": "unclear", "confidence": "low",
                                  "items": [], "clarification": ASK_CUR[lang]}
    if kind == "future":
        row = rng.choice(ITEMS)
        surface = rng.choice(row[ITEM_IDX[lang]] or row[4])
        plan = {"uz_latin": f"ertaga {surface} olishim kerak",
                "uz_cyr": f"эртага {surface} олишим керак",
                "ru": f"завтра надо купить {surface}",
                "en": f"i need to buy {surface} tomorrow"}[lang]
        clar = {"uz_latin": "Bu xarajat qilinganmi yoki rejami?",
                "uz_cyr": "Бу харажат қилинганми ёки режами?",
                "ru": "Это уже потрачено или планируете?",
                "en": "Is that already spent, or planned?"}[lang]
        return noisy(plan, rng), {"intent": "unclear", "confidence": "low",
                                  "items": [], "clarification": clar}
    greet = {"uz_latin": ["salom", "rahmat", "yaxshimisiz", "xayr"],
             "uz_cyr": ["салом", "раҳмат", "хайр"],
             "ru": ["привет", "спасибо", "пока", "как дела"],
             "en": ["hello", "thanks", "bye", "how are you"]}[lang]
    return noisy(rng.choice(greet), rng), {"intent": "chitchat",
                                           "confidence": "high", "items": [],
                                           "clarification": None}


def build_adversarial(rng):
    if rng.random() < 0.75:
        return build_ood(rng)
    text, clar = rng.choice(AMBIG)
    if clar is not None:
        obj = {"intent": "unclear", "confidence": "low", "items": [],
               "clarification": clar}
    else:
        low = text.lower()
        if any(k in low for k in ["qancha", "сколько", "how much"]):
            intent = "query"
        elif any(k in low for k in ["o'chir", "удали", "delete"]):
            intent = "delete"
        else:
            intent = "chitchat"
        obj = {"intent": intent, "confidence": "high", "items": [],
               "clarification": None}
    return noisy(text, rng), obj


BUILDERS = [(build_expense, 0.44), (build_income, 0.10), (build_multi, 0.14),
            (build_codeswitch, 0.12), (build_adversarial, 0.20)]


def sample(rng):
    r, acc = rng.random(), 0.0
    for fn, w in BUILDERS:
        acc += w
        if r <= acc:
            return fn(rng)
    return build_expense(rng)


def to_record(text, obj):
    return {"messages": [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": text},
        {"role": "assistant",
         "content": json.dumps(obj, ensure_ascii=False, separators=(",", ":"))}]}


def main(outdir, n_train=6000, n_valid=400, n_test=600):
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(20260801)
    seen, recs, tries = set(), [], 0
    total = n_train + n_valid + n_test
    while len(recs) < total and tries < 500000:
        tries += 1
        text, obj = sample(rng)
        key = text.strip().lower()
        if key in seen or not text.strip():
            continue
        seen.add(key)
        recs.append(to_record(text, obj))
    rng.shuffle(recs)
    splits = {"train": recs[:n_train],
              "valid": recs[n_train:n_train + n_valid],
              "test": recs[n_train + n_valid:total]}
    for name, rows in splits.items():
        with open(os.path.join(outdir, f"{name}.jsonl"), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"{name}.jsonl: {len(rows)}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data")
