#!/usr/bin/env python3
"""Exercise iOS backup I/O using serializers generated from Android's actual models.

Requires the Kotlin artifacts already present in this repository's Gradle cache.
Only schema declarations are compiled; database-dependent helper methods are omitted.
"""
from pathlib import Path
import os
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "ios/build/backup-check"
BUILD.mkdir(parents=True, exist_ok=True)
CACHE = Path.home() / ".gradle/caches/modules-2/files-2.1"
JAVA = ROOT / "ios/build/runtime/jdk-27.jdk/Contents/Home/bin/java"
JAVAC = JAVA.with_name("javac")
COMPAT = ROOT / "ios/build/runtime/compat.jar"

def jar(group, artifact, version):
    found = list((CACHE / group / artifact / version).glob("*/*.jar"))
    if not found:
        raise RuntimeError(f"Missing cached {artifact} {version}")
    return found[0]

compiler = jar("org.jetbrains.kotlin", "kotlin-compiler-embeddable", "2.4.10")
reflect = jar("org.jetbrains.kotlin", "kotlin-reflect", "2.4.10")
plugin = jar("org.jetbrains.kotlin", "kotlin-serialization-compiler-plugin-embeddable", "2.4.10")
stdlib = jar("org.jetbrains.kotlin", "kotlin-stdlib", "2.4.10")
coroutines = jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.11.0")
annotations = jar("org.jetbrains", "annotations", "26.0.1")
core = jar("org.jetbrains.kotlinx", "kotlinx-serialization-core-jvm", "1.11.0")
protobuf = jar("org.jetbrains.kotlinx", "kotlinx-serialization-protobuf-jvm", "1.11.0")
cp = os.pathsep.join(map(str, [stdlib, core, protobuf, annotations, COMPAT]))
models = ROOT / "app/src/main/java/eu/kanade/tachiyomi/data/backup/models"
declarations = []
for filename in ["Backup", "BackupManga", "BackupChapter", "BackupCategory", "BackupTracking", "BackupSource"]:
    text = (models / f"{filename}.kt").read_text()
    start = re.search(r"(?:data )?class " + filename + r"\(", text).start()
    end = text.index("\n) {", start) + 2
    declarations.append("@Serializable\n" + text[start:end])
for filename in ["BackupHistory", "BackupPreference"]:
    text = (models / f"{filename}.kt").read_text()
    declarations.append("\n".join(line for line in text.splitlines() if not line.startswith(("package ", "import "))))
(BUILD / "Schemas.kt").write_text("""package eu.kanade.tachiyomi.data.backup.models
import kotlinx.serialization.Serializable
import kotlinx.serialization.protobuf.ProtoNumber
import eu.kanade.tachiyomi.source.model.UpdateStrategy
""" + "\n".join(declarations))
(BUILD / "Check.kt").write_text('''
import eu.kanade.tachiyomi.data.backup.models.*
import kotlinx.serialization.protobuf.ProtoBuf
import java.io.File
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
fun main(args: Array<String>) {
    val original = Backup(backupManga = listOf(BackupManga(
        source = -9223372036854775000L, url = "/book/1", title = "测试漫画", author = "作者", artist = "画师",
        description = "简介", genre = listOf("冒险", "奇幻"), status = 1, thumbnailUrl = "https://example.org/cover.jpg",
        dateAdded = 1700000000000L, viewer_flags = 18, memo = "{\\"id\\":1}".encodeToByteArray(),
        categories = listOf(0), chapters = listOf(BackupChapter(url = "/chapter/1", name = "第一章", scanlator = "汉化组",
            lastPageRead = 44, pagesLeft = 227, bookmark = true, chapterNumber = 1.5F, dateUpload = 1700000001000L,
            dateFetch = 1700000002000L, memo = "{\\"cid\\":1}".encodeToByteArray())),
        history = listOf(BackupHistory("/chapter/1", 1700000003000L, 12000L)),
        tracking = listOf(BackupTracking(syncId = 9, libraryId = 100, mediaId = 456789012345L, title = "追踪记录", score = 8.5F)),
        customTitle = "自定义标题", customArtist = "自定义画师", customAuthor = "自定义作者",
        customDescription = "自定义简介", customGenre = listOf("自定义类型"), customStatus = 2, chapterFlags = 104)),
        backupCategories = listOf(BackupCategory("收藏", 0, flags = 23, mangaSort = 'r')),
        backupSources = listOf(BackupSource("测试源", -9223372036854775000L)),
        backupPreferences = listOf(BackupPreference("pref_default_reading_mode_key", IntPreferenceValue(2))),
        backupSourcePreferences = listOf(BackupSourcePreferences("source_-9223372036854775000",
            listOf(BackupPreference("username", StringPreferenceValue("fixture-only")),
                   BackupPreference("hosts", StringSetPreferenceValue(setOf("a", "b")))))))
    if (args[0] == "create") {
        GZIPOutputStream(File(args[1]).outputStream()).use { it.write(ProtoBuf.encodeToByteArray(Backup.serializer(), original)) }
    } else {
        val bytes = GZIPInputStream(File(args[1]).inputStream()).use { it.readBytes() }
        val read = ProtoBuf.decodeFromByteArray(Backup.serializer(), bytes)
        val a = original.backupManga.single(); val b = read.backupManga.single()
        check(a.source == b.source && a.url == b.url && a.title == b.title && a.viewer_flags == b.viewer_flags)
        check(a.genre == b.genre && a.memo.contentEquals(b.memo))
        check(b.chapters.single().lastPageRead == 44 && b.chapters.single().pagesLeft == 227 && b.chapters.single().bookmark)
        check(a.chapters.single().scanlator == b.chapters.single().scanlator && b.chapters.single().chapterNumber == 1.5F)
        check(a.history == b.history && a.tracking == b.tracking && a.chapterFlags == b.chapterFlags)
        check(a.author == b.author && a.artist == b.artist && a.description == b.description && a.status == b.status)
        check(a.customTitle == b.customTitle && a.customAuthor == b.customAuthor && a.customArtist == b.customArtist)
        check(a.customDescription == b.customDescription && a.customGenre == b.customGenre && a.customStatus == b.customStatus)
        check(read.backupCategories.single().name == "收藏" && read.backupCategories.single().flags == 23 && read.backupCategories.single().mangaSort == 'r' && b.categories == listOf(0))
        check(read.backupSources.single().sourceId == a.source)
        check(read.backupPreferences == original.backupPreferences && read.backupSourcePreferences == original.backupSourcePreferences)
        println("Android Kotlin serializer accepted the iOS export; metadata/progress/bookmarks/history/categories/preferences/tracking preserved.")
    }
}
''')
(BUILD / "IndexCheck.kt").write_text('''
import eu.kanade.tachiyomi.extension.api.ExtensionIndexDto
import kotlinx.serialization.protobuf.ProtoBuf
import java.io.File
import java.util.zip.GZIPInputStream
import org.json.*
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
fun main(args: Array<String>) {
    val raw=File(args[0]).readBytes()
    val data=if(raw[0]==0x1f.toByte() && raw[1]==0x8b.toByte()) GZIPInputStream(raw.inputStream()).readBytes() else raw
    val index=ProtoBuf.decodeFromByteArray(ExtensionIndexDto.serializer(),data)
    val entries=JSONArray()
    index.extensionList!!.extensions.forEach { extension ->
        entries.put(JSONObject().put("name",extension.name).put("packageName",extension.packageName)
            .put("versionCode",extension.versionCode).put("versionName",extension.versionName)
            .put("resources",JSONObject().put("apkUrl",extension.resources!!.apkUrl)).put("icon",extension.resources.iconUrl))
    }
    println(entries.toString())
}
''')
compiler_cp = os.pathsep.join(map(str, [compiler, stdlib, reflect, coroutines, annotations]))
subprocess.run([str(JAVA), "-cp", compiler_cp, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
                "-classpath", cp, f"-Xplugin={plugin}", "-d", str(BUILD / "schema.jar"), str(BUILD / "Schemas.kt"), str(BUILD / "Check.kt"), str(BUILD / "IndexCheck.kt"),
                str(ROOT / "app/src/main/java/eu/kanade/tachiyomi/extension/api/ExtensionIndexDto.kt")], check=True)
