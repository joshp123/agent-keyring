#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.35",
#   "curl-cffi>=0.10",
#   "pillow>=11.0",
#   "resvg-py>=0.5",
# ]
# ///
# Written by AI on 2026.11.26 by model gemini-4-neon.
"""Post-process Go crawler raw streams + run Stage-2 curl_cffi WAF recovery + pack & upload AKIC v1 buckets."""

from __future__ import annotations

import argparse
import asyncio
import base64
import concurrent.futures
import hashlib
import io
import json
import multiprocessing as mp
import os
import re
import struct
import sys
import time
import urllib.parse
import warnings
from collections import defaultdict
from pathlib import Path

from curl_cffi.requests import AsyncSession
from PIL import Image
import resvg_py

warnings.filterwarnings("ignore", category=UserWarning)

PREFIX_BITS = 14
BUCKET_COUNT = 1 << PREFIX_BITS

LINK_RE = re.compile(r"<link\b[^>]*rel=[\"']?[^\"']*icon[^\"']*[\"']?[^>]*>", re.I)
HREF_RE = re.compile(r"href=[\"']([^\"']+)[\"']", re.I)
SIZES_RE = re.compile(r"sizes=[\"'](\d+)x(\d+)[\"']", re.I)


def bucket_id(domain: str) -> str:
    digest = hashlib.sha256(domain.encode("utf-8")).digest()
    val = ((digest[0] << 8) | digest[1]) >> (16 - PREFIX_BITS)
    return f"{val:04x}"


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


def normalize_icon(data: bytes, is_svg: bool = False) -> bytes | None:
    if not data or len(data) < 32:
        return None
    if is_svg:
        return rasterize_svg(data)
    head = data[:256].lstrip().lower()
    if b"<svg" in head:
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


# MARK: - Stage 2: Parallel curl_cffi WAF recovery

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


def extract_html_cands(html: str, final_base: str) -> tuple[bytes | None, list[str]]:
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
    seen, urls = set(), []
    for _, u in cands:
        if u not in seen:
            seen.add(u)
            urls.append(u)
            if len(urls) >= 3:
                break
    return None, urls


async def cffi_try_icon(session: AsyncSession, url: str) -> bytes | None:
    try:
        r = await session.get(url, allow_redirects=True, timeout=5)
        if r.status_code == 200:
            ct = (r.headers.get("content-type") or "").lower()
            is_svg = "svg" in ct or str(r.url).lower().split("?")[0].endswith(".svg")
            return normalize_icon(r.content[:350_000], is_svg=is_svg)
    except Exception:
        pass
    return None


async def cffi_crawl_one(session: AsyncSession, dom: str, origin: str) -> bytes | None:
    bases = [origin]
    alt = f"https://www.{dom}" if not origin.startswith(f"https://www.{dom}") else f"https://{dom}"
    if alt not in bases:
        bases.append(alt)

    for idx, base in enumerate(bases):
        try:
            r = await session.get(base + "/", allow_redirects=True, timeout=6)
            if r.status_code == 200 and "html" in (r.headers.get("content-type") or "").lower():
                html = r.text[:100_000]
                final_base = str(r.url)
                inline_webp, urls = extract_html_cands(html, final_base)
                if inline_webp:
                    return inline_webp
                for u in urls:
                    webp = await cffi_try_icon(session, u)
                    if webp:
                        return webp
                pu = urllib.parse.urlparse(final_base)
                root = f"{pu.scheme}://{pu.netloc}"
                for path in ("/apple-touch-icon.png", "/favicon.ico", "/favicon.svg"):
                    webp = await cffi_try_icon(session, root + path)
                    if webp:
                        return webp
                break
        except Exception:
            if idx == 0:
                continue
            break

    for path in ("/favicon.ico", "/apple-touch-icon.png", "/favicon.svg"):
        webp = await cffi_try_icon(session, bases[0] + path)
        if webp:
            return webp
    return None


def waf_worker(args_tuple: tuple) -> tuple[int, int]:
    idx, items, out_path_str, conc = args_tuple
    out_path = Path(out_path_str)

    async def run() -> tuple[int, int]:
        t0 = time.time()
        done = hits = 0
        q: asyncio.Queue[tuple[str, str] | None] = asyncio.Queue(maxsize=conc * 2)

        async def prod():
            for d, o in items:
                await q.put((d, o))
            for _ in range(conc):
                await q.put(None)

        out_f = open(out_path, "wb")

        async def cons(session: AsyncSession):
            nonlocal done, hits
            while True:
                item = await q.get()
                if item is None:
                    q.task_done()
                    return
                d, o = item
                try:
                    webp = await asyncio.wait_for(cffi_crawl_one(session, d, o), timeout=10.0)
                except Exception:
                    webp = None
                done += 1
                if webp:
                    hits += 1
                    db = d.encode("utf-8")
                    out_f.write(struct.pack("<H", len(db)) + db + struct.pack("<BI", 2, len(webp)) + webp)
                if (idx == 0 and done % 1000 == 0) or done == len(items):
                    dt = max(0.01, time.time() - t0)
                    print(f"[waf-w{idx}] {done:,}/{len(items):,} ({done/dt:.1f}/s) recovered={hits:,}", flush=True)
                q.task_done()

        async with AsyncSession(impersonate="chrome", verify=False) as session:
            p = asyncio.create_task(prod())
            ws = [asyncio.create_task(cons(session)) for _ in range(conc)]
            await p
            await asyncio.gather(*ws)
        out_f.close()
        return done, hits

    return asyncio.run(run())


