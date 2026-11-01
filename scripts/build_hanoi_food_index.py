#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Builds Resources/hanoi_food_index.zlib (HANOI_FOOD_INDEX_V2) by fusing:
  1. green_food_hanoi.json  (17,014 Xanh SM Hanoi merchants)
  2. shopeefood_hanoi.json  (53,602 ShopeeFood Hanoi merchants + alley/house GPS pins)
  3. grabfood_hanoi.json    (3,880 GrabFood top Hanoi high-volume merchants)

If raw JSON files are absent (e.g. on GitHub Actions macOS runners where
Resources/hanoi_food_index.zlib is already committed), verifies the existing
Resources/hanoi_food_index.zlib header and exits 0 cleanly.
"""
import argparse
import collections
import json
import math
import os
import re
import sys
import unicodedata
import zlib

DEFAULT_GF_PATHS = [
    r"C:\Users\Acer\Downloads\gsm\green_food_hanoi.json",
    "green_food_hanoi.json",
]
DEFAULT_SF_PATHS = [
    r"C:\Users\Acer\Downloads\gsm\shopeefood_hanoi.json",
    "shopeefood_hanoi.json",
]
DEFAULT_GR_PATHS = [
    r"C:\Users\Acer\Downloads\gsm\grabfood_hanoi.json",
    "grabfood_hanoi.json",
]
DEFAULT_OUT_PATH = os.path.join("Resources", "hanoi_food_index.zlib")

# Mask directional landmark phrases ("Đối diện Aeon", "Cạnh Vincom", "Gần Big C"...)
# BEFORE running mall detection so street-front shops across from a mall are NEVER false-flagged!
DIRECTIONAL_LANDMARK_RE = re.compile(
    r"\b(?:doi\s+dien|canh|ben\s+canh|ngay\s+canh|gan|sau|sau\s+lung|dang\s+sau|cach|huong|chech)\s+"
    r"(?:cong\s+[a-z0-9]*\s*|sanh\s+[a-z0-9]*\s*)?"
    r"(?:tttm\s+|trung\s+tam\s+thuong\s+mai\s+|sieu\s+thi\s+|toa\s+nha\s+)?"
    r"(?:vincom\w*|aeon\w*|lotte\w*|big\s*c|bigc|tops?\s*market|topmarket|mega\s*market|go|royal\s*city|"
    r"times\s*city|park\s*hill|keangnam|the\s*garden|indochina|iph|the\s*loop|tasco\w*|savico|artemis|"
    r"discovery|trang\s*tien|ho\s*guom|mac\s*plaza|machinco|mipec|the\s*zei|tnr|sun\s*plaza|rox\s*center|ebest)"
    r"(?:\s+[a-z0-9]+){0,3}"
)

MALL_REGEX = re.compile(
    r"\b("
    r"tttm|trung\s+tam\s+thuong\s+mai|vincom|vincommall|aeon\s*mall|aeonmall|aeon|"
    r"lotte\s*mall|lottemall|lotte\s*center|lotte\s*centre|lotte\s*dao\s*tan|lotte\s*mart|lottemart|"
    r"royal\s*city|times\s*city|park\s*hill|big\s*c|bigc|tops?\s*market|topmarket|"
    r"go\s*thang\s*long|go\s*mall|mega\s*market|the\s*garden|indochina|iph\s*xuan\s*thuy|iph\s*cau\s*giay|"
    r"the\s*loop|keangnam|landmark\s*72|tasco\s*mall|tascomall|savico|artemis|discovery\s*complex|"
    r"trang\s*tien\s*plaza|ho\s*guom\s*plaza|mac\s*plaza|machinco|mipec\s*long\s*bien|mipec\s*tay\s*son|"
    r"mipec\s*tower|the\s*zei|tnr\s*tower|sun\s*plaza|cho\s*dong\s*xuan|rox\s*center|ha\s*noi\s*centre|ebest|"
    r"tang\s*ham|ham\s*b[1-4]|gian\s*hang|kiosk|food\s*court|goods\s*court|"
    r"tang\s*l[1-6]|lo\s*b[1-3]|lo\s*f[1-6]|b[1-3]\s*-\s*[a-z0-9]|l[1-6]\s*-\s*[0-9a-z]|f[1-6]\s*-\s*[a-z0-9]"
    r")\b"
)

EXACT_MALL_ADDR_REGEX = re.compile(
    r"(?:^|\b)("
    r"72a\s+(?:duong\s+)?nguyen\s+trai|"
    r"458\s+(?:pho\s+|duong\s+)?minh\s+khai|"
    r"191\s+(?:pho\s+)?ba\s+trieu|"
    r"54a\s+(?:duong\s+)?nguyen\s+chi\s+thanh|"
    r"119\s+(?:duong\s+)?tran\s+duy\s+hung|"
    r"222\s+(?:duong\s+)?tran\s+duy\s+hung|"
    r"272\s+(?:duong\s+)?vo\s+chi\s+cong|"
    r"54\s+(?:pho\s+)?lieu\s+giai|"
    r"29\s+(?:pho\s+)?lieu\s+giai|"
    r"0?2\s+pham\s+ngoc\s+thach|"
    r"241\s+(?:duong\s+)?xuan\s+thuy|"
    r"27\s+(?:duong\s+)?co\s+linh|"
    r"302\s+(?:duong\s+)?cau\s+giay|"
    r"0?3\s+le\s+trong\s+tan|"
    r"229\s+(?:pho\s+)?tay\s+son|"
    r"234\s+(?:duong\s+)?pham\s+van\s+dong|"
    r"236\s+(?:duong\s+|d\s+)?pham\s+van\s+dong|"
    r"24\s+(?:pho\s+)?hai\s+ba\s+trung"
    r")\b"
)

GENERIC_FOOD_WORDS = {
    "quan", "tiem", "nha", "hang", "bep", "co", "chu", "ba", "ong", "anh", "chi", "em",
    "bun", "pho", "mien", "chao", "xoi", "com", "banh", "mi", "my", "lau", "nuong", "ga",
    "bo", "heo", "lon", "vit", "ngan", "ca", "tom", "oc", "hai", "san", "chay", "thit",
    "suon", "tam", "rang", "dua", "dau", "mam", "met", "nem", "cha", "cuon", "tron", "cham",
    "ran", "chien", "xao", "hap", "luoc", "quay", "kho", "sot", "cay", "chua", "ngot",
    "tra", "sua", "ca", "phe", "coffee", "cafe", "tea", "fresh", "juice", "nuoc", "ep",
    "sinh", "to", "che", "kem", "sua", "chua", "tran", "chau", "matcha", "latte", "cacao",
    "an", "vat", "do", "uong", "ngon", "gia", "truyen", "dac", "san", "pho", "co", "ha", "noi",
    "sai", "gon", "hue", "da", "nang", "mien", "tay", "bac", "nam", "trung", "han", "quoc",
    "nhat", "ban", "dai", "loan", "thai", "lan", "hong", "kong", "singapore", "italia",
    "pizza", "burger", "spaghetti", "pasta", "steak", "bbq", "hotpot", "dimsum", "sushi",
    "kimbap", "tokbokki", "salad", "healthy", "bakery", "cake", "bread", "food", "kitchen",
    "shop", "store", "online", "express", "deli", "house", "corner", "station", "club"
}


def norm_vn(s: str) -> str:
    s = (str(s) if s is not None else "").lower().replace("đ", "d")
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = re.sub(r"[^a-z0-9\s/,-]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def clean_lookup_key(s: str) -> str:
    s = norm_vn(s)
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    s = re.sub(r"\b(thanh pho ha noi|tp ha noi|ha noi|hanoi|viet nam|vietnam|vnm|100000|10000)\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6371008.8
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat * 0.5) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng * 0.5) ** 2
    return r * 2.0 * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


def detect_true_mall(raw_blob: str) -> bool:
    norm = norm_vn(raw_blob)
    if not norm:
        return False
    # Strip "Đối diện / Cạnh / Gần / Sau lưng <Mall>" landmarks first!
    scrubbed = DIRECTIONAL_LANDMARK_RE.sub(" ", norm)
    # Strip plain street-level apartment kiots ("kiot 6 ct10...", "kiot hh2...")
    scrubbed = re.sub(r"\bkiot\s+[a-z0-9\s]{0,12}\b(?:chung cu|ct\d|hh\d|ngo|cho|kdt)\b", " ", scrubbed)
    return bool(MALL_REGEX.search(scrubbed) or EXACT_MALL_ADDR_REGEX.search(scrubbed))


def distinctive_brand_tokens(raw_name: str):
    head = (raw_name or "").split(" - ")[0]
    words = clean_lookup_key(head).split()
    dist = [w for w in words if len(w) >= 2 and w not in GENERIC_FOOD_WORDS and not w.isdigit()]
    if dist:
        return dist
    # Fallback to full normalized brand phrase if name consists entirely of generic words (e.g. "Cơm Sườn Đào Duy Từ")
    return [w for w in words if len(w) >= 2]


def strict_same_brand(name_a: str, name_b: str) -> bool:
    ca = clean_lookup_key((name_a or "").split(" - ")[0])
    cb = clean_lookup_key((name_b or "").split(" - ")[0])
    if not ca or not cb:
        return False
    if ca == cb or (len(ca) >= 8 and ca in cb) or (len(cb) >= 8 and cb in ca):
        return True
    da = distinctive_brand_tokens(name_a)
    db = distinctive_brand_tokens(name_b)
    sa, sb = set(da), set(db)
    inter = sa & sb
    if len(inter) >= 2:
        return True
    if len(inter) == 1:
        tok = next(iter(inter))
        if len(tok) >= 5 and tok not in GENERIC_FOOD_WORDS and (len(sa) <= 2 or len(sb) <= 2):
            return True
    return False


def extract_street_parts(addr_str: str, new_label_str: str = ""):
    segs = [norm_vn(x) for x in (addr_str or "").split(",") if x.strip()]
    new_segs = [norm_vn(x) for x in (new_label_str or "").split(",") if x.strip()]
    if not segs:
        return ("", 0, 0, "", [])

    admin_tokens = []
    ward_full_names = []
    for sg in segs[1:] + new_segs[1:]:
        sg_raw = re.sub(r"[^a-z0-9\s]", " ", sg)
        sg_raw = re.sub(r"\s+", " ", sg_raw).strip()
        if any(sg_raw.startswith(p) for p in ("phuong ", "xa ", "thi tran ", "khu do thi ", "vinhomes ")):
            if sg_raw not in ward_full_names:
                ward_full_names.append(sg_raw)
        sg_c = re.sub(
            r"\b(phuong|quan|huyen|thi tran|xa|thanh pho|ha noi|hanoi|viet nam|vietnam|vnm|tp|p|q|10000|100000)\b",
            " ",
            sg_raw,
        )
        sg_c = re.sub(r"\s+", " ", sg_c).strip()
        if sg_c and len(sg_c) >= 2 and sg_c not in admin_tokens:
            admin_tokens.append(sg_c)
    admin_str = "|".join(admin_tokens[:3])

    for raw_cand in segs[:3]:
        cand = re.sub(r"[^a-z0-9\s/]", " ", raw_cand)
        cand = re.sub(r"\s+", " ", cand).strip()
        if not cand or cand.startswith(("phuong ", "quan ", "huyen ", "thi tran ", "xa ", "thanh pho ", "tp ")):
            continue

        m_ngo = re.search(r"\b(?:ngo|ng)\s+(\d+[a-z]?)\s+(?:duong\s+|pho\s+|p\s+|d\s+)?([a-z][a-z0-9\s]{2,32})$", cand)
        if m_ngo:
            ngo_m = re.match(r"\d+", m_ngo.group(1))
            ngo_num = int(ngo_m.group(0)) if ngo_m else 0
            st_name = re.sub(r"^(duong|pho|p|d)\s+", "", m_ngo.group(2).strip())
            prefix = cand[: m_ngo.start()].strip()
            m_h = re.search(r"\b(\d{1,4})\b", prefix)
            h_num = int(m_h.group(1)) if m_h else 0
            return (st_name, min(ngo_num, 32000), min(h_num, 32000), admin_str, ward_full_names)

        m_st = re.search(r"^(?:so\s+|sn\s+)?(\d{1,4})[a-z]?(?:/\d+[a-z]?)?\s+(?:duong\s+|pho\s+|p\s+|d\s+)?([a-z][a-z0-9\s]{2,32})$", cand)
        if m_st:
            st_cand = re.sub(r"^(duong|pho|p|d)\s+", "", m_st.group(2).strip())
            if not st_cand.startswith(("tang ", "lo ", "kiot ", "kiosk ", "toa ", "sanh ", "phong ", "khu ", "cau thang ", "nha ")):
                return (st_cand, 0, min(int(m_st.group(1)), 32000), admin_str, ward_full_names)

        m_st2 = re.search(r"(?:^|\b)(?:duong|pho)\s+([a-z][a-z0-9\s]{2,32})$", cand)
        if m_st2:
            m_h = re.search(r"\b(\d{1,4})\b", cand[: m_st2.start()])
            st_name = re.sub(r"^(duong|pho|p|d)\s+", "", m_st2.group(1).strip())
            return (st_name, 0, min(int(m_h.group(1)), 32000) if m_h else 0, admin_str, ward_full_names)

        # ShopeeFood style without 'Đường/Phố' keyword: e.g. "56 Hàng Than" or "88 Trần Đại Nghĩa"
        m_bare = re.search(r"^(?:so\s+|sn\s+)?(\d{1,4})[a-z]?(?:/\d+[a-z]?)?\s+([a-z][a-z\s]{2,28})$", cand)
        if m_bare:
            st_cand = re.sub(r"^(duong|pho|p|d)\s+", "", m_bare.group(2).strip())
            if not st_cand.startswith(("tang ", "lo ", "kiot ", "kiosk ", "toa ", "sanh ", "phong ", "khu ", "cau thang ", "nha ")):
                return (st_cand, 0, min(int(m_bare.group(1)), 32000), admin_str, ward_full_names)

    return ("", 0, 0, admin_str, ward_full_names)


def find_existing_file(candidates):
    for p in candidates:
        if p and os.path.isfile(p):
            return p
    return ""


def parse_safe_int(val) -> int:
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, str):
        s = val.strip()
        if s.isdigit():
            return int(s)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="", help="Path to green_food_hanoi.json")
    ap.add_argument("--shopee", default="", help="Path to shopeefood_hanoi.json")
    ap.add_argument("--grab", default="", help="Path to grabfood_hanoi.json")
    ap.add_argument("--output", default=DEFAULT_OUT_PATH, help="Output zlib path")
    args = ap.parse_args()

    gf_path = args.input or find_existing_file(DEFAULT_GF_PATHS)
    sf_path = args.shopee or find_existing_file(DEFAULT_SF_PATHS)
    gr_path = args.grab or find_existing_file(DEFAULT_GR_PATHS)

    if not gf_path:
        if os.path.isfile(args.output) and os.path.getsize(args.output) > 100000:
            raw_hdr = zlib.decompress(open(args.output, "rb").read())[:64].decode("utf-8", errors="ignore").splitlines()[0]
            print(f"[build_hanoi_food_index] Reusing committed {args.output} ({os.path.getsize(args.output):,} bytes, hdr='{raw_hdr}').")
            return 0
        print("[build_hanoi_food_index] ERROR: green_food_hanoi.json not found and no prebuilt index exists!", file=sys.stderr)
        return 1

    with open(gf_path, "r", encoding="utf-8") as f:
        gf_records = json.load(f)
    sf_records = json.load(open(sf_path, "r", encoding="utf-8")) if sf_path else []
    gr_records = json.load(open(gr_path, "r", encoding="utf-8")) if gr_path else []

    # 1. Pre-index ShopeeFood spatially (~110m grid) + extract street GPS pins
    sf_grid = collections.defaultdict(list)
    sf_parsed = []
    street_pin_lookup = {}  # (st_key, ngo_num, h_num, adm_first) -> (lat, lng)
    ward_accum = collections.defaultdict(list)

    for idx, sr in enumerate(sf_records):
        lat = sr.get("lat")
        lng = sr.get("lng")
        if not isinstance(lat, (int, float)) or not isinstance(lng, (int, float)):
            continue
        if not (20.4 < lat < 21.6 and 105.2 < lng < 106.2):
            continue
        full_addr = f"{sr.get('address', '')}, {sr.get('district', '')}"
        st_k, ngo_n, h_n, adm_k, w_names = extract_street_parts(full_addr, "")
        for wn in w_names:
            ward_accum[wn].append((lat, lng))
        adm0 = adm_k.split("|")[0] if adm_k else ""
        if st_k and (ngo_n > 0 or h_n > 0):
            street_pin_lookup.setdefault((st_k, ngo_n, h_n, adm0), (lat, lng))

        pop = parse_safe_int(sr.get("popularity_score"))
        eff_sf = int(round(pop * 3.0))  # Empirical Top-10..200 quantile alignment with GreenFood orders
        is_m = detect_true_mall(f"{sr.get('name', '')} , {sr.get('address', '')}")
        item = {
            "idx": idx,
            "lat": float(lat),
            "lng": float(lng),
            "name": sr.get("name", ""),
            "addr": sr.get("address", ""),
            "dist": sr.get("district", ""),
            "eff_oc": eff_sf,
            "is_mall": is_m,
            "st": st_k,
            "ngo": ngo_n,
            "num": h_n,
            "adm": adm_k,
            "linked": False,
        }
        sf_parsed.append(item)
        sf_grid[(int(lat * 1000), int(lng * 1000))].append(item)

    # 2. Pre-index GrabFood by street + distinctive brand tokens
    gr_by_st = collections.defaultdict(list)
    gr_by_tok = collections.defaultdict(list)
    gr_parsed = []
    for idx, gr in enumerate(gr_records):
        full_addr = f"{gr.get('address', '')}, {gr.get('district', '')}"
        st_k, ngo_n, h_n, adm_k, _ = extract_street_parts(full_addr, "")
        votes = parse_safe_int(gr.get("vote_count"))
        eff_gr = int(round(votes * 3.2))  # Empirical Top-10..200 quantile alignment with GreenFood orders
        is_m = detect_true_mall(f"{gr.get('name', '')} , {gr.get('address', '')}")
        glat = float(gr["lat"]) if str(gr.get("lat", "")).strip() not in ("", "None") else 0.0
        glng = float(gr["lng"]) if str(gr.get("lng", "")).strip() not in ("", "None") else 0.0
        if (glat == 0.0 or glng == 0.0) and st_k and (ngo_n > 0 or h_n > 0):
            adm0 = adm_k.split("|")[0] if adm_k else ""
            pt = street_pin_lookup.get((st_k, ngo_n, h_n, adm0))
            if pt:
                glat, glng = pt
        item = {
            "idx": idx,
            "lat": glat,
            "lng": glng,
            "name": gr.get("name", ""),
            "addr": gr.get("address", ""),
            "dist": gr.get("district", ""),
            "eff_oc": eff_gr,
            "is_mall": is_m,
            "st": st_k,
            "ngo": ngo_n,
            "num": h_n,
            "adm": adm_k,
            "linked": False,
        }
        gr_parsed.append(item)
        if st_k:
            gr_by_st[st_k].append(item)
        for tok in set(distinctive_brand_tokens(item["name"])):
            gr_by_tok[tok].append(item)

    # 3. Fuse all 17,014 GreenFood merchants with ShopeeFood & GrabFood
    merchant_lines = []
    gf_covered_pins = set()
    mall_cnt = 0
    crowd_boosted_cnt = 0
    mall_unmasked_cnt = 0

    for r in gf_records:
        lat = r.get("lat")
        lng = r.get("lng")
        if not isinstance(lat, (int, float)) or not isinstance(lng, (int, float)):
            continue
        if not (20.4 < lat < 21.6 and 105.2 < lng < 106.2):
            continue

        oc_gf = parse_safe_int(r.get("order_count"))
        mc_raw = r.get("mc_name", "")
        fl_raw = r.get("full_label", "")
        nl_raw = r.get("new_admin_label", "")
        ad_raw = r.get("address", "")

        st_key, ngo_num, h_num, adm_key, ward_names = extract_street_parts(ad_raw or fl_raw, nl_raw)
        for wn in ward_names:
            ward_accum[wn].append((lat, lng))
        if st_key and (ngo_num > 0 or h_num > 0):
            adm0 = adm_key.split("|")[0] if adm_key else ""
            gf_covered_pins.add((st_key, ngo_num, h_num, adm0))

        # Match exact merchant in ShopeeFood (<= 55m + strict same brand)
        best_sf = None
        gx, gy = int(lat * 1000), int(lng * 1000)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for s_item in sf_grid.get((gx + dx, gy + dy), ()):
                    if haversine_m(lat, lng, s_item["lat"], s_item["lng"]) <= 55.0:
                        if strict_same_brand(mc_raw, s_item["name"]):
                            if best_sf is None or s_item["eff_oc"] > best_sf["eff_oc"]:
                                best_sf = s_item
        if best_sf:
            best_sf["linked"] = True

        # Match exact merchant in GrabFood (same street+number OR GPS <= 55m, PLUS strict same brand)
        best_gr = None
        cand_grs = list(gr_by_st.get(st_key, ())) if st_key else []
        for tok in set(distinctive_brand_tokens(mc_raw)):
            cand_grs.extend(gr_by_tok.get(tok, ()))
        seen_g = set()
        gf_adm_clean = clean_lookup_key(f"{fl_raw} {ad_raw} {r.get('district_or_ward', '')}")
        for g_item in cand_grs:
            if g_item["idx"] in seen_g:
                continue
            seen_g.add(g_item["idx"])
            if not strict_same_brand(mc_raw, g_item["name"]):
                continue
            loc_ok = False
            if g_item["lat"] > 20.4 and haversine_m(lat, lng, g_item["lat"], g_item["lng"]) <= 60.0:
                loc_ok = True
            elif st_key and g_item["st"] == st_key and (h_num == 0 or g_item["num"] == 0 or abs(h_num - g_item["num"]) <= 4):
                loc_ok = True
            elif g_item["dist"]:
                d_tok = clean_lookup_key(g_item["dist"]).replace("quan ", "").replace("huyen ", "").strip()
                g_ad_words = [w for w in clean_lookup_key(g_item["addr"]).split() if len(w) >= 4]
                if d_tok and d_tok in gf_adm_clean and len(g_ad_words) >= 2 and all(w in gf_adm_clean for w in g_ad_words[:2]):
                    loc_ok = True
            if loc_ok:
                if best_gr is None or g_item["eff_oc"] > best_gr["eff_oc"]:
                    best_gr = g_item
        if best_gr:
            best_gr["linked"] = True

        gf_mall = detect_true_mall(f"{mc_raw} , {ad_raw} , {fl_raw}")
        sf_mall = best_sf["is_mall"] if best_sf else False
        gr_mall = best_gr["is_mall"] if best_gr else False
        is_mall = 1 if (gf_mall or sf_mall or gr_mall) else 0
        if is_mall:
            mall_cnt += 1
            if not gf_mall:
                mall_unmasked_cnt += 1

        eff_orders = max(
            oc_gf,
            best_sf["eff_oc"] if best_sf else 0,
            best_gr["eff_oc"] if best_gr else 0,
        )
        if eff_orders >= 5000 and oc_gf < 5000:
            crowd_boosted_cnt += 1

        mc_clean = clean_lookup_key(mc_raw)
        fl_clean = clean_lookup_key(fl_raw)
        if fl_clean == "unknown":
            fl_clean = ""
        nl_clean = clean_lookup_key(nl_raw)
        ad_clean = clean_lookup_key(ad_raw)

        if not fl_clean:
            fl_clean = ad_clean
        if not fl_clean and best_sf:
            fl_clean = clean_lookup_key(f"{best_sf['addr']} {best_sf['dist']}")

        nl_diff = nl_clean if (nl_clean and nl_clean != fl_clean) else ""
        ad_diff = (
            ad_clean
            if (ad_clean and ad_clean != fl_clean and ad_clean != nl_clean and not fl_clean.endswith(ad_clean))
            else ""
        )
        if not ad_diff and best_sf:
            sf_ad_clean = clean_lookup_key(f"{best_sf['addr']} {best_sf['dist']}")
            if sf_ad_clean and sf_ad_clean != fl_clean and sf_ad_clean != nl_clean:
                ad_diff = sf_ad_clean

        merchant_lines.append(
            f"{lat:.5f}\t{lng:.5f}\t{eff_orders}\t{is_mall}\t{mc_clean}\t{fl_clean}\t{nl_diff}\t{ad_diff}\t{st_key}\t{ngo_num}\t{h_num}\t{adm_key}"
        )

    # 4. Preemptive Off-GreenFood Guard Rows (unlinked Mall/Basement OR Crowd >= 5000 from ShopeeFood & GrabFood)
    preemptive_added = 0
    seen_preemptive = set()
    for src_item in sf_parsed + gr_parsed:
        if src_item["linked"]:
            continue
        if not src_item["is_mall"] and src_item["eff_oc"] < 5000:
            continue
        if not (20.4 < src_item["lat"] < 21.6 and 105.2 < src_item["lng"] < 106.2):
            continue
        mc_c = clean_lookup_key(src_item["name"])
        fl_c = clean_lookup_key(f"{src_item['addr']} {src_item['dist']}")
        if len(mc_c) < 3 or len(fl_c) < 6:
            continue
        dedup_k = (mc_c[:20], fl_c[:28])
        if dedup_k in seen_preemptive:
            continue
        seen_preemptive.add(dedup_k)
        is_m = 1 if src_item["is_mall"] else 0
        if is_m:
            mall_cnt += 1
        merchant_lines.append(
            f"{src_item['lat']:.5f}\t{src_item['lng']:.5f}\t{src_item['eff_oc']}\t{is_m}\t{mc_c}\t{fl_c}\t\t\t{src_item['st']}\t{src_item['ngo']}\t{src_item['num']}\t{src_item['adm']}"
        )
        preemptive_added += 1

    # 5. Extra Hanoi Street/Alley/House GPS Pins from ShopeeFood (for 3.1x denser Offline Dropoff Geocoding)
    pin_lines = []
    for (st_k, ngo_n, h_n, adm0), (plat, plng) in sorted(street_pin_lookup.items()):
        if (st_k, ngo_n, h_n, adm0) in gf_covered_pins:
            continue
        pin_lines.append(f"@P\t{plat:.5f}\t{plng:.5f}\t{st_k}\t{ngo_n}\t{h_n}\t{adm0}")

    # 6. Ward / KĐT Centroids across combined 70k GPS points
    ward_lines = []
    for wn, pts in sorted(ward_accum.items()):
        if len(pts) >= 2:
            avg_lat = sum(p[0] for p in pts) / len(pts)
            avg_lng = sum(p[1] for p in pts) / len(pts)
            ward_lines.append(f"@W\t{avg_lat:.5f}\t{avg_lng:.5f}\t{wn}")

    header = f"HANOI_FOOD_INDEX_V2\t{len(merchant_lines)}\t{len(pin_lines)}\t{len(ward_lines)}"
    full_payload = "\n".join([header] + merchant_lines + pin_lines + ward_lines).encode("utf-8")
    compressed = zlib.compress(full_payload, level=9)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(compressed)

    print(
        f"[build_hanoi_food_index V2] Built {args.output}:\n"
        f"  - Merchants: {len(merchant_lines):,} ({mall_cnt:,} mall/basement [{mall_unmasked_cnt} newly unmasked], "
        f"{crowd_boosted_cnt} crowd-boosted >=5k, +{preemptive_added:,} preemptive SF/GR guards)\n"
        f"  - Extra Street/Alley Pins: +{len(pin_lines):,} (Total unique Hanoi pins: {len(street_pin_lookup) + len(gf_covered_pins):,})\n"
        f"  - Hanoi Wards/Zones: {len(ward_lines):,}\n"
        f"  - Size: raw={len(full_payload)/1024:.1f} KB -> zlib={len(compressed)/1024:.1f} KB"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
