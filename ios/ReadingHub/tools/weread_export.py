#!/usr/bin/env python3
"""Export account-uploaded WeRead TXT/EPUB books and import them into ReadingHub.

Browser automation needs pyppeteer==2.0.0; cached exports and tests use stdlib only.
No cookies, auth headers, or request signatures are extracted or saved by this tool.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from pathlib import Path

XHTML = "http://www.w3.org/1999/xhtml"
ET.register_namespace("", XHTML)
HOME = "https://weread.qq.com"
CATALOG = ".readerCatalog_list_item_title_text"
STORE = "Library/Application Support/QiyeReader"
SEGMENTS = {"txt": ("t_0", "t_1"), "epub": ("e_0", "e_1", "e_3")}
BOOK_INDEX = Path.home() / "Documents/书房/微信读书书目索引.json"


def x(tag: str) -> str:
    return "{" + XHTML + "}" + tag


def save_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as file:
        os.chmod(temporary, 0o600)
        json.dump(value, file, ensure_ascii=False, indent=2)
    temporary.replace(path)


def chapter_id(code: str) -> int:
    width = int(code[7:9], 16)
    value = int(code[9:9 + width], 16)
    if width < 1 or value < 1:
        raise ValueError("Invalid chapter identifier")
    return value


def decode_shards(shards: list[str]) -> str:
    """WeRead shard transform, adapted from danleegle/wxBook (weread_crypto.cc)."""
    payload = ""
    for shard in shards:
        if len(shard) <= 32:
            raise ValueError("Missing chapter shard")
        if hashlib.md5(shard[32:].encode()).hexdigest().upper() != shard[:32]:
            raise ValueError("Chapter shard checksum failed")
        payload += shard[32:]
    encoded = list(payload[1:])
    length = len(encoded)
    if length < 4:
        positions = []
    elif length < 11:
        positions = [0, 2]
    else:
        tail = min(4, (length + 9) // 10)
        digits = "".join(str(sum(1 << (bit * 2) for bit in range(8)
                                 if (ord(c) >> bit) & 1)) for c in reversed(encoded[-tail:]))
        modulus = length - tail - 2
        width = len(str(modulus))
        positions = []
        for i in range(0, len(digits) - width, width):
            if len(positions) >= 10:
                break
            positions.extend([int(digits[i:i + width]) % modulus,
                              int(digits[i + 1:i + 1 + width]) % modulus])
    for i in range(len(positions) - 1, 0, -2):
        for offset in (1, 0):
            a, b = positions[i] + offset, positions[i - 1] + offset
            encoded[a], encoded[b] = encoded[b], encoded[a]
    value = re.sub(r"[^A-Za-z0-9+/]", "", "".join(encoded).replace("-", "+").replace("_", "/"))
    return base64.b64decode(value + "=" * ((-len(value)) % 4)).decode("utf-8")


def cfi(doc: ET.Element, element: ET.Element, offset: int, uid: int) -> str:
    parents = {child: parent for parent in doc.iter() for child in parent}
    steps = []
    node = element
    while node is not doc:
        parent = parents[node]
        step = str((list(parent).index(node) + 1) * 2)
        if node.get("id"):
            step += "[" + re.sub(r"([\[\](),;=^])", r"^\1", node.get("id")) + "]"
        steps.append(step)
        node = parent
    return f"epubcfi(/6/{(uid + 1) * 2}[c{uid}]!/" + "/".join(reversed(steps)) + f"/1:{offset})"


def normalize(value: str) -> str:
    return "".join(unicodedata.normalize("NFKC", value).split())


def find_index_books(query: str, path: Path = BOOK_INDEX) -> list[dict]:
    if not query.strip():
        raise ValueError("请输入书名或作者")
    if not path.exists():
        return []
    books = json.loads(path.read_text(encoding="utf-8"))["books"]
    key = normalize(query).casefold()
    return [book for book in books if key in normalize(book["title"]).casefold()
            or key in normalize(book.get("author", "")).casefold()]


def choose_book(matches: list[dict]) -> dict:
    if len(matches) == 1:
        return matches[0]
    for number, row in enumerate(matches, 1):
        print(f"{number}. {row['title']} · {row.get('format', '').upper()}")
    selected = int(input("要取回哪一本？输入序号：")) - 1
    if not 0 <= selected < len(matches):
        raise ValueError("无效序号")
    return matches[selected]


def cover_media(image: bytes) -> str:
    if image.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if image.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    raise ValueError("Unsupported cover image")


def chapter_document(raw: str, title: str, fmt: str) -> tuple[ET.Element, list[tuple[ET.Element, int]]]:
    doc = ET.Element(x("html"), {"lang": "zh-CN"})
    head = ET.SubElement(doc, x("head"))
    ET.SubElement(head, x("title")).text = title
    ET.SubElement(head, x("link"), {"rel": "stylesheet", "href": "style.css"})
    body = ET.SubElement(doc, x("body"))
    offsets = []
    if fmt == "txt":
        ET.SubElement(body, x("h2"), {"id": "heading"}).text = title
        position = 0
        for number, line in enumerate(raw.splitlines(keepends=True), 1):
            text = line.rstrip("\r\n")
            if text:
                p = ET.SubElement(body, x("p"), {"id": f"p{number}"})
                p.text = text
                offsets.append((p, position))
            position += len(line)
    else:
        originals = re.findall(r"<html\b[\s\S]*?</html>", raw)
        if not originals:
            raise ValueError("EPUB chapter did not contain XHTML")
        for part, source in enumerate(originals, 1):
            original = ET.fromstring(source)
            original_body = original.find(x("body"))
            if original_body is None:
                raise ValueError("Missing chapter body")
            container = ET.SubElement(body, x("div"), {"id": f"part{part}"})
            container.text = original_body.text
            container.extend(original_body)
            for serial, node in enumerate(container.iter()):
                tag = node.tag.rsplit("}", 1)[-1]
                if tag in ("script", "iframe", "object", "embed", "img", "image"):
                    raise ValueError(f"Chapter contains {tag}; asset export needs adaptation")
                for key in node.attrib:
                    if key.lower().startswith("on"):
                        raise ValueError("Active XHTML content is unsupported")
                if node is not container and node.get("id"):
                    node.set("id", f"part{part}-" + node.get("id"))
                elif node is not container and (node.text or "").strip():
                    node.set("id", f"part{part}-n{serial}")
    return doc, offsets


def export_book(capture: dict, output: Path, quote: str | None = None) -> dict:
    info = capture["bookInfo"]
    fmt = info["format"].lower()
    if fmt not in SEGMENTS or not info["bookId"].startswith("CB_"):
        raise ValueError("Only your uploaded TXT and EPUB books are supported")
    title = unicodedata.normalize("NFC", info["title"])
    author = unicodedata.normalize("NFC", info.get("author", ""))
    chapters = {int(k): v for k, v in capture["chapters"].items()}
    expected = set(range(1, int(info["lastChapterIdx"]) + 1))
    if set(chapters) != expected:
        raise ValueError(f"Missing chapters: {sorted(expected - set(chapters))}")
    catalog = capture["catalog"]
    source_position = capture.get("position", {})
    uid = int(source_position.get("chapterUid", 1))
    if uid not in chapters:
        raise ValueError("Reading position refers to an absent chapter")
    fraction = float(source_position.get("fraction", 0))
    if not 0 <= fraction <= 1:
        raise ValueError("Invalid reading fraction")
    docs, raw_text, headings, line_offsets = {}, {}, {}, {}
    for chapter_uid, shards in sorted(chapters.items()):
        raw = decode_shards([shards[p] for p in SEGMENTS[fmt]])
        raw_text[chapter_uid] = raw
        chapter_title = next((c["title"] for c in catalog if c.get("chapterUid") == chapter_uid), f"第{chapter_uid}章")
        doc, offsets = chapter_document(raw, chapter_title, fmt)
        docs[chapter_uid], line_offsets[chapter_uid] = doc, offsets
        for node in doc.iter():
            if node.tag.rsplit("}", 1)[-1] in ("h1", "h2", "h3", "h4"):
                headings.setdefault(normalize("".join(node.itertext())), []).append((chapter_uid, node))
    position = {"chapter": source_position.get("chapter", ""), "fraction": fraction,
                "chapterUid": uid, "sourceOffset": source_position.get("chapterOffset", 0),
                "sourceBookId": info["bookId"], "precision": "chapter"}
    target, text_offset = None, 0
    if quote:
        matches = [(u, n, n.text.index(quote)) for u, doc in docs.items()
                   for n in doc.iter() if quote in (n.text or "")]
        if len(matches) != 1:
            raise ValueError("Position quote must occur exactly once")
        uid, target, text_offset = matches[0]
        position.update(chapterUid=uid, precision="sentence", sentence=quote)
    elif fmt == "txt":
        raw = raw_text[uid]
        byte_offset = int(source_position.get("chapterOffset", 0))
        if not 0 <= byte_offset <= len(raw.encode()):
            raise ValueError("Reading byte offset is outside the TXT chapter")
        character_offset = len(raw.encode()[:byte_offset].decode("utf-8", errors="ignore"))
        offsets = line_offsets[uid]
        candidates = [(node, start) for node, start in offsets if start <= character_offset]
        if candidates:
            target, start = candidates[-1]
            text_offset = min(character_offset - start, len(target.text or ""))
            position["precision"] = "byte-offset"
    if target is None:
        target = next((n for n in docs[uid].find(x("body")).iter() if (n.text or "").strip()), None)
    if target is None:
        raise ValueError("Empty reading-position chapter")
    if not target.get("id"):
        target.set("id", "start")
    utf16_offset = len((target.text or "")[:text_offset].encode("utf-16-le")) // 2
    position["cfi"] = cfi(docs[uid], target, utf16_offset, uid)
    position["href"] = f"chapter-{uid:03}.xhtml#{target.get('id')}"

    nav = ET.Element(x("html"), {"lang": "zh-CN"})
    ET.SubElement(ET.SubElement(nav, x("head")), x("title")).text = "目录"
    toc = ET.SubElement(ET.SubElement(nav, x("body")), x("nav"),
                        {"{http://www.idpf.org/2007/ops}type": "toc", "id": "toc"})
    root_list = ET.SubElement(toc, x("ol"))
    lists, last_items = {1: root_list}, {}
    for number, item in enumerate(catalog):
        label = item["title"]
        level = max(1, int(item.get("level", 1)))
        chapter_uid = item.get("chapterUid")
        if label == "扉页":
            href = "cover.xhtml"
        else:
            matches = headings.get(normalize(label), [])
            match = next((m for m in matches if m[0] == chapter_uid), matches[0] if matches else None)
            if match:
                chapter_uid, node = match
                if not node.get("id"):
                    node.set("id", f"toc{number}")
                href = f"chapter-{chapter_uid:03}.xhtml#{node.get('id')}"
            elif chapter_uid in docs:
                href = f"chapter-{chapter_uid:03}.xhtml"
            else:
                raise ValueError(f"TOC entry has no chapter: {label}")
        if level > 1:
            if level - 1 not in last_items:
                raise ValueError("Invalid TOC nesting")
            if level not in lists:
                lists[level] = ET.SubElement(last_items[level - 1], x("ol"))
        li = ET.SubElement(lists[level], x("li"))
        ET.SubElement(li, x("a"), {"href": href}).text = label
        last_items[level] = li
        for deeper in list(lists):
            if deeper > level:
                del lists[deeper]

    cover = ET.Element(x("html"), {"lang": "zh-CN"})
    ET.SubElement(ET.SubElement(cover, x("head")), x("title")).text = title
    cover_body = ET.SubElement(cover, x("body"))
    ET.SubElement(cover_body, x("h1")).text = title
    ET.SubElement(cover_body, x("p")).text = author
    files = {"nav.xhtml": ET.tostring(nav, encoding="utf-8", xml_declaration=True),
             "cover.xhtml": ET.tostring(cover, encoding="utf-8", xml_declaration=True),
             "style.css": (re.sub(r"@font-face\s*\{[^}]*\}", "", capture.get("css", "") or
                                    (decode_shards([capture["cssShard"]]) if capture.get("cssShard") else "")) +
                           "\nbody{line-height:1.7}img{max-width:100%}p{white-space:pre-wrap}").encode()}
    if capture.get("cover"):
        image = base64.b64decode(capture["cover"], validate=True)
        cover_name = "cover.png" if cover_media(image) == "image/png" else "cover.jpg"
        ET.SubElement(cover_body, x("img"), {"src": cover_name, "alt": title})
        files["cover.xhtml"] = ET.tostring(cover, encoding="utf-8", xml_declaration=True)
        files[cover_name] = image
    files.update({f"chapter-{u:03}.xhtml": ET.tostring(doc, encoding="utf-8", xml_declaration=True)
                  for u, doc in sorted(docs.items())})
    package = ET.Element("package", {"xmlns": "http://www.idpf.org/2007/opf", "version": "3.0", "unique-identifier": "bookid"})
    metadata = ET.SubElement(package, "metadata", {"xmlns:dc": "http://purl.org/dc/elements/1.1/"})
    ET.SubElement(metadata, "dc:identifier", {"id": "bookid"}).text = "urn:weread:" + info["bookId"]
    ET.SubElement(metadata, "dc:title").text = title
    ET.SubElement(metadata, "dc:creator").text = author
    ET.SubElement(metadata, "dc:language").text = "zh-CN"
    modified = datetime.fromtimestamp(info.get("version", 0), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ET.SubElement(metadata, "meta", {"property": "dcterms:modified"}).text = modified
    manifest = ET.SubElement(package, "manifest")
    for href in files:
        identifier = "c" + str(int(re.search(r"chapter-(\d+)", href)[1])) if href.startswith("chapter-") else href.split(".")[0]
        is_cover_image = href in ("cover.jpg", "cover.png")
        if is_cover_image:
            identifier = "cover-image"
        attributes = {"id": identifier, "href": href, "media-type": "application/xhtml+xml" if href.endswith(".xhtml") else "text/css" if href.endswith(".css") else cover_media(files[href])}
        if href == "nav.xhtml":
            attributes["properties"] = "nav"
        if is_cover_image:
            attributes["properties"] = "cover-image"
        ET.SubElement(manifest, "item", attributes)
    spine = ET.SubElement(package, "spine")
    ET.SubElement(spine, "itemref", {"idref": "cover"})
    for u in sorted(docs):
        ET.SubElement(spine, "itemref", {"idref": f"c{u}"})
    files["package.opf"] = ET.tostring(package, encoding="utf-8", xml_declaration=True)
    output.mkdir(parents=True, exist_ok=True)
    stem = re.sub(r'[/\\:\x00-\x1f]', "_", title).removesuffix(".txt")
    stem = stem.encode("utf-8")[:230].decode("utf-8", errors="ignore")
    file = output / (stem + ".epub")
    temporary = file.with_suffix(".epub.tmp")
    with zipfile.ZipFile(temporary, "w") as archive:
        contents = {"mimetype": b"application/epub+zip",
                    "META-INF/container.xml": b'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
                    **{"OEBPS/" + name: data for name, data in files.items()}}
        for name, data in contents.items():
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    verify_epub(temporary)
    if file.exists() and file.read_bytes() != temporary.read_bytes():
        raise FileExistsError(f"Output already exists with different content: {file}")
    temporary.replace(file)
    if fmt == "txt":
        txt = output / (stem + ".txt")
        content = "\n\n".join(raw_text[u].rstrip("\r\n") for u in sorted(raw_text)) + "\n"
        if txt.exists() and txt.read_bytes() != content.encode("utf-8"):
            raise FileExistsError(f"TXT output already exists with different content: {txt}")
        txt.write_bytes(content.encode("utf-8"))
    position.update(fileSha256=hashlib.sha256(file.read_bytes()).hexdigest(), title=title, author=author)
    save_json(file.with_suffix(".progress.json"), position)
    return {"file": str(file), "bytes": file.stat().st_size, "chapterFiles": len(docs),
            "tocEntries": len(catalog), "sourceFormat": fmt, "readingPosition": position}


def verify_epub(file: Path) -> None:
    with zipfile.ZipFile(file) as archive:
        if archive.testzip() is not None or archive.read("mimetype") != b"application/epub+zip":
            raise ValueError("Invalid EPUB archive")
        docs = {name: ET.fromstring(archive.read(name)) for name in archive.namelist()
                if name.endswith((".xml", ".xhtml", ".opf"))}
        for name, doc in docs.items():
            ids = [node.get("id") for node in doc.iter() if node.get("id")]
            if len(ids) != len(set(ids)):
                raise ValueError("Duplicate XHTML IDs in " + name)
        for link in docs["OEBPS/nav.xhtml"].iter(x("a")):
            name, _, fragment = link.get("href").partition("#")
            target = docs.get("OEBPS/" + name)
            if target is None or fragment and not any(n.get("id") == fragment for n in target.iter()):
                raise ValueError("Broken TOC link")


async def collect_book(title: str, cache: Path, profile: Path, reader_url: str | None = None) -> dict:
    from pyppeteer import launch
    browser = await launch(executablePath="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                           userDataDir=str(profile), headless=False, defaultViewport=None, autoClose=False,
                           args=["--no-first-run", "--no-default-browser-check"])
    page = (await browser.pages())[0]
    client = await page.target.createCDPSession()
    await client.send("Network.enable")
    requests, chapters, pending = {}, {}, set()
    info, original, catalog, css = {}, {}, [], ""
    accept_position = True

    def request(event):
        nonlocal original
        request = event["request"]
        path = urllib.parse.urlparse(request["url"]).path
        if path.startswith("/web/book/chapter/") and request.get("postData"):
            data = json.loads(request["postData"])
            requests[event["requestId"]] = chapter_id(data["c"])
        elif path == "/web/book/read" and accept_position and request.get("postData"):
            data = json.loads(request["postData"])
            original = {"chapterUid": chapter_id(data["c"]), "chapterOffset": data["co"],
                        "fraction": data["pr"] / 100}

    async def response(event):
        nonlocal info, css
        path = urllib.parse.urlparse(event["response"]["url"]).path
        if path != "/web/book/readInfo" and not path.startswith("/web/book/chapter/"):
            return
        if event["response"]["status"] != 200:
            return
        # loadingFinished is not guaranteed to precede responseReceived.
        for _ in range(40):
            try:
                payload = await client.send("Network.getResponseBody", {"requestId": event["requestId"]})
                break
            except Exception:
                await asyncio.sleep(.05)
        else:
            raise RuntimeError("Chapter response body was unavailable")
        body = base64.b64decode(payload["body"]).decode() if payload.get("base64Encoded") else payload["body"]
        if path == "/web/book/readInfo":
            info = json.loads(body)["bookInfo"]
        elif path.endswith("/e_2"):
            css = decode_shards([body])
        elif path.rsplit("/", 1)[1] in {p for parts in SEGMENTS.values() for p in parts}:
            uid = requests.get(event["requestId"])
            if uid is not None:
                chapters.setdefault(str(uid), {})[path.rsplit("/", 1)[1]] = body

    def on_response(event):
        task = asyncio.create_task(response(event))
        pending.add(task)

    client.on("Network.requestWillBeSent", request)
    client.on("Network.responseReceived", on_response)

    async def wait_for(predicate, message, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for task in list(pending):
                if task.done():
                    pending.remove(task)
                    task.result()
            if predicate():
                return
            await asyncio.sleep(.05)
        raise TimeoutError(message)

    original_url = None
    try:
        await page.goto(HOME + "/web/shelf", {"waitUntil": "domcontentloaded"})
        print("若浏览器未登录，请扫码登录微信读书。", flush=True)
        await page.waitForSelector('a[href*="/web/reader/"]', {"timeout": 180000})
        if reader_url is None:
            rows = await page.evaluate("""() => [...document.querySelectorAll('a[href*="/web/reader/"]')].map(a=>({title:a.textContent.trim(),url:a.href}))""")
            matches = [r for r in rows if normalize(title) in normalize(r["title"])]
            if not matches:
                raise ValueError("当前网页书架未找到此书；先在手机微信读书中打开它，再重试，或使用 --url 阅读页链接")
            reader_url = (await asyncio.to_thread(choose_book, matches))["url"]
        if not reader_url.startswith(HOME + "/web/reader/"):
            raise ValueError("Expected a WeRead reader URL")
        await page.goto(reader_url, {"waitUntil": "domcontentloaded"})
        await wait_for(lambda: info and original, "未取得书籍信息或原阅读位置；请确认已登录")
        if info.get("format") not in SEGMENTS or not info["bookId"].startswith("CB_"):
            raise ValueError("请选择自己上传的 TXT 或 EPUB")
        original_url = page.url
        accept_position = False
        await client.send("Network.setBlockedURLs", {"urls": [HOME + "/web/book/read"]})
        async def open_catalog():
            if not await page.evaluate("s=>{const e=document.querySelector(s); return !!e && getComputedStyle(e).visibility!=='hidden' && e.getBoundingClientRect().height>0}", CATALOG):
                for button in await page.JJ("button"):
                    if (await page.evaluate("b=>b.textContent.trim()", button)) == "目录":
                        await button.click()
                        break
                await page.waitForSelector(CATALOG, {"visible": True})
        await open_catalog()
        catalog = await page.evaluate("""selector => [...document.querySelectorAll(selector)].map((e,index)=>({index,title:e.textContent.trim(),level:Number((e.closest('.readerCatalog_list_item')?.className.match(/level_?(\\d+)/)||[])[1]||1)}))""", CATALOG)
        path = cache / (info["bookId"] + ".json")
        if path.exists():
            previous = json.loads(path.read_text())
            if previous["bookInfo"].get("version") != info.get("version"):
                raise ValueError("上传书版本变更，请移走旧缓存后重试")
            chapters = {**previous["chapters"], **chapters}
        def checkpoint():
            save_json(path, {"bookInfo": info, "catalog": catalog, "chapters": chapters,
                             "position": original, "readerUrl": reader_url, "css": css})
        def ready(uid):
            return all(p in chapters.get(str(uid), {}) for p in SEGMENTS[info["format"]])
        is_simple_txt = info["format"] == "txt" and len(catalog) == info["lastChapterIdx"] + 1 and catalog[0]["title"] == "扉页"
        for item in catalog:
            if item["title"] == "扉页":
                continue
            expected_uid = item["index"] if is_simple_txt else None
            if expected_uid and ready(expected_uid):
                item["chapterUid"] = expected_uid
                continue
            await open_catalog()
            elements = await page.JJ(CATALOG)
            await elements[item["index"]].click()
            if expected_uid:
                await wait_for(lambda: ready(expected_uid), f"章节 {expected_uid} 加载失败")
                uid = expected_uid
            else:
                await asyncio.sleep(.2)
                code = urllib.parse.urlparse(page.url).path.rsplit("k", 1)[-1]
                uid = chapter_id(code)
                await wait_for(lambda: ready(uid), f"章节 {uid} 加载失败")
            item["chapterUid"] = uid
            checkpoint()
            print(f"已取回 {sum(ready(u) for u in range(1,info['lastChapterIdx']+1))}/{info['lastChapterIdx']} 章", flush=True)
        await wait_for(lambda: all(ready(u) for u in range(1, info["lastChapterIdx"] + 1)), "章节不完整")
        original["chapter"] = next((c["title"] for c in catalog if c.get("chapterUid") == original["chapterUid"]), "")
        checkpoint()
        capture = json.loads(path.read_text())
        if info.get("cover"):
            cover_url = info["cover"]
            if not cover_url.startswith("https://"):
                raise ValueError("Invalid cover URL")
            with urllib.request.urlopen(cover_url, timeout=20) as response:
                image = response.read()
            capture["cover"] = base64.b64encode(image).decode()
            save_json(path, capture)
        return capture
    finally:
        # Restore while progress writes remain blocked, then close the export browser.
        try:
            client.remove_listener("Network.responseReceived", on_response)
            client.remove_listener("Network.requestWillBeSent", request)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            if original_url:
                await page.goto(original_url, {"waitUntil": "domcontentloaded"})
            await client.send("Network.setBlockedURLs", {"urls": []})
        finally:
            await browser.close()


def merge_library(library: dict, file: Path, position: dict, cover: str | None = None) -> tuple[dict, bool]:
    identifier = hashlib.sha256(file.read_bytes()).hexdigest()
    if identifier != position["fileSha256"]:
        raise ValueError("Reading position belongs to a different EPUB")
    books = library["books"]
    if identifier in books:
        return library, False  # Retain subsequent progress, notes and bookmarks.
    now = time.time() * 1000
    native_position = {k: position[k] for k in ("cfi", "chapter", "fraction")}
    native_position.update(revision=str(uuid.uuid4()), device=library["device"], updated=now)
    book = {"id": identifier, "file": identifier + ".epub", "name": file.name,
            "title": position["title"], "author": position.get("author", ""), "format": "EPUB",
            "size": file.stat().st_size, "added": now, "lastRead": now, "dirty": True,
            "progress": native_position}
    if cover:
        media = cover_media(base64.b64decode(cover, validate=True))
        book.update(cover="data:" + media + ";base64," + cover, coverSource="embedded", coverEmbeddedChecked=True)
    books[identifier] = book
    return library, True


def install_phone(file: Path, position: dict, device: str, cover: str | None = None) -> bool:
    """Use Apple's paired-device interface, with the native reader stopped during writes."""
    bundle = "com.wyih.qiyereader"
    with tempfile.TemporaryDirectory(prefix="readinghub-import-") as temporary:
        root = Path(temporary)
        def command(*args):
            subprocess.run(["xcrun", "devicectl", "device", *args, "--device", device,
                            "--timeout", "30", "--quiet"], check=True, capture_output=True, text=True)
        def info(kind):
            path = root / (kind + ".json")
            command("info", kind, "--json-output", str(path))
            return json.loads(path.read_text())["result"]
        apps = info("apps")["apps"]
        app = next((a for a in apps if a.get("bundleIdentifier") == bundle), None)
        if not app:
            raise ValueError("ReadingHub is not installed on this device")
        bundle_url = app["url"] if isinstance(app["url"], str) else app["url"]["path"]
        def running():
            return [p for p in info("processes")["runningProcesses"]
                    if str(p.get("executable", "")).startswith(bundle_url.rstrip("/") + "/")]
        for process in running():
            command("process", "terminate", "--pid", str(process["processIdentifier"]))
        library_file = root / "library.json"
        def copy(direction, source, destination):
            command("copy", direction, "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                    "--source", str(source), "--destination", str(destination))
        copy("from", STORE + "/library.json", library_file)
        library = json.loads(library_file.read_text())
        library, added = merge_library(library, file, position, cover)
        if added:
            save_json(library_file, library)
            identifier = position["fileSha256"]
            copy("to", file, STORE + "/books/" + identifier + ".epub")
            if running():
                raise RuntimeError("ReadingHub reopened during import; library was not replaced")
            copy("to", library_file, STORE + "/library.json")
            verified = root / "verified.json"
            copy("from", STORE + "/library.json", verified)
            if json.loads(verified.read_text()) != library:
                raise RuntimeError("Phone library verification failed")
            verified_book = root / "verified.epub"
            copy("from", STORE + "/books/" + identifier + ".epub", verified_book)
            if hashlib.sha256(verified_book.read_bytes()).hexdigest() != identifier:
                raise RuntimeError("Phone book verification failed")
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", device,
                        "--payload-url", "readinghub://qiye", "--timeout", "30", "--quiet", bundle],
                       check=True, capture_output=True, text=True)
        return added


