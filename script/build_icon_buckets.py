#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "aiodns>=3.2",
#   "aiohttp>=3.11",
#   "boto3>=1.35",
#   "curl-cffi>=0.10",
#   "pillow>=11.0",
#   "resvg-py>=0.5",
# ]
# ///
# Written by AI on 2026.11.26 by model gemini-4-neon.
"""Build and upload k-anonymous static hash-prefix site icon buckets (AKIC v1).

Corpus:
  - Chrome UX Report (CrUX) Global Top 1M + regional CrUX lists
  - Tranco Top 1M
  - Canonicalized to PSL eTLD+1 (excluding IPs and private/local suffixes)

Format:
  - 14-bit SHA-256 prefix -> 16,384 static files (`0000.bin`..`3fff.bin`)
  - Each file is an AKIC binary pack of sorted (domain -> 64x64 RGBA WebP)
  - Designed for zero-leak client lookups via GET /icons/v1/<prefix>.bin
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import concurrent.futures
import csv
import gzip
import hashlib
import io
import json
import multiprocessing as mp
import os
import re
import resource
import sqlite3
import struct
import sys
import time
import urllib.parse
import urllib.request
import warnings
import zipfile
import zlib

warnings.filterwarnings("ignore", category=UserWarning)
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable

import aiohttp
from curl_cffi.requests import AsyncSession
from PIL import Image
import resvg_py

PREFIX_BITS = 14
BUCKET_COUNT = 1 << PREFIX_BITS  # 16,384
PSL_URL = "https://publicsuffix.org/list/public_suffix_list.dat"
CRUX_GLOBAL_URL = "https://raw.githubusercontent.com/zakird/crux-top-lists/main/data/global/current.csv.gz"
CRUX_COUNTRY_API = "https://api.github.com/repos/zakird/crux-top-lists/contents/data/country/{cc}"
CRUX_COUNTRY_RAW = "https://raw.githubusercontent.com/zakird/crux-top-lists/main/data/country/{cc}/{file}"
TRANCO_URL = "https://tranco-list.eu/top-1m.csv.zip"

DEFAULT_COUNTRIES = "us,gb,nl,de,fr,ca,au"

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
    ),
    "Accept": "text/html,application/xhtml+xml,image/webp,image/png,image/*;q=0.8,*/*;q=0.5",
    "Accept-Language": "en-US,en;q=0.9",
}

LINK_RE = re.compile(r"<link\b[^>]*rel=[\"']?[^\"']*icon[^\"']*[\"']?[^>]*>", re.I)
HREF_RE = re.compile(r"href=[\"']([^\"']+)[\"']", re.I)
SIZES_RE = re.compile(r"sizes=[\"'](\d+)x(\d+)[\"']", re.I)
WAF_STATUSES = {403, 406, 429, 503, 520, 521, 522, 523, 524, 525, 526}
WAF_MARKERS = (
    b"just a moment",
    b"cf-browser-verification",
    b"attention required! | cloudflare",
    b"_incapsula_resource",
    b"datadome",
    b"access denied",
    b"akamai",
    b"px-captcha",
)

# Guaranteed offline-fallback domains (also used by design previews and unit tests)
CORE_BUNDLED_DOMAINS = (
    "github.com", "cloudflare.com", "aws.amazon.com", "amazon.com", "openai.com",
    "chatgpt.com", "claude.ai", "cursor.com", "vercel.com", "linear.app", "notion.so",
    "stripe.com", "figma.com", "docker.com", "huggingface.co", "elevenlabs.io",
    "youtube.com", "instagram.com", "reddit.com", "x.com", "linkedin.com", "discord.com",
    "google.com", "mail.google.com", "cloud.google.com", "outlook.live.com", "slack.com",
    "zoom.us", "ebay.com", "aliexpress.com", "ikea.com", "deliveroo.co.uk", "wise.com",
    "revolut.com", "coinbase.com", "wikipedia.org", "apple.com", "icloud.com",
    "microsoft.com", "netflix.com", "spotify.com", "paypal.com", "airbnb.com",
    "booking.com", "uber.com", "dropbox.com", "1password.com", "bitwarden.com",
    "tailscale.com", "supabase.com", "netlify.com", "heroku.com", "gitlab.com",
    "bitbucket.org", "npmjs.com", "pypi.org", "stackoverflow.com", "medium.com",
    "substack.com", "shopify.com", "twilio.com", "sentry.io", "datadoghq.com",
    "postman.com", "raycast.com", "arc.net", "proton.me", "fastmail.com",
    "barclays.co.uk", "hsbc.co.uk", "monzo.com", "chase.com", "amex.com",
    "zalando.com", "bol.com", "coolblue.nl", "ah.nl", "ing.nl", "rabobank.nl",
    "abnamro.nl", "degiro.nl", "anwb.nl", "ns.nl", "kpn.com", "bunq.com", "gov.uk",
)


# MARK: - Public Suffix List & Canonicalization

class PublicSuffixList:
    def __init__(self, path: Path) -> None:
        self.exact: set[str] = set()
        self.wildcard: set[str] = set()
        self.exception: set[str] = set()
        self.clean_lines: list[str] = []
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip().lower()
                if not line or line.startswith("//"):
                    continue
                self.clean_lines.append(line)
                if line.startswith("!"):
                    self.exception.add(line[1:])
                elif line.startswith("*."):
                    self.wildcard.add(line[2:])
                else:
                    self.exact.add(line)

    @staticmethod
    def is_private_or_ip(host: str) -> bool:
        if not host or "." not in host or host == "localhost":
            return True
        if host.endswith((".local", ".lan", ".internal", ".ts.net", ".home", ".arpa")):
            return True
        if ":" in host or re.fullmatch(r"\d+\.\d+\.\d+\.\d+", host):
            return True
        return False

    @staticmethod
    def normalise(raw_host: str) -> str:
        t = raw_host.strip().lower()
        if not t:
            return ""
        cand = t if "://" in t else "https://" + t
        try:
            h = (urllib.parse.urlparse(cand).hostname or t).lower().rstrip(".")
        except ValueError:
            return ""
        return h[4:] if h.startswith("www.") else h

    def etld1(self, raw_host: str) -> str:
        host = self.normalise(raw_host)
        if self.is_private_or_ip(host):
            return ""
        parts = host.split(".")
        best_len = 1
        for i in range(len(parts)):
            sub = ".".join(parts[i:])
            if sub in self.exception:
                best_len = len(parts) - i - 1
                break
            if sub in self.exact:
                best_len = max(best_len, len(parts) - i)
                break
            if i + 1 < len(parts) and ".".join(parts[i + 1 :]) in self.wildcard:
                best_len = max(best_len, len(parts) - i)
                break
        if len(parts) <= best_len:
            return ""
        return ".".join(parts[-(best_len + 1) :])

    def write_compressed(self, out_path: Path) -> int:
        payload = ("\n".join(self.clean_lines) + "\n").encode("utf-8")
        compressed = zlib.compress(payload, level=9)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(compressed)
        return len(compressed)


def bucket_id(domain: str) -> str:
    digest = hashlib.sha256(domain.encode("utf-8")).digest()
    val = ((digest[0] << 8) | digest[1]) >> (16 - PREFIX_BITS)
    return f"{val:04x}"


# MARK: - Icon Decoding & Normalization

def rasterize_svg(svg_bytes: bytes) -> bytes | None:
    if not svg_bytes or len(svg_bytes) > 512_000:
        return None
    try:
        text = svg_bytes.decode("utf-8", "ignore")
        if "<svg" not in text.lower():
            return None
        png_bytes = resvg_py.svg_to_bytes(svg_string=text, width=64, height=64)
        im = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
        if im.width < 12 or im.height < 12:
            return None
        if im.width > 64 or im.height > 64:
            im.thumbnail((64, 64), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format="WEBP", quality=82, method=4)
        return buf.getvalue()
    except Exception:
        return None


def normalize_icon(data: bytes, content_type: str = "", url: str = "") -> bytes | None:
    if not data or len(data) < 32:
        return None
    head = data[:256].lstrip().lower()
    if b"<svg" in head or "svg" in content_type.lower() or url.lower().split("?")[0].endswith(".svg"):
        return rasterize_svg(data)
    if head.startswith((b"<!doctype", b"<html")):
        return None
    try:
        im = Image.open(io.BytesIO(data))
        im.load()
        if getattr(im, "format", None) == "ICO" and hasattr(im, "ico") and im.ico:
            best = max(im.ico.sizes(), key=lambda s: s[0] * s[1])
            im = im.ico.getimage(best)
        if im.width < 12 or im.height < 12:
            return None
        im = im.convert("RGBA")
        if im.width > 64 or im.height > 64:
            im.thumbnail((64, 64), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format="WEBP", quality=82, method=4)
        return buf.getvalue()
    except Exception:
        return None


def rank_link_tag(tag: str, href: str) -> int:
    tl, hl = tag.lower(), href.lower()
    score = 10
    if "apple-touch-icon" in tl:
        score += 40
    m = SIZES_RE.search(tag)
    if m:
        sz = int(m.group(1))
        if 48 <= sz <= 256:
            score += 35
        elif sz > 256:
            score += 25
        elif sz >= 32:
            score += 20
    if ".svg" in hl or "svg" in tl:
        score += 30
    elif ".png" in hl or ".webp" in hl:
        score += 15
    elif ".ico" in hl:
        score += 5
    return score


def extract_html_icon_candidates(html: str, final_base: str) -> tuple[bytes | None, list[str]]:
    cands: list[tuple[int, str]] = []
    for m in LINK_RE.finditer(html):
        tag = m.group(0)
        hm = HREF_RE.search(tag)
        if not hm:
            continue
        href = hm.group(1).strip()
        if not href:
            continue
        if href.startswith("data:image/svg+xml"):
            try:
                if ";base64," in href:
                    raw = base64.b64decode(href.split(";base64,", 1)[1])
                else:
                    raw = urllib.parse.unquote(href.split(",", 1)[1]).encode("utf-8")
                webp = rasterize_svg(raw)
                if webp:
                    return webp, []
            except Exception:
                pass
            continue
        if href.startswith("data:"):
            continue
        cands.append((rank_link_tag(tag, href), urllib.parse.urljoin(final_base, href)))
    cands.sort(key=lambda x: -x[0])
    seen: set[str] = set()
    urls: list[str] = []
    for _, u in cands:
        if u not in seen:
            seen.add(u)
            urls.append(u)
            if len(urls) >= 3:
                break
    return None, urls


def looks_like_waf(status: int, headers: dict[str, str], body_prefix: bytes) -> bool:
    if status in WAF_STATUSES:
        return True
    if headers.get("cf-mitigated", "").lower() == "challenge":
        return True
    low = body_prefix[:2048].lower()
    return any(m in low for m in WAF_MARKERS)


# MARK: - Stage 1 (Fast aiohttp) & Stage 2 (curl_cffi WAF recovery)

def open_shard_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS icons (
            domain TEXT PRIMARY KEY,
            status INTEGER NOT NULL,
            source TEXT NOT NULL,
            webp BLOB
        )
        """
    )
    con.commit()
    return con


