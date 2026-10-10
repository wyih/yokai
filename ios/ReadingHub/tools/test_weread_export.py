import copy
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from unittest.mock import patch

import weread_export as export


class ExportTests(unittest.TestCase):
    def test_index_lookup_by_title_and_author_keeps_duplicate_books(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "index.json"
            export.save_json(path, {"books": [
                {"bookId": "CB_1", "title": "同名书", "author": "헤복"},
                {"bookId": "CB_2", "title": "同名书", "author": "另一作者"},
            ]})
            self.assertEqual(len(export.find_index_books(" 同名 书 ", path)), 2)
            self.assertEqual(export.find_index_books("헤복", path)[0]["bookId"], "CB_1")
            self.assertEqual(export.find_index_books("不存在", path), [])

    def test_txt_position_and_repeat_import(self):
        raw = "前言\r\n\r\n　　中文😀后文\r\n"
        capture = {
            "bookInfo": {"bookId": "CB_test", "title": "测试", "format": "txt", "lastChapterIdx": 1},
            "chapters": {"1": {"t_0": "a", "t_1": "b"}},
            "catalog": [{"title": "扉页"}, {"title": "前言", "chapterUid": 1}],
            "position": {"chapterUid": 1, "chapterOffset": len("前言\r\n\r\n　　中文😀".encode()), "fraction": .4},
        }
        with tempfile.TemporaryDirectory() as root, patch.object(export, "decode_shards", return_value=raw):
            result = export.export_book(capture, Path(root))
            position, file = result["readingPosition"], Path(result["file"])
            self.assertTrue(position["cfi"].endswith("/1:6)"))  # Emoji takes two UTF-16 units.
            self.assertEqual(file.with_suffix(".txt").read_bytes(), (raw.rstrip("\r\n") + "\n").encode())
            original_hash = position["fileSha256"]
            capture["position"]["chapterOffset"] = 0
            repeated = export.export_book(capture, Path(root))
            self.assertEqual(repeated["readingPosition"]["fileSha256"], original_hash)
            library = {"device": "test", "books": {"old": {"notes": ["保留"]}}, "settings": {"theme": "dark"}}
            before = copy.deepcopy(library)
            library, added = export.merge_library(library, file, position)
            self.assertTrue(added)
            self.assertEqual(library["books"]["old"], before["books"]["old"])
            self.assertEqual(library["settings"], before["settings"])
            library["books"][original_hash]["progress"]["fraction"] = .9
            saved = copy.deepcopy(library)
            library, added = export.merge_library(library, file, repeated["readingPosition"])
            self.assertFalse(added)
            self.assertEqual(library, saved)
            with zipfile.ZipFile(file) as epub:
                ET.fromstring(epub.read("OEBPS/package.opf"))

    def test_missing_chapter_and_corrupt_shard(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, "Missing chapters"):
                export.export_book({"bookInfo": {"bookId": "CB_test", "format": "txt", "title": "测试", "lastChapterIdx": 2},
                                    "chapters": {"1": {}}}, Path(root))
        with self.assertRaisesRegex(ValueError, "checksum"):
            export.decode_shards(["0" * 32 + "changed"])


if __name__ == "__main__":
    unittest.main()