def main() -> int:
    parser = argparse.ArgumentParser(description="微信读书上传书 → TXT/EPUB → 书房")
    parser.add_argument("--title", help="书名或作者；不传时交互输入")
    parser.add_argument("--find", action="store_true", help="仅查询本地书目索引，不取回正文或打开浏览器")
    parser.add_argument("--url", help="微信读书阅读页 URL，适合重名或书架未显示的书")
    parser.add_argument("--capture", type=Path, help="从已取回的章节缓存导出，不访问浏览器")
    parser.add_argument("--output", type=Path, default=Path.home() / "Downloads/微信读书导出")
    parser.add_argument("--cache", type=Path, default=Path.home() / "Library/Caches/ReadingHubWeread/chapters")
    parser.add_argument("--profile", type=Path, default=Path.home() / "Library/Caches/ReadingHubWeread/Chrome")
    parser.add_argument("--position-quote", help="EPUB 精确定位用：原阅读页第一句，须唯一出现")
    parser.add_argument("--device", help="导入指定已配对 iPhone 的书房；不传则只导出")
    args = parser.parse_args()
    started = time.monotonic()
    if args.capture:
        capture = json.loads(args.capture.read_text())
    else:
        query = args.title or input("要取回的书名或作者：").strip()
        matches = find_index_books(query)
        if args.find:
            print(json.dumps(matches, ensure_ascii=False, indent=2))
            return 0 if matches else 1
        reader_url = args.url
        if reader_url is None and matches:
            book = choose_book(matches)
            if book["format"] not in SEGMENTS:
                raise ValueError(f"此书为 {book['format'].upper()}；当前取回脚本支持 TXT 和纯文字 EPUB")
            reader_url = book["readerUrl"]
        capture = asyncio.run(collect_book(query, args.cache, args.profile, reader_url))
    result = export_book(capture, args.output, args.position_quote)
    if args.device:
        result["phoneImport"] = "added" if install_phone(Path(result["file"]), result["readingPosition"], args.device, capture.get("cover")) else "already-present"
    elapsed = round(time.monotonic() - started, 1)
    position = result["readingPosition"]
    print(f"\n已取回《{position['title']}》：{result['chapterFiles']} 章，用时 {elapsed} 秒。")
    print("EPUB：" + str(Path(result["file"]).resolve()))
    if result["sourceFormat"] == "txt":
        print("TXT：" + str(Path(result["file"]).with_suffix('.txt').resolve()))
    print(f"阅读进度：{position['chapter']} · {position['fraction']:.0%}")
    if position["precision"] == "chapter":
        print("定位到原章节开头；百分比已记录。精确句子可通过 --position-quote 指定。")
    if args.device:
        print("书房：已导入。" if result["phoneImport"] == "added" else "书房：已有此书，保留现有进度。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, TimeoutError, OSError, subprocess.CalledProcessError) as error:
        print("导出未完成：" + str(error), file=sys.stderr)
        raise SystemExit(1)