async def aiohttp_try_icon(session: aiohttp.ClientSession, url: str) -> tuple[bytes | None, bool]:
    try:
        async with session.get(url, allow_redirects=True) as r:
            if r.status == 200:
                ct = r.headers.get("Content-Type", "")
                data = await r.content.read(300_000)
                return normalize_icon(data, ct, str(r.url)), False
            return None, r.status in WAF_STATUSES
    except Exception:
        return None, False


async def aiohttp_crawl_one(session: aiohttp.ClientSession, dom: str, origin: str) -> tuple[int, str, bytes | None]:
    waf_seen = False
    bases = [origin]
    alt = f"https://www.{dom}" if not origin.startswith(f"https://www.{dom}") else f"https://{dom}"
    if alt not in bases:
        bases.append(alt)

    for idx, base in enumerate(bases):
        try:
            async with session.get(base + "/", allow_redirects=True) as resp:
                ct = (resp.headers.get("Content-Type") or "").lower()
                if resp.status == 200 and "html" in ct:
                    raw = await resp.content.read(65_536)
                    if looks_like_waf(resp.status, dict(resp.headers), raw):
                        waf_seen = True
                        break
                    html = raw.decode("utf-8", "ignore")
                    final_base = str(resp.url)
                    inline_webp, urls = extract_html_icon_candidates(html, final_base)
                    if inline_webp:
                        return 1, "inline-svg", inline_webp
                    for u in urls[:2]:
                        webp, w = await aiohttp_try_icon(session, u)
                        waf_seen = waf_seen or w
                        if webp:
                            return 1, "html", webp
                    pu = urllib.parse.urlparse(final_base)
                    root = f"{pu.scheme}://{pu.netloc}"
                    for path in ("/favicon.ico", "/apple-touch-icon.png"):
                        webp, w = await aiohttp_try_icon(session, root + path)
                        waf_seen = waf_seen or w
                        if webp:
                            return 1, path, webp
                    return (2 if waf_seen else 0), ("waf" if waf_seen else "miss"), None
                elif resp.status in WAF_STATUSES:
                    waf_seen = True
                    break
        except Exception:
            if idx == 0:
                continue
            break

    # Direct /favicon.ico fallback (often succeeds even when homepage 403s or redirects)
    webp, w = await aiohttp_try_icon(session, bases[0] + "/favicon.ico")
    waf_seen = waf_seen or w
    if webp:
        return 1, "direct/favicon.ico", webp

    return (2 if waf_seen else 0), ("waf" if waf_seen else "miss"), None


