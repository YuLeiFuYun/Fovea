#!/usr/bin/env python3
"""生成并校验 Fovea Workbench 的真实媒体素材清单。"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from image_metadata import contains_sensitive_image_metadata, sanitize_image_metadata

ROOT = Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench/Resources"
CATALOG_PATH = RESOURCE_ROOT / "workbench-media-catalog.json"
LOCAL_ROOT = RESOURCE_ROOT / "LocalMedia"
API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "FoveaWorkbenchCatalog/1.0 (https://github.com/; educational example)"
TARGET_REMOTE_COUNT = 480
TARGET_LOCAL_COUNT = 29
CACHE_ROOT = ROOT / ".artifacts/workbench-media-generator"
REQUEST_LOCK = threading.Lock()
LAST_REQUEST_TIME = 0.0
ALLOWED_LICENSES = {"CC0", "Public domain", "PDM"}
ALLOWED_EXTENSIONS = {"jpg", "jpeg", "png", "webp"}
CURATED_LOCAL_FILE_NAMES = [
    "A view of the Taunus mountain range during fog 3.png",
    "Fog descending on a pine forest (Unsplash).jpg",
    "Golfarone Waterfall (Villa Minozzo) in 2024.02.jpg",
    "Apple flower dissected.jpg",
    "Flower in Guingamp 5.jpg",
    "Flowers in Tokyo.jpg",
    "Arthur A. Smith Covered Bridge - interior.jpg",
    "Cityscape of Taipei, Taiwan 20151221.jpg",
    "Bridge in forest (21158992109).jpg",
    "Butterfly enjoying with nature.jpg",
    "Common Bluebottle Butterfly (33174063801).jpg",
    "Cat in Quebec city.jpg",
    "'Abstract landscape in Reds' - large painting on canvas in acryl paint, made in 1990 by Dutch artist Fons Heijnsbroek - CC0.jpg",
    "Aichi Prefectural Ceramic Museum 2018 (033).jpg",
    "Landscape with a Village in the Distance MET DP145939.jpg",
    "Flaming Star Nebula, IC 405.png",
    "Full moon in Sagittarius.jpg",
    "Far side of the Moon close up for Lunar Crater Radio Telescope.png",
    "August 2006, bicycle rental in Stockholm 3.jpg",
    "Brown Line Train Crossing Chicago River 2.jpg",
    "Bodrum Kalesi ve Yelkenliler 2015.jpg",
    "20220410 Florin sign and ij digraph on Dutch typewriter.jpg",
    "Computer motherboard 13.jpg",
    "Camera - Desk - Computer - Notepad - Life (Unsplash).jpg",
    "Judith Leyster, Self-Portrait, c. 1630, NGA 37003.jpg",
    "Antonello da Messina - Portrait of a Man (Il Condottiere) cleaned version.jpg",
    "Autumn Rosehip Berries in Białystok Forest.jpg",
    "Fruits in bowl oranges lime apples (1).jpg",
    "Vegan food in Madrid 2016.jpg",
]

CATEGORY_QUERIES: dict[str, list[str]] = {
    "nature": ["landscape", "mountain", "forest", "ocean", "waterfall", "desert", "clouds"],
    "plants": ["botanical", "flower", "tree", "leaf", "fruit", "vegetable", "garden"],
    "architecture": ["architecture", "building", "bridge", "interior", "street", "cityscape"],
    "wildlife": ["wild bird", "butterfly", "wildlife", "cat", "dog", "insect"],
    "plantFood": ["vegan food", "plant based food", "fruit bowl", "vegetables", "berries"],
    "art": ["abstract painting", "landscape painting", "sculpture", "ceramic", "textile art"],
    "astronomy": ["astronomy", "moon", "planet", "nebula", "night sky"],
    "mobility": ["bicycle", "train", "tram", "sailing ship", "civil aircraft"],
    "objects": ["camera", "book", "typewriter", "computer", "musical instrument", "tools"],
    "portraits": ["portrait painting", "historical portrait", "self portrait painting"],
}

# 标题、描述和分类中出现任一词时拒绝。这里有意宁可漏收，也不把伦理成本转嫁给用户。
DENY_TERMS = {
    "meat", "beef", "pork", "chicken", "turkey", "duck", "goose", "lamb", "mutton", "veal",
    "bacon", "ham", "sausage", "burger", "steak", "seafood", "fish dish", "fishing",
    "crab", "alimasag", "shrimp", "prawn", "lobster", "oyster", "mussel", "shellfish",
    "hunting", "hunt ", "hunter", "slaughter", "carcass", "dead animal", "taxidermy",
    "leather", "fur coat", "wool", "wool production", "dairy", "milk", "cheese", "egg dish",
    "honey", "zoo", "circus", "cage", "captivity", "aquarium", "animal show",
    "horse racing", "bullfight", "rodeo", "laboratory animal", "vivisection", "aquaculture",
    "weapon", "gun", "rifle", "pistol", "missile", "military", "warship", "tank ",
    "porn", "nude", "nudity", "erotic", "fetish", "lingerie", "underwear",
    "surgery", "wound", "injury", "blood", "corpse", "autopsy", "disease",
    "child portrait", "children portrait", "schoolchild", "minor portrait",
    "fast food", "foie gras", "animal product",
}

REQUIRED_KEYS = {
    "id", "title", "subtitle", "category", "sourceKind", "fileName", "bundledResourceName",
    "author", "license", "licenseURL", "sourcePageURL", "originalPixelWidth",
    "originalPixelHeight", "mimeType", "ethicalReview", "searchTerms",
}


PLANT_FOOD_RAW_TERMS = {
    "fruit", "fruits", "vegetable", "vegetables", "berries", "rosehip", "okra", "onion",
    "onions", "mushroom", "mushrooms", "chickpea", "chickpeas", "mung bean", "bean sprouts",
}
PLANT_FOOD_CONTEXT_DENY = {
    "restaurant", "food palace", "food", "foods", "cuisine", "home cooking", "cooking",
    "menu", "vendor", "museum", "dish", "salad", "breakfast", "burrito", "ramen", "cake",
    "toast", "dashi", "menudo", "nilaga", "sinigang", "tortang", "tamales",
    "drawing", "painting", "garland", "hairdress", "basket", "ceramic", "metal bowl",
    "living quarters", "canal", "priesthood", "society",
}


def contains_phrase(text: str, phrase: str) -> bool:
    pattern = r"(?<![a-z0-9])" + re.escape(phrase.casefold()).replace(r"\ ", r"\s+") + r"(?![a-z0-9])"
    return re.search(pattern, text.casefold()) is not None


def plant_food_admissible(title: str, description: str) -> bool:
    evidence = f"{title} {description}".casefold()
    if "vegan" in evidence:
        return any(
            contains_phrase(evidence, term)
            for term in PLANT_FOOD_RAW_TERMS | {"food", "breakfast", "burrito", "ramen", "salad", "cake"}
        )
    if any(contains_phrase(evidence, term) for term in PLANT_FOOD_CONTEXT_DENY):
        return False
    return any(contains_phrase(evidence, term) for term in PLANT_FOOD_RAW_TERMS)


CATEGORY_POSITIVE_TERMS: dict[str, set[str]] = {
    "nature": {"mountain", "forest", "ocean", "waterfall", "desert", "cloud", "landscape", "beach", "lake", "fog", "harbor", "river", "valley", "coast"},
    "plants": {"flower", "tree", "leaf", "plant", "botanical", "garden", "fruit", "vegetable", "forest", "blossom"},
    "architecture": {"architecture", "building", "bridge", "interior", "street", "cityscape", "cathedral", "church", "house", "tower", "station", "urban"},
    "wildlife": {"cat", "dog", "bird", "butterfly", "insect", "wildlife", "lynx", "bee", "beetle", "dragonfly", "animal"},
    "plantFood": PLANT_FOOD_RAW_TERMS | {"vegan", "salad", "breakfast", "burrito", "ramen", "sauerkraut"},
    "art": {"painting", "sculpture", "ceramic", "pottery", "drawing", "art", "textile", "weaving", "watercolor", "print"},
    "astronomy": {"astronomy", "moon", "lunar", "planet", "nebula", "star", "night sky", "eclipse", "telescope", "galaxy", "space"},
    "mobility": {"bicycle", "bike", "train", "tram", "ship", "sailing", "aircraft", "airplane", "rail", "ferry", "subway"},
    "objects": {"camera", "book", "typewriter", "computer", "instrument", "tool", "device", "motherboard", "keyboard", "notepad", "desk"},
    "portraits": {"portrait", "self-portrait", "self portrait"},
}

CATEGORY_DENY_TERMS: dict[str, set[str]] = {
    "wildlife": {"bird park", "animal park", "zoological", "petting zoo", "breed", "breeding", "coat genetics", "dog clothing", "animal locomotion"},
    "mobility": {"armed", "military", "defence", "defense", "fighter", "air force", "tanker", "warship"},
    "portraits": {"girl", "boy", "baby", "child", "children", "family portrait", "minor"},
    "plantFood": {"museo", "museum", "glass", "ceramic", "still life", "painting", "drawing", "sculpture"},
}


def category_relevant(category: str, text: str) -> bool:
    evidence = text.casefold()
    positive = CATEGORY_POSITIVE_TERMS.get(category, set())
    if positive and not any(contains_phrase(evidence, term) for term in positive):
        return False
    return not any(
        contains_phrase(evidence, term)
        for term in CATEGORY_DENY_TERMS.get(category, set())
    )

TAG_RE = re.compile(r"<[^>]+>")
SPACE_RE = re.compile(r"\s+")


def clean_text(value: str | None) -> str:
    if not value:
        return ""
    value = html.unescape(TAG_RE.sub(" ", value))
    return SPACE_RE.sub(" ", value).strip()


def slug(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    digest = hashlib.sha256(value.encode()).hexdigest()[:10]
    return f"{normalized[:54]}-{digest}" if normalized else digest


def request_json(url: str, cache_key: str) -> dict[str, Any]:
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_ROOT / f"{cache_key}.json"
    if cache_path.is_file():
        return json.loads(cache_path.read_text())
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                data = json.load(response)
            cache_path.write_text(json.dumps(data))
            return data
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 5:
                raise
            delay = int(error.headers.get("Retry-After", "0") or 0) or min(60, 4 * (attempt + 1))
            time.sleep(delay)
    raise RuntimeError("unreachable")


def api_query(params: dict[str, str]) -> dict[str, Any]:
    encoded = urllib.parse.urlencode(params)
    key = hashlib.sha256(encoded.encode()).hexdigest()
    return request_json(API + "?" + encoded, key)


def candidate_pages(query: str, limit: int = 100) -> list[dict[str, Any]]:
    data = api_query({
        "action": "query",
        "generator": "search",
        "gsrsearch": f'filetype:bitmap incategory:"CC-Zero" {query}',
        "gsrnamespace": "6",
        "gsrlimit": str(limit),
        "prop": "imageinfo|info|categories",
        "iiprop": "url|size|mime|extmetadata",
        "inprop": "url",
        "cllimit": "max",
        "format": "json",
        "formatversion": "2",
    })
    return data.get("query", {}).get("pages", [])


def rejected(text: str) -> bool:
    folded = text.casefold()
    for raw_term in DENY_TERMS:
        term = raw_term.strip().casefold()
        pattern = r"(?<![a-z0-9])" + re.escape(term).replace(r"\ ", r"\s+") + r"(?![a-z0-9])"
        if re.search(pattern, folded):
            return True
    return False


def record_from_page(page: dict[str, Any], category: str, query: str) -> dict[str, Any] | None:
    title = page.get("title", "")
    if not title.startswith("File:"):
        return None
    file_name = title.removeprefix("File:")
    extension = file_name.rsplit(".", 1)[-1].lower() if "." in file_name else ""
    if extension not in ALLOWED_EXTENSIONS:
        return None
    info = (page.get("imageinfo") or [{}])[0]
    width = info.get("width")
    height = info.get("height")
    mime = info.get("mime", "")
    metadata = info.get("extmetadata") or {}
    license_name = clean_text((metadata.get("LicenseShortName") or {}).get("value"))
    if license_name not in ALLOWED_LICENSES:
        return None
    if not isinstance(width, int) or not isinstance(height, int) or width < 320 or height < 240:
        return None
    if not mime.startswith("image/"):
        return None

    description = clean_text((metadata.get("ImageDescription") or {}).get("value"))
    categories = " ".join(item.get("title", "") for item in page.get("categories", []))
    combined = " ".join((file_name, description, categories, query))
    if rejected(combined):
        return None
    if category == "plantFood" and not plant_food_admissible(file_name, description):
        return None
    if not category_relevant(category, " ".join((file_name, description, categories))):
        return None

    author = clean_text((metadata.get("Artist") or {}).get("value")) or "Wikimedia Commons contributor"
    author = author[:180]
    usage_terms = clean_text((metadata.get("UsageTerms") or {}).get("value"))
    license_url = clean_text((metadata.get("LicenseUrl") or {}).get("value")).replace(
        "http://creativecommons.org", "https://creativecommons.org"
    )
    canonical_url = page.get("canonicalurl") or (
        "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"), safe=":_()")
    )
    display_title = clean_text(file_name.rsplit(".", 1)[0].replace("_", " "))[:120]
    if not display_title:
        return None

    return {
        "id": f"remote-{slug(file_name)}",
        "title": display_title,
        "subtitle": description[:220] or f"来自 Wikimedia Commons 的真实{category}图片。",
        "category": category,
        "sourceKind": "remote",
        "fileName": file_name,
        "bundledResourceName": None,
        "author": author,
        "license": usage_terms or license_name,
        "licenseURL": license_url or "https://creativecommons.org/publicdomain/zero/1.0/",
        "sourcePageURL": canonical_url,
        "originalPixelWidth": width,
        "originalPixelHeight": height,
        "mimeType": mime,
        "ethicalReview": "许可已验证；拒绝动物利用、动物性食物、暴力、色情、医疗创伤与未成年人可识别肖像。",
        "searchTerms": sorted({query, category, display_title.casefold()}),
    }


def collect_remote() -> list[dict[str, Any]]:
    per_category = TARGET_REMOTE_COUNT // len(CATEGORY_QUERIES)
    requests = [(category, query) for category, queries in CATEGORY_QUERIES.items() for query in queries]
    pages_by_request: dict[tuple[str, str], list[dict[str, Any]]] = {}
    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {
            executor.submit(candidate_pages, query): (category, query)
            for category, query in requests
        }
        for future in as_completed(futures):
            category, query = futures[future]
            pages_by_request[(category, query)] = future.result()
            print(f"fetched {category}: {query}", file=sys.stderr)

    output: list[dict[str, Any]] = []
    globally_selected: set[str] = set()
    for category, queries in CATEGORY_QUERIES.items():
        candidates_by_file: dict[str, dict[str, Any]] = {}
        for query in queries:
            for page in pages_by_request.get((category, query), []):
                record = record_from_page(page, category, query)
                if record is None or record["fileName"] in globally_selected:
                    continue
                candidates_by_file.setdefault(record["fileName"], record)
        candidates = list(candidates_by_file.values())
        candidates.sort(key=lambda item: hashlib.sha256(item["fileName"].encode()).hexdigest())
        selected = candidates[:per_category]
        globally_selected.update(item["fileName"] for item in selected)
        if len(selected) < per_category:
            print(f"warning: {category} only produced {len(selected)} entries", file=sys.stderr)
        output.extend(selected)
    output.sort(key=lambda item: (item["category"], item["id"]))
    return output


def thumbnail_urls(file_names: list[str], width: int = 640) -> dict[str, str]:
    result: dict[str, str] = {}
    for offset in range(0, len(file_names), 40):
        batch = file_names[offset:offset + 40]
        data = api_query({
            "action": "query",
            "titles": "|".join(f"File:{name}" for name in batch),
            "prop": "imageinfo",
            "iiprop": "url",
            "iiurlwidth": str(width),
            "format": "json",
            "formatversion": "2",
        })
        for page in data.get("query", {}).get("pages", []):
            title = page.get("title", "").removeprefix("File:")
            info = (page.get("imageinfo") or [{}])[0]
            url = info.get("thumburl") or info.get("url")
            if title and url:
                result[title] = url
    return result


def download_one_local(
    index: int,
    item: dict[str, Any],
    source_url: str,
) -> tuple[int, dict[str, Any], str, bytes, str] | None:
    request = urllib.request.Request(source_url, headers={"User-Agent": USER_AGENT})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                payload = response.read(4 * 1024 * 1024 + 1)
                content_type = response.headers.get_content_type()
            extensions = {
                "image/jpeg": "jpg",
                "image/png": "png",
                "image/webp": "webp",
            }
            extension = extensions.get(content_type)
            if len(payload) > 4 * 1024 * 1024 or extension is None:
                return None
            resource_name = f"local-{index:03d}-{slug(item['fileName'])}.{extension}"
            return (
                index,
                item,
                resource_name,
                sanitize_image_metadata(payload),
                content_type,
            )
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 5:
                print(f"warning: local download failed for {item['fileName']}: {error}", file=sys.stderr)
                return None
            delay = int(error.headers.get("Retry-After", "0") or 0) or min(90, 8 * (attempt + 1))
            time.sleep(delay)
        except OSError as error:
            if attempt == 5:
                print(f"warning: local download failed for {item['fileName']}: {error}", file=sys.stderr)
                return None
            time.sleep(3 * (attempt + 1))
    return None


def download_local(remote: list[dict[str, Any]]) -> list[dict[str, Any]]:
    LOCAL_ROOT.mkdir(parents=True, exist_ok=True)
    for path in LOCAL_ROOT.glob("*"):
        if path.is_file():
            path.unlink()

    remote_by_file = {item["fileName"]: item for item in remote}
    missing = [name for name in CURATED_LOCAL_FILE_NAMES if name not in remote_by_file]
    if missing:
        raise ValueError(f"curated local assets disappeared from remote catalog: {missing}")
    chosen = [remote_by_file[name] for name in CURATED_LOCAL_FILE_NAMES]

    urls = thumbnail_urls([item["fileName"] for item in chosen])
    completed: list[tuple[int, dict[str, Any], str, bytes, str]] = []
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [
            executor.submit(download_one_local, index, item, urls[item["fileName"]])
            for index, item in enumerate(chosen)
            if item["fileName"] in urls
        ]
        for future in as_completed(futures):
            try:
                value = future.result()
            except Exception as error:
                print(f"warning: local download task failed: {error}", file=sys.stderr)
                continue
            if value is not None:
                completed.append(value)

    local: list[dict[str, Any]] = []
    for index, item, resource_name, payload, content_type in sorted(completed):
        (LOCAL_ROOT / resource_name).write_bytes(payload)
        copy = dict(item)
        copy.update({
            "id": item["id"].replace("remote-", "local-", 1),
            "sourceKind": "bundled",
            "bundledResourceName": resource_name,
            "mimeType": content_type,
            "subtitle": "随 App 打包的真实离线图片；来源、作者与许可仍可追溯。",
            "searchTerms": sorted(set(item["searchTerms"] + ["local", "offline", "bundled"])),
        })
        local.append(copy)
    return local


def validate(catalog: dict[str, Any]) -> None:
    if catalog.get("schemaVersion") != 1:
        raise ValueError("schemaVersion must equal 1")
    assets = catalog.get("assets")
    if not isinstance(assets, list) or len(assets) < 300:
        raise ValueError("catalog must contain at least 300 real assets")
    ids: set[str] = set()
    local_count = 0
    for index, asset in enumerate(assets):
        if set(asset) != REQUIRED_KEYS:
            raise ValueError(f"asset[{index}] fields differ from schema")
        if asset["id"] in ids:
            raise ValueError(f"duplicate id: {asset['id']}")
        ids.add(asset["id"])
        if asset["license"] not in {"CC0", "CC0 1.0", "Public domain", "PDM"} and "public" not in asset["license"].casefold():
            raise ValueError(f"unsupported license: {asset['license']}")
        review_text = " ".join(str(value) for value in asset.values())
        if rejected(review_text):
            raise ValueError(f"ethical deny term found in {asset['id']}")
        if not category_relevant(asset["category"], review_text):
            raise ValueError(f"category relevance failed for {asset['id']}")
        if asset["sourceKind"] == "bundled":
            local_count += 1
            resource = LOCAL_ROOT / asset["bundledResourceName"]
            if not resource.is_file() or resource.stat().st_size == 0:
                raise ValueError(f"missing bundled resource: {resource}")
            payload = resource.read_bytes()
            expected = {
                "image/jpeg": (".jpg", payload.startswith(b"\xff\xd8\xff")),
                "image/png": (".png", payload.startswith(b"\x89PNG\r\n\x1a\n")),
                "image/webp": (".webp", payload.startswith(b"RIFF") and payload[8:12] == b"WEBP"),
            }.get(asset["mimeType"])
            if expected is None or resource.suffix.lower() != expected[0] or not expected[1]:
                raise ValueError(f"bundled extension/magic/MIME mismatch: {asset['id']}")
            if contains_sensitive_image_metadata(payload):
                raise ValueError(f"bundled resource retains EXIF/XMP/IPTC metadata: {asset['id']}")
        elif asset["sourceKind"] != "remote":
            raise ValueError(f"unsupported sourceKind: {asset['sourceKind']}")
    if local_count < 16:
        raise ValueError("catalog must contain at least 16 bundled real images")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--generate", action="store_true")
    args = parser.parse_args()
    if args.generate:
        remote = collect_remote()
        local = download_local(remote)
        catalog = {
            "schemaVersion": 1,
            "source": "Wikimedia Commons",
            "policy": "CC0/public-domain only with animal-ethics and sensitive-content filtering",
            "assets": local + remote,
        }
        RESOURCE_ROOT.mkdir(parents=True, exist_ok=True)
        CATALOG_PATH.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print(f"generated {len(remote)} remote + {len(local)} bundled assets")
    if args.validate or not args.generate:
        validate(json.loads(CATALOG_PATH.read_text()))
        print(f"validated {len(json.loads(CATALOG_PATH.read_text())['assets'])} assets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