# MARK: - Stage 3: Parallel WebP normalization into 256 temp bucket-groups, then 16,384 AKIC files

def normalize_chunk(args_tuple: tuple) -> tuple[int, int, str]:
    worker_idx, raw_path_str, out_path_str, offset_start, offset_end = args_tuple
    # Read full raw file (or chunked by record boundaries) - each Go raw file is processed by a pool of workers
    # Actually simplest & fastest: stream records from raw_path_str and distribute batches to pool!
    raise NotImplementedError


def normalize_batch(batch: list[tuple[str, int, bytes]]) -> list[tuple[str, bytes]]:
    out: list[tuple[str, bytes]] = []
    for dom, flags, data in batch:
        if flags == 2:
            # Already normalized 64x64 WebP from Stage 2
            out.append((dom, data))
        else:
            webp = normalize_icon(data, is_svg=(flags == 1))
            if webp:
                out.append((dom, webp))
    return out


def iter_raw_records(paths: list[Path], batch_size: int = 1000):
    batch: list[tuple[str, int, bytes]] = []
    for p in paths:
        if not p.exists():
            continue
        with open(p, "rb") as f:
            while True:
                h2 = f.read(2)
                if len(h2) < 2:
                    break
                dom_len = struct.unpack("<H", h2)[0]
                dom_b = f.read(dom_len)
                h5 = f.read(5)
                if len(dom_b) < dom_len or len(h5) < 5:
                    break
                flags, data_len = struct.unpack("<BI", h5)
                blob = f.read(data_len)
                if len(blob) < data_len:
                    break
                dom = dom_b.decode("utf-8", "ignore")
                batch.append((dom, flags, blob))
                if len(batch) >= batch_size:
                    yield batch
                    batch = []
    if batch:
        yield batch


def pack_akic(entries: dict[str, bytes]) -> bytes:
    sorted_entries = sorted(entries.items(), key=lambda x: x[0])
    index_buf = bytearray()
    data_buf = bytearray()
    for dom, blob in sorted_entries:
        db = dom.encode("utf-8")
        index_buf += struct.pack("<H", len(db)) + db + struct.pack("<II", len(data_buf), len(blob))
        data_buf += blob
    return struct.pack("<4sII", b"AKIC", len(sorted_entries), len(index_buf)) + bytes(index_buf) + bytes(data_buf)