runtime_cp = str(BUILD / "schema.jar") + os.pathsep + cp
subprocess.run([str(JAVA), "-cp", runtime_cp, "CheckKt", "create", str(BUILD / "android.tachibk")], check=True)
(BUILD / "BackupCheck.java").write_text('''
import yokai.AndroidBackup;
import org.json.*;
public class BackupCheck {
    public static void main(String[] args) throws Exception {
        JSONObject value=AndroidBackup.read(args[0]);
        value.put("path",args[1]);
        JSONArray names=new JSONArray(), list=value.getJSONArray("categoryList");for(int i=0;i<list.length();i++)names.put(list.getJSONObject(i).getString("name"));
        value.put("categoryNames",names);
        JSONObject source=new JSONObject().put("id","-9223372036854775000").put("name","测试源");
        value.put("sources",new JSONArray().put(source));
        AndroidBackup.write(value);
        JSONObject again=AndroidBackup.read(args[1]);
        JSONObject book=again.getJSONArray("manga").getJSONObject(0);
        if(!book.getString("source").equals("-9223372036854775000"))throw new AssertionError("64-bit source ID changed");
        if(book.getJSONArray("chapters").getJSONObject(0).getInt("lastPage")!=44)throw new AssertionError("progress changed");
    }
}
''')
subprocess.run([str(JAVAC), "--release", "17", "-cp", str(COMPAT), "-d", str(BUILD),
                str(ROOT / "ios/Runtime/java/yokai/AndroidBackup.java"), str(BUILD / "BackupCheck.java")], check=True)
subprocess.run([str(JAVA), "-cp", str(BUILD) + os.pathsep + str(COMPAT), "BackupCheck", str(BUILD / "android.tachibk"), str(BUILD / "ios.tachibk")], check=True)
subprocess.run([str(JAVA), "-cp", runtime_cp, "CheckKt", "check", str(BUILD / "ios.tachibk")], check=True)
(BUILD / "ReadIndex.java").write_text('import yokai.RepositoryIndex; public class ReadIndex { public static void main(String[] args)throws Exception{System.out.println(RepositoryIndex.read(args[0]));}}')
subprocess.run([str(JAVAC), "--release", "17", "-cp", str(COMPAT), "-d", str(BUILD),
                str(ROOT / "ios/Runtime/java/yokai/AndroidBackup.java"), str(ROOT / "ios/Runtime/java/yokai/RepositoryIndex.java"), str(BUILD / "ReadIndex.java")], check=True)
for index in (ROOT / "ios/build/repo-check").glob("*.pb"):
    original = subprocess.check_output([str(JAVA), "-cp", runtime_cp, "IndexCheckKt", str(index)], text=True)
    ported = subprocess.check_output([str(JAVA), "-cp", str(BUILD) + os.pathsep + str(COMPAT), "ReadIndex", str(index)], text=True)
    assert json.loads(original) == json.loads(ported), f"Index parser differs from Android: {index}"
    print(f"{index.stem}: {len(json.loads(ported))} extension records match Android's original protobuf decoder.")
