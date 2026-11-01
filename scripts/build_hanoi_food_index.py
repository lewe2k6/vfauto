#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Builds Resources/hanoi_food_index.zlib from green_food_hanoi.json.
If the JSON source is not present (e.g., on GitHub Actions CI where Resources/hanoi_food_index.zlib
is already committed), exits 0 cleanly after verifying Resources/hanoi_food_index.zlib exists.
"""
import argparse
import collections
import json
import os
import re
import sys
import unicodedata
import zlib

DEFAULT_JSON_PATHS = [
    r"C:\Users\Acer\Downloads\gsm\green_food_hanoi.json",
    "green_food_hanoi.json",
]
DEFAULT_OUT_PATH = os.path.join("Resources", "hanoi_food_index.zlib")

MALL_REGEX = re.compile(
    r"\b("
    r"tttm|trung tam thuong mai|vincom|aeon\s*mall|aeonmall|lotte\s*mall|lotte\s*center|lotte\s*mart|"
    r"royal\s*city|times\s*city|park\s*hill|big\s*c|bigc|tops\s*market|go\s*thang\s*long|mega\s*market|"
    r"the\s*garden|indochina|iph\s*xuan\s*thuy|the\s*loop|keangnam|landmark\s*72|tasco\s*mall|savico|"
    r"artemis|discovery\s*complex|trang\s*tien\s*plaza|ho\s*guom\s*plaza|mac\s*plaza|machinco|"
    r"mipec\s*long\s*bien|mipec\s*tay\s*son|mipec\s*tower|the\s*zei|tnr\s*tower|sun\s*plaza|cho\s*dong\s*xuan|"
    r"tang\s*ham|ham\s*b1|ham\s*b2|ham\s*b3|gian\s*hang|kiosk|food\s*court|goods\s*court|"
    r"tang\s*[2-8]|tang\s*0[2-8]|tang\s*l[1-6]|lo\s*b[1-2]|b1\s*-\s*[a-z0-9]|b2\s*-\s*[a-z0-9]|"
    r"l[1-6]\s*-\s*[0-9a-z]"
    r")\b"
)

EXACT_MALL_ADDR_REGEX = re.compile(
    r"(?:^|\b)("
    r"72a\s+nguyen\s+trai|72a\s+duong\s+nguyen\s+trai|"
    r"458\s+minh\s+khai|458\s+pho\s+minh\s+khai|458\s+duong\s+minh\s+khai|"
    r"191\s+ba\s+trieu|191\s+pho\s+ba\s+trieu|"
    r"54a\s+nguyen\s+chi\s+thanh|54a\s+duong\s+nguyen\s+chi\s+thanh|"
    r"119\s+tran\s+duy\s+hung|119\s+duong\s+tran\s+duy\s+hung|"
    r"222\s+tran\s+duy\s+hung|222\s+duong\s+tran\s+duy\s+hung|"
    r"272\s+vo\s+chi\s+cong|272\s+duong\s+vo\s+chi\s+cong|"
    r"54\s+lieu\s+giai|54\s+pho\s+lieu\s+giai|"
    r"29\s+lieu\s+giai|29\s+pho\s+lieu\s+giai|"
    r"2\s+pham\s+ngoc\s+thach|02\s+pham\s+ngoc\s+thach|"
    r"241\s+xuan\s+thuy|241\s+duong\s+xuan\s+thuy|"
    r"27\s+co\s+linh|27\s+duong\s+co\s+linh|"
    r"302\s+cau\s+giay|302\s+duong\s+cau\s+giay|"
    r"3\s+le\s+trong\s+tan|03\s+le\s+trong\s+tan|"
    r"229\s+tay\s+son|229\s+pho\s+tay\s+son|"
    r"234\s+pham\s+van\s+dong|234\s+duong\s+pham\s+van\s+dong|"
    r"24\s+hai\s+ba\s+trung|24\s+pho\s+hai\s+ba\s+trung"
    r")\b"
)


def norm_vn(s: str) -> str:
    s = (s or "").lower().replace("đ", "d")
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = re.sub(r"[^a-z0-9\s/,-]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def clean_lookup_key(s: str) -> str:
    s = norm_vn(s)
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    s = re.sub(r"\b(thanh pho ha noi|tp ha noi|ha noi|viet nam|vietnam|vnm|100000|10000)\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def extract_street_parts(addr_str: str, new_label_str: str):
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
        sg_c = re.sub(r"\b(phuong|quan|huyen|thi tran|xa|thanh pho|ha noi|viet nam|vietnam|vnm|tp|p|q|10000|100000)\b", " ", sg_raw)
        sg_c = re.sub(r"\s+", " ", sg_c).strip()
        if sg_c and len(sg_c) >= 2 and sg_c not in admin_tokens:
            admin_tokens.append(sg_c)
    admin_str = "|".join(admin_tokens[:3])

    cand = segs[0]
    if len(segs) >= 2 and not re.search(r"\b(duong|pho|ngo|ngach|hem|ql|quoc lo|tinh lo)\b|\d", cand):
        cand = segs[1]
    cand = re.sub(r"[^a-z0-9\s/]", " ", cand)
    cand = re.sub(r"\s+", " ", cand).strip()

    m_ngo = re.search(r"\b(?:ngo|ng)\s+(\d+[a-z]?)\s+(?:duong\s+|pho\s+|p\s+)?([a-z][a-z0-9\s]{2,32})$", cand)
    if m_ngo:
        ngo_m = re.match(r"\d+", m_ngo.group(1))
        ngo_num = int(ngo_m.group(0)) if ngo_m else 0
        st_name = re.sub(r"^(duong|pho|p)\s+", "", m_ngo.group(2).strip())
        prefix = cand[: m_ngo.start()].strip()
        m_h = re.search(r"\b(\d+)\b", prefix)
        h_num = int(m_h.group(1)) if m_h else 0
        return (st_name, ngo_num, h_num, admin_str, ward_full_names)

    m_st = re.search(r"^(?:so\s+|sn\s+)?(\d+)[a-z]?(?:/\d+[a-z]?)?\s+(?:duong\s+|pho\s+|p\s+)?([a-z][a-z0-9\s]{2,32})$", cand)
    if m_st:
        st_name = re.sub(r"^(duong|pho|p)\s+", "", m_st.group(2).strip())
        return (st_name, 0, int(m_st.group(1)), admin_str, ward_full_names)

    m_st2 = re.search(r"\b(?:duong|pho)\s+([a-z][a-z0-9\s]{2,32})$", cand)
    if m_st2:
        m_h = re.search(r"\b(\d+)\b", cand[: m_st2.start()])
        st_name = re.sub(r"^(duong|pho|p)\s+", "", m_st2.group(1).strip())
        return (st_name, 0, int(m_h.group(1)) if m_h else 0, admin_str, ward_full_names)

    return ("", 0, 0, admin_str, ward_full_names)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="", help="Path to green_food_hanoi.json")
    ap.add_argument("--output", default=DEFAULT_OUT_PATH, help="Output zlib path")
    args = ap.parse_args()

    in_path = args.input
    if not in_path:
        for p in DEFAULT_JSON_PATHS:
            if os.path.isfile(p):
                in_path = p
                break

    if not in_path or not os.path.isfile(in_path):
        if os.path.isfile(args.output) and os.path.getsize(args.output) > 100000:
            print(f"[build_hanoi_food_index] Using prebuilt {args.output} ({os.path.getsize(args.output)} bytes).")
            return 0
        print("[build_hanoi_food_index] ERROR: green_food_hanoi.json not found and no prebuilt index exists!", file=sys.stderr)
        return 1

    with open(in_path, "r", encoding="utf-8") as f:
        records = json.load(f)

    merchant_lines = []
    ward_accum = collections.defaultdict(list)
    mall_cnt = 0

    for r in records:
        lat = r.get("lat")
        lng = r.get("lng")
        if not isinstance(lat, (int, float)) or not isinstance(lng, (int, float)):
            continue
        if lat < 20.4 or lat > 21.6 or lng < 105.2 or lng > 106.2:
            continue

        oc = r.get("order_count")
        if isinstance(oc, (int, float)):
            oc_int = int(oc)
        elif isinstance(oc, str) and oc.strip().isdigit():
            oc_int = int(oc.strip())
        else:
            oc_int = 0

        blob = norm_vn(f"{r.get('mc_name','')} , {r.get('address','')} , {r.get('full_label','')}")
        is_mall = 1 if (MALL_REGEX.search(blob) or EXACT_MALL_ADDR_REGEX.search(blob)) else 0
        if is_mall:
            mall_cnt += 1

        mc_clean = clean_lookup_key(r.get("mc_name", ""))
        fl_clean = clean_lookup_key(r.get("full_label", ""))
        nl_clean = clean_lookup_key(r.get("new_admin_label", ""))
        ad_clean = clean_lookup_key(r.get("address", ""))

        if not fl_clean:
            fl_clean = ad_clean
        nl_diff = nl_clean if (nl_clean and nl_clean != fl_clean) else ""
        ad_diff = (
            ad_clean
            if (ad_clean and ad_clean != fl_clean and ad_clean != nl_clean and not fl_clean.endswith(ad_clean))
            else ""
        )

        st_key, ngo_num, h_num, adm_key, ward_names = extract_street_parts(
            r.get("address", ""), r.get("new_admin_label", "")
        )

        for wn in ward_names:
            ward_accum[wn].append((lat, lng))

        merchant_lines.append(
            f"{lat:.5f}\t{lng:.5f}\t{oc_int}\t{is_mall}\t{mc_clean}\t{fl_clean}\t{nl_diff}\t{ad_diff}\t{st_key}\t{ngo_num}\t{h_num}\t{adm_key}"
        )

    ward_lines = []
    for wn, pts in sorted(ward_accum.items()):
        if len(pts) >= 2:
            avg_lat = sum(p[0] for p in pts) / len(pts)
            avg_lng = sum(p[1] for p in pts) / len(pts)
            ward_lines.append(f"@W\t{avg_lat:.5f}\t{avg_lng:.5f}\t{wn}")

    header = f"HANOI_FOOD_INDEX_V1\t{len(merchant_lines)}\t{len(ward_lines)}"
    full_payload = "\n".join([header] + merchant_lines + ward_lines).encode("utf-8")
    compressed = zlib.compress(full_payload, level=9)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(compressed)

    print(
        f"[build_hanoi_food_index] Built {args.output}: "
        f"{len(merchant_lines)} merchants ({mall_cnt} mall/basement), "
        f"{len(ward_lines)} Hanoi wards, raw={len(full_payload)/1024:.1f} KB -> zlib={len(compressed)/1024:.1f} KB"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