def upload_to_s3(buckets_dir: Path, bucket: str, prefix: str, aws_profile: str, aws_region: str, max_workers: int = 64) -> dict:
    import boto3

    session = boto3.Session(profile_name=aws_profile, region_name=aws_region)
    s3 = session.client("s3")
    prefix = prefix.strip("/")

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
    ap = argparse.ArgumentParser()
    ap.add_argument("--work-dir", type=Path, required=True)
    ap.add_argument("--raw-files", nargs="+", type=Path, required=True)
    ap.add_argument("--waf-files", nargs="*", type=Path, default=[])
    ap.add_argument("--waf-limit", type=int, default=120_000, help="Top-ranked WAF retries to run via curl_cffi")
    ap.add_argument("--waf-workers", type=int, default=8)
    ap.add_argument("--waf-concurrency", type=int, default=45)
    ap.add_argument("--cpu-workers", type=int, default=12)
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--bucket", default="agent-keyring.jjpcodes.com")
    ap.add_argument("--prefix", default="icons/v1")
    ap.add_argument("--aws-profile", default="homelab-admin")
    ap.add_argument("--aws-region", default="eu-west-1")
    args = ap.parse_args()

    work_dir: Path = args.work_dir
    buckets_dir = work_dir / "buckets_v1"
    buckets_dir.mkdir(parents=True, exist_ok=True)

    all_raw_files = list(args.raw_files)

    # Stage 2: WAF recovery via curl_cffi
    if args.waf_files:
        waf_items: dict[str, tuple[str, int]] = {}
        for wf in args.waf_files:
            if not wf.exists():
                continue
            with open(wf, "r", encoding="utf-8") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) >= 2:
                        d, o = parts[0], parts[1]
                        rk = int(parts[2]) if len(parts) >= 3 else 9999999
                        if d not in waf_items or rk < waf_items[d][1]:
                            waf_items[d] = (o, rk)
        ordered_waf = sorted(((d, o, rk) for d, (o, rk) in waf_items.items()), key=lambda x: (x[2], x[0]))
        if args.waf_limit and len(ordered_waf) > args.waf_limit:
            ordered_waf = ordered_waf[: args.waf_limit]
        print(f"Stage-2 WAF recovery: {len(ordered_waf):,} domains across {args.waf_workers} curl_cffi workers", flush=True)
        if ordered_waf:
            t0 = time.time()
            waf_out_dir = work_dir / "waf_raw"
            waf_out_dir.mkdir(parents=True, exist_ok=True)
            chunks = [[] for _ in range(args.waf_workers)]
            for i, (d, o, _) in enumerate(ordered_waf):
                chunks[i % args.waf_workers].append((d, o))
            wargs = [
                (i, chunks[i], str(waf_out_dir / f"waf_{i:02d}.raw"), args.waf_concurrency)
                for i in range(args.waf_workers)
                if chunks[i]
            ]
            ctx = mp.get_context("spawn")
            with ctx.Pool(processes=len(wargs)) as pool:
                res = pool.map(waf_worker, wargs)
            dt = time.time() - t0
            tot_done = sum(x[0] for x in res)
            tot_rec = sum(x[1] for x in res)
            print(f"Stage-2 WAF done in {dt:.1f}s ({tot_done/max(1,dt):.1f}/s): recovered {tot_rec:,}/{tot_done:,}", flush=True)
            all_raw_files.extend(sorted(waf_out_dir.glob("waf_*.raw")))

    # Stage 3: Parallel WebP normalization across cpu_workers, writing to 64 intermediate bucket shards
    # (keeps RAM < 500 MB even for 2.5M icons!)
    t0 = time.time()
    mid_dir = work_dir / "mid_buckets"
    mid_dir.mkdir(parents=True, exist_ok=True)
    for old in mid_dir.glob("mid_*.bin"):
        old.unlink()
    mid_files = [open(mid_dir / f"mid_{i:02x}.bin", "wb") for i in range(64)]

    total_in = total_ok = 0
    ctx = mp.get_context("spawn")
    with ctx.Pool(processes=args.cpu_workers) as pool:
        for res_batch in pool.imap_unordered(normalize_batch, iter_raw_records(all_raw_files, batch_size=800), chunksize=2):
            for dom, webp in res_batch:
                total_ok += 1
                bid_int = int(bucket_id(dom), 16)
                mid_idx = bid_int >> 8  # 14 bits -> top 6 bits (0..63)
                db = dom.encode("utf-8")
                mid_files[mid_idx].write(struct.pack("<H", len(db)) + db + struct.pack("<I", len(webp)) + webp)
            total_in += 1
            if total_in % 100 == 0:
                dt = max(0.01, time.time() - t0)
                print(f"[normalize] {total_ok:,} valid WebP icons ({total_ok/dt:.0f}/s)", flush=True)

    for f in mid_files:
        f.close()
    print(f"Normalization done in {time.time()-t0:.1f}s: {total_ok:,} valid 64x64 WebP icons", flush=True)

    # Stage 4: Pack exact 16,384 AKIC bucket files from the 64 mid-shards (low RAM!)
    t1 = time.time()
    total_bytes = total_unique = non_empty = 0
    for mid_idx in range(64):
        by_bid: dict[int, dict[str, bytes]] = defaultdict(dict)
        p = mid_dir / f"mid_{mid_idx:02x}.bin"
        with open(p, "rb") as f:
            while True:
                h2 = f.read(2)
                if len(h2) < 2:
                    break
                dl = struct.unpack("<H", h2)[0]
                dom = f.read(dl).decode("utf-8")
                wl = struct.unpack("<I", f.read(4))[0]
                webp = f.read(wl)
                bid_int = int(bucket_id(dom), 16)
                by_bid[bid_int][dom] = webp
        p.unlink()
        base_bid = mid_idx << 8
        for sub in range(256):
            bid_int = base_bid | sub
            entries = by_bid.get(bid_int, {})
            raw = pack_akic(entries)
            (buckets_dir / f"{bid_int:04x}.bin").write_bytes(raw)
            total_bytes += len(raw)
            total_unique += len(entries)
            if entries:
                non_empty += 1

    manifest = {
        "version": 1,
        "format": "AKIC-WEBP-64",
        "prefix_bits": PREFIX_BITS,
        "bucket_count": BUCKET_COUNT,
        "non_empty_buckets": non_empty,
        "total_icons": total_unique,
        "total_bytes": total_bytes,
        "avg_icons_per_bucket": round(total_unique / BUCKET_COUNT, 2),
        "avg_bucket_bytes": round(total_bytes / BUCKET_COUNT, 1),
        "built_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    (buckets_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Packed 16,384 AKIC buckets in {time.time()-t1:.1f}s:", json.dumps(manifest, indent=2), flush=True)

    if args.upload:
        up = upload_to_s3(buckets_dir, args.bucket, args.prefix, args.aws_profile, args.aws_region)
        print("S3 upload:", json.dumps(up, indent=2), flush=True)
        if up["failed"] > 0:
            sys.exit(1)


if __name__ == "__main__":
    main()