async def cffi_try_icon(session: AsyncSession, url: str) -> bytes | None:
    try:
        r = await session.get(url, allow_redirects=True, timeout=6)
        if r.status_code == 200:
            ct = r.headers.get("content-type", "")
            return normalize_icon(r.content[:350_000], ct, str(r.url))
    except Exception:
        pass
    return None


async def cffi_crawl_one(session: AsyncSession, dom: str, origin: str) -> tuple[int, str, bytes | None]:
    bases = [origin]
    if f"https://{dom}" not in bases:
        bases.append(f"https://{dom}")
    if f"https://www.{dom}" not in bases:
        bases.append(f"https://www.{dom}")

    for base in bases[:2]:
        try:
            r = await session.get(base + "/", allow_redirects=True, timeout=7)
            if r.status_code == 200 and "html" in (r.headers.get("content-type") or "").lower():
                html = r.text[:100_000]
                final_base = str(r.url)
                inline_webp, urls = extract_html_icon_candidates(html, final_base)
                if inline_webp:
                    return 1, "cffi-inline-svg", inline_webp
                for u in urls:
                    webp = await cffi_try_icon(session, u)
                    if webp:
                        return 1, "cffi-html", webp
                pu = urllib.parse.urlparse(final_base)
                root = f"{pu.scheme}://{pu.netloc}"
                for path in ("/apple-touch-icon.png", "/favicon.ico", "/favicon.svg"):
                    webp = await cffi_try_icon(session, root + path)
                    if webp:
                        return 1, f"cffi{path}", webp
                break
        except Exception:
            pass

    for base in bases[:2]:
        for path in ("/favicon.ico", "/apple-touch-icon.png", "/favicon.svg"):
            webp = await cffi_try_icon(session, base + path)
            if webp:
                return 1, f"cffi-direct{path}", webp

    return 0, "cffi-miss", None


def worker_process(args_tuple: tuple) -> dict:
    worker_idx, items, shard_path_str, concurrency, waf_concurrency, waf_rank_cutoff, skip_waf = args_tuple
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        target = min(8192, hard if hard != resource.RLIM_INFINITY else 8192)
        if soft < target:
            resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except Exception:
        pass

    shard_path = Path(shard_path_str)
    con = open_shard_db(shard_path)
    existing = {row[0]: row[1] for row in con.execute("SELECT domain, status FROM icons")}

    todo_stage1 = [(d, o, rk) for d, o, rk in items if d not in existing]
    origin_map = {d: o for d, o, _ in items}
    rank_map = {d: rk for d, _, rk in items}

    async def run_stage1() -> tuple[int, int, int]:
        if not todo_stage1:
            return 0, 0, 0
        t0 = time.time()
        timeout = aiohttp.ClientTimeout(total=4.0, connect=2.0)
        resolver = aiohttp.AsyncResolver(nameservers=["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        conn = aiohttp.TCPConnector(
            limit=concurrency,
            resolver=resolver,
            ttl_dns_cache=600,
            ssl=False,
            enable_cleanup_closed=True,
        )
        hits = wafs = done = 0
        pending_rows: list[tuple[str, int, str, bytes | None]] = []
        queue: asyncio.Queue[tuple[str, str] | None] = asyncio.Queue(maxsize=concurrency * 2)

        async def producer():
            for d, o, _ in todo_stage1:
                await queue.put((d, o))
            for _ in range(concurrency):
                await queue.put(None)

        async def consumer(session: aiohttp.ClientSession):
            nonlocal hits, wafs, done
            while True:
                item = await queue.get()
                if item is None:
                    queue.task_done()
                    return
                d, o = item
                try:
                    st, src, webp = await asyncio.wait_for(aiohttp_crawl_one(session, d, o), timeout=6.0)
                except Exception:
                    st, src, webp = (0, "timeout", None)
                done += 1
                if st == 1:
                    hits += 1
                elif st == 2:
                    wafs += 1
                pending_rows.append((d, st, src, webp))
                if len(pending_rows) >= 500:
                    batch = pending_rows[:]
                    pending_rows.clear()
                    con.executemany(
                        "INSERT OR REPLACE INTO icons(domain, status, source, webp) VALUES (?, ?, ?, ?)",
                        batch,
                    )
                    con.commit()
                if (worker_idx == 0 and done % 5000 == 0) or done == len(todo_stage1):
                    dt = max(0.01, time.time() - t0)
                    print(
                        f"[w{worker_idx} stage1] {done:,}/{len(todo_stage1):,} "
                        f"({done/dt:.1f}/s) hits={hits:,} ({100*hits/max(1,done):.1f}%) waf={wafs:,}",
                        flush=True,
                    )
                queue.task_done()

        async with aiohttp.ClientSession(
            timeout=timeout,
            connector=conn,
            headers=HEADERS,
            cookie_jar=aiohttp.DummyCookieJar(),
        ) as session:
            prod = asyncio.create_task(producer())
            workers = [asyncio.create_task(consumer(session)) for _ in range(concurrency)]
            await prod
            await asyncio.gather(*workers)

        if pending_rows:
            con.executemany(
                "INSERT OR REPLACE INTO icons(domain, status, source, webp) VALUES (?, ?, ?, ?)",
                pending_rows,
            )
            con.commit()
        return done, hits, wafs

    async def run_stage2() -> tuple[int, int]:
        if skip_waf:
            return 0, 0
        rows = list(con.execute("SELECT domain, status FROM icons WHERE status IN (0, 2)"))
        todo_stage2 = [
            (d, origin_map[d])
            for d, st in rows
            if d in origin_map and (st == 2 or rank_map.get(d, 10**9) <= waf_rank_cutoff)
        ]
        if not todo_stage2:
            return 0, 0
        t0 = time.time()
        done = recovered = 0
        pending_rows: list[tuple[str, int, str, bytes | None]] = []
        queue: asyncio.Queue[tuple[str, str] | None] = asyncio.Queue(maxsize=waf_concurrency * 4)

        async def producer():
            for item in todo_stage2:
                await queue.put(item)
            for _ in range(waf_concurrency):
                await queue.put(None)

        async def consumer(session: AsyncSession):
            nonlocal done, recovered
            while True:
                item = await queue.get()
                if item is None:
                    queue.task_done()
                    return
                d, o = item
                try:
                    st, src, webp = await asyncio.wait_for(cffi_crawl_one(session, d, o), timeout=11.0)
                except Exception:
                    st, src, webp = (0, "cffi-timeout", None)
                done += 1
                if st == 1:
                    recovered += 1
                pending_rows.append((d, st, src, webp))
                if len(pending_rows) >= 250:
                    batch = pending_rows[:]
                    pending_rows.clear()
                    con.executemany(
                        "INSERT OR REPLACE INTO icons(domain, status, source, webp) VALUES (?, ?, ?, ?)",
                        batch,
                    )
                    con.commit()
                if (worker_idx == 0 and done % 1000 == 0) or done == len(todo_stage2):
                    dt = max(0.01, time.time() - t0)
                    print(
                        f"[w{worker_idx} stage2-waf] {done:,}/{len(todo_stage2):,} "
                        f"({done/dt:.1f}/s) recovered={recovered:,}",
                        flush=True,
                    )
                queue.task_done()

        async with AsyncSession(impersonate="chrome", verify=False) as session:
            prod = asyncio.create_task(producer())
            workers = [asyncio.create_task(consumer(session)) for _ in range(waf_concurrency)]
            await prod
            await asyncio.gather(*workers)

        if pending_rows:
            con.executemany(
                "INSERT OR REPLACE INTO icons(domain, status, source, webp) VALUES (?, ?, ?, ?)",
                pending_rows,
            )
            con.commit()
        return done, recovered

    s1_done, s1_hits, s1_waf = asyncio.run(run_stage1())
    s2_done, s2_rec = asyncio.run(run_stage2())
    total_hits = con.execute("SELECT COUNT(*) FROM icons WHERE status = 1").fetchone()[0]
    con.close()
    return {
        "worker": worker_idx,
        "stage1_done": s1_done,
        "stage1_hits": s1_hits,
        "stage1_waf": s1_waf,
        "stage2_done": s2_done,
        "stage2_recovered": s2_rec,
        "total_hits": total_hits,
    }


# MARK: - Corpus Download & Packing

def download_if_missing(url: str, dest: Path) -> bool:
    if dest.exists() and dest.stat().st_size > 0:
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "agent-keyring-icon-builder/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            tmp = dest.with_suffix(dest.suffix + ".tmp")
            tmp.write_bytes(resp.read())
            tmp.replace(dest)
        return True
    except Exception as e:
        print(f"WARN: failed to download {url}: {e}", file=sys.stderr)
        return False


def latest_crux_country_file(cc: str) -> str:
    req = urllib.request.Request(
        CRUX_COUNTRY_API.format(cc=cc),
        headers={"User-Agent": "agent-keyring-icon-builder/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            items = json.loads(resp.read().decode("utf-8"))
            csvs = sorted(x["name"] for x in items if x["name"].endswith(".csv.gz"))
            if csvs:
                return csvs[-1]
    except Exception:
        pass
    return "202610.csv.gz"


def load_corpus(work_dir: Path, countries: list[str], psl: PublicSuffixList, limit: int | None) -> list[tuple[str, str, int]]:
    dl_dir = work_dir / "downloads"
    download_if_missing(CRUX_GLOBAL_URL, dl_dir / "crux-global.csv.gz")
    download_if_missing(TRANCO_URL, dl_dir / "tranco-1m.csv.zip")

    for cc in countries:
        cc = cc.strip().lower()
        if not cc:
            continue
        dest = dl_dir / f"crux-{cc}.csv.gz"
        if not dest.exists():
            fname = latest_crux_country_file(cc)
            download_if_missing(CRUX_COUNTRY_RAW.format(cc=cc, file=fname), dest)

    # domain -> (preferred_origin, best_rank)
    corpus: dict[str, tuple[str, int]] = {}

    def add_domain(dom: str, origin: str, rank: int) -> None:
        if not dom:
            return
        prev = corpus.get(dom)
        if prev is None:
            corpus[dom] = (origin, rank)
        elif rank < prev[1]:
            corpus[dom] = (origin, rank)

    # Core guaranteed domains at rank 1
    for d in CORE_BUNDLED_DOMAINS:
        e = psl.etld1(d)
        if e:
            add_domain(e, f"https://{e}", 1)
        if d != e and d:
            # Also keep explicit subdomain origins where needed (mail.google.com, aws.amazon.com)
            pass

    # CrUX Global
    global_path = dl_dir / "crux-global.csv.gz"
    if global_path.exists():
        with gzip.open(global_path, "rt", encoding="utf-8") as f:
            r = csv.reader(f)
            next(r, None)
            for row in r:
                if len(row) < 2:
                    continue
                e = psl.etld1(row[0])
                add_domain(e, row[0], int(row[1]))

    # CrUX Countries
    for cc in countries:
        p = dl_dir / f"crux-{cc.strip().lower()}.csv.gz"
        if not p.exists():
            continue
        with gzip.open(p, "rt", encoding="utf-8") as f:
            r = csv.reader(f)
            next(r, None)
            for row in r:
                if len(row) < 2:
                    continue
                e = psl.etld1(row[0])
                # Slight offset so global rank takes precedence on ties
                add_domain(e, row[0], int(row[1]) + 500)

    # Tranco 1M
    tranco_path = dl_dir / "tranco-1m.csv.zip"
    if tranco_path.exists():
        with zipfile.ZipFile(tranco_path) as zf:
            with zf.open(zf.namelist()[0]) as f:
                for line in io.TextIOWrapper(f, encoding="utf-8"):
                    parts = line.strip().split(",")
                    if len(parts) >= 2:
                        rk = int(parts[0])
                        e = psl.etld1(parts[1])
                        add_domain(e, f"https://{e}", rk + 1000)

    ordered = sorted(((d, o, rk) for d, (o, rk) in corpus.items()), key=lambda x: (x[2], x[0]))
    if limit is not None:
        ordered = ordered[:limit]
    return ordered


def pack_akic(entries: Iterable[tuple[str, bytes]]) -> bytes:
    sorted_entries = sorted(entries, key=lambda x: x[0])
    index_buf = bytearray()
    data_buf = bytearray()
    for dom, blob in sorted_entries:
        db = dom.encode("utf-8")
        index_buf += struct.pack("<H", len(db)) + db + struct.pack("<II", len(data_buf), len(blob))
        data_buf += blob
    return struct.pack("<4sII", b"AKIC", len(sorted_entries), len(index_buf)) + bytes(index_buf) + bytes(data_buf)


def pack_buckets(work_dir: Path, corpus_ranks: dict[str, int], bundled_out: Path | None, bundled_limit: int) -> dict:
    shards_dir = work_dir / "shards"
    buckets_dir = work_dir / "buckets_v1"
    buckets_dir.mkdir(parents=True, exist_ok=True)

    by_bucket: dict[str, list[tuple[str, bytes]]] = defaultdict(list)
    all_hits_ranked: list[tuple[int, str, bytes]] = []
    source_counts: Counter[str] = Counter()
    total_icons = 0

    for shard in sorted(shards_dir.glob("worker_*.sqlite")):
        con = sqlite3.connect(str(shard))
        for dom, src, webp in con.execute("SELECT domain, source, webp FROM icons WHERE status = 1 AND webp IS NOT NULL"):
            by_bucket[bucket_id(dom)].append((dom, webp))
            source_counts[src] += 1
            total_icons += 1
            if bundled_out is not None:
                rk = 0 if dom in CORE_BUNDLED_DOMAINS else corpus_ranks.get(dom, 10**9)
                if rk <= 25_000:
                    all_hits_ranked.append((rk, dom, webp))
        con.close()

    total_bytes = 0
    non_empty = 0
    for idx in range(BUCKET_COUNT):
        bid = f"{idx:04x}"
        entries = by_bucket.get(bid, [])
        raw = pack_akic(entries)
        (buckets_dir / f"{bid}.bin").write_bytes(raw)
        total_bytes += len(raw)
        if entries:
            non_empty += 1

    bundled_bytes = 0
    bundled_count = 0
    if bundled_out is not None:
        all_hits_ranked.sort(key=lambda x: (x[0], x[1]))
        chosen: dict[str, bytes] = {}
        for _, dom, webp in all_hits_ranked:
            if dom not in chosen:
                chosen[dom] = webp
                if len(chosen) >= bundled_limit:
                    break
        raw_bundled = pack_akic(chosen.items())
        bundled_out.parent.mkdir(parents=True, exist_ok=True)
        bundled_out.write_bytes(raw_bundled)
        bundled_bytes = len(raw_bundled)
        bundled_count = len(chosen)

    manifest = {
        "version": 1,
        "format": "AKIC-WEBP-64",
        "prefix_bits": PREFIX_BITS,
        "bucket_count": BUCKET_COUNT,
        "non_empty_buckets": non_empty,
        "total_icons": total_icons,
        "total_bytes": total_bytes,
        "avg_icons_per_bucket": round(total_icons / BUCKET_COUNT, 2),
        "avg_bucket_bytes": round(total_bytes / BUCKET_COUNT, 1),
        "sources": dict(source_counts),
        "built_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    (buckets_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if bundled_out is not None:
        manifest["bundled_count"] = bundled_count
        manifest["bundled_bytes"] = bundled_bytes
    return manifest


def upload_to_s3(work_dir: Path, bucket: str, prefix: str, aws_profile: str, aws_region: str, max_workers: int = 64) -> dict:
    import boto3

    buckets_dir = work_dir / "buckets_v1"
    session = boto3.Session(profile_name=aws_profile, region_name=aws_region)
    s3 = session.client("s3")
    prefix = prefix.strip("/")

    # Fetch existing ETags so re-runs skip unchanged buckets
    existing_etags: dict[str, str] = {}
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=f"{prefix}/"):
        for obj in page.get("Contents", []):
            existing_etags[obj["Key"]] = obj["ETag"].strip('"')

    files = sorted(buckets_dir.glob("*.bin"))
    manifest_file = buckets_dir / "manifest.json"
    uploaded = skipped = failed = 0
    t0 = time.time()

    def put_one(path: Path) -> str:
        data = path.read_bytes()
        key = f"{prefix}/{path.name}"
        md5_hex = hashlib.md5(data).hexdigest()
        if existing_etags.get(key) == md5_hex:
            return "skip"
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=data,
            ContentType="application/octet-stream",
            CacheControl="public, max-age=2592000, immutable",
        )
        return "put"

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futs = [pool.submit(put_one, p) for p in files]
        for idx, fut in enumerate(concurrent.futures.as_completed(futs), 1):
            try:
                res = fut.result()
                if res == "put":
                    uploaded += 1
                else:
                    skipped += 1
            except Exception as e:
                failed += 1
                if failed <= 10:
                    print(f"Upload error: {e}", file=sys.stderr)
            if idx % 2000 == 0 or idx == len(files):
                dt = max(0.01, time.time() - t0)
                print(
                    f"[upload] {idx:,}/{len(files):,} ({idx/dt:.0f}/s) "
                    f"uploaded={uploaded:,} skipped={skipped:,} failed={failed:,}",
                    flush=True,
                )

    if manifest_file.exists():
        s3.put_object(
            Bucket=bucket,
            Key=f"{prefix}/manifest.json",
            Body=manifest_file.read_bytes(),
            ContentType="application/json",
            CacheControl="public, max-age=300",
        )

    return {"uploaded": uploaded, "skipped": skipped, "failed": failed, "elapsed_sec": round(time.time() - t0, 1)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Build and upload k-anonymous site icon buckets.")
    parser.add_argument("--work-dir", type=Path, default=Path("build/icon-buckets"))
    parser.add_argument("--countries", default=DEFAULT_COUNTRIES)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--concurrency", type=int, default=220)
    parser.add_argument("--waf-concurrency", type=int, default=40)
    parser.add_argument("--waf-rank-cutoff", type=int, default=150_000)
    parser.add_argument("--limit", type=int, default=None, help="Cap corpus size for quick testing")
    parser.add_argument("--skip-crawl", action="store_true")
    parser.add_argument("--skip-waf-retry", action="store_true")
    parser.add_argument("--export-psl", type=Path, default=None, help="Write compressed psl.txt.zlib")
    parser.add_argument("--export-bundled", type=Path, default=None, help="Write compact offline SiteIcons.bin")
    parser.add_argument("--bundled-limit", type=int, default=1500)
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--bucket", default="agent-keyring.jjpcodes.com")
    parser.add_argument("--prefix", default="icons/v1")
    parser.add_argument("--aws-profile", default="homelab-admin")
    parser.add_argument("--aws-region", default="eu-west-1")
    args = parser.parse_args()

    work_dir: Path = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    psl_path = work_dir / "downloads" / "public_suffix_list.dat"
    if not download_if_missing(PSL_URL, psl_path):
        sys.exit("Failed to download Public Suffix List")
    psl = PublicSuffixList(psl_path)
    if args.export_psl:
        nbytes = psl.write_compressed(args.export_psl)
        print(f"Wrote compressed PSL ({len(psl.clean_lines):,} rules, {nbytes:,} bytes) -> {args.export_psl}")

    countries = [c.strip() for c in args.countries.split(",") if c.strip()]
    corpus = load_corpus(work_dir, countries, psl, args.limit)
    print(f"Corpus ready: {len(corpus):,} unique public eTLD+1 domains (countries={countries})", flush=True)

    if not args.skip_crawl:
        t0 = time.time()
        shards_dir = work_dir / "shards"
        shards_dir.mkdir(parents=True, exist_ok=True)
        n_workers = max(1, min(args.workers, len(corpus)))
        # Round-robin split so every worker gets the same rank distribution
        worker_chunks: list[list[tuple[str, str, int]]] = [[] for _ in range(n_workers)]
        for i, item in enumerate(corpus):
            worker_chunks[i % n_workers].append(item)

        worker_args = [
            (
                i,
                worker_chunks[i],
                str(shards_dir / f"worker_{i:02d}.sqlite"),
                args.concurrency,
                args.waf_concurrency,
                args.waf_rank_cutoff,
                args.skip_waf_retry,
            )
            for i in range(n_workers)
        ]
        if n_workers == 1:
            results = [worker_process(worker_args[0])]
        else:
            ctx = mp.get_context("spawn")
            with ctx.Pool(processes=n_workers) as pool:
                results = pool.map(worker_process, worker_args)
        dt = time.time() - t0
        total_hits = sum(r["total_hits"] for r in results)
        s2_rec = sum(r["stage2_recovered"] for r in results)
        print(
            f"Crawl finished in {dt:.1f}s ({len(corpus)/max(1, dt):.1f} domains/s): "
            f"{total_hits:,}/{len(corpus):,} live icons ({100*total_hits/max(1, len(corpus)):.1f}%), "
            f"WAF/SVG stage2 recovered={s2_rec:,}",
            flush=True,
        )

    corpus_ranks = {d: rk for d, _, rk in corpus}
    manifest = pack_buckets(work_dir, corpus_ranks, args.export_bundled, args.bundled_limit)
    print("Packed manifest:", json.dumps(manifest, indent=2), flush=True)

    if args.upload:
        up = upload_to_s3(work_dir, args.bucket, args.prefix, args.aws_profile, args.aws_region)
        print("S3 upload:", json.dumps(up, indent=2), flush=True)
        if up["failed"] > 0:
            sys.exit(1)


if __name__ == "__main__":
    main()
