package eu.kanade.tachiyomi.extension.zh.huakacomic

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceScreen
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import keiyoushi.annotation.Source
import keiyoushi.network.get
import keiyoushi.network.rateLimit
import keiyoushi.source.KeiSource
import keiyoushi.utils.extractNextJs
import keiyoushi.utils.firstInstanceOrNull
import keiyoushi.utils.getPreferencesLazy
import keiyoushi.utils.parseAs
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.CacheControl
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import java.io.IOException

@Source
abstract class Huakacomic :
    KeiSource(),
    ConfigurableSource {

    private val preferences by getPreferencesLazy()
    private val popularCursor = Cursor()
    private val latestCursor = Cursor()
    private val searchCursor = Cursor()

    override fun OkHttpClient.Builder.configureClient() = rateLimit(2)

    override fun getHomeUrl() = "$baseUrl/zh-CN"

    override suspend fun getPopularManga(page: Int): MangasPage = getListing(
        page,
        apiUrl("engagement/v2/leaderboards")
            .addQueryParameter("type", "reads")
            .addQueryParameter("window", "24h")
            .addQueryParameter("pageSize", "25")
            .build(),
        popularCursor,
    )

    override suspend fun getLatestUpdates(page: Int): MangasPage = getListing(
        page,
        apiUrl("comics").addQueryParameter("sort", "updated").addQueryParameter("pageSize", "25").build(),
        latestCursor,
    )

    override suspend fun getSearchMangaList(page: Int, query: String, filters: FilterList): MangasPage {
        val status = filters.firstInstanceOrNull<StatusFilter>()?.value.orEmpty()
        if (query.isBlank() && status.isEmpty()) return getPopularManga(page)

        val url = apiUrl("comic-search")
            .addQueryParameter("sort", filters.firstInstanceOrNull<SortFilter>()?.value ?: "relevance")
            .addQueryParameter("pageSize", "25")
            .apply {
                if (query.isNotBlank()) addQueryParameter("query", query.trim())
                if (status.isNotEmpty()) addQueryParameter("finished", status)
            }
            .build()
        return getListing(page, url, searchCursor)
    }

    // Keep only the next cursor per feed; replay pages for out-of-sequence requests.
    private suspend fun getListing(page: Int, url: HttpUrl, cursor: Cursor): MangasPage = cursor.mutex.withLock {
        var currentPage = 1
        var token: String? = null
        if (page > 1 && cursor.url == url && cursor.page == page) {
            currentPage = page
            token = cursor.token ?: return@withLock MangasPage(emptyList(), false)
        }

        var result: ComicList
        do {
            val requestUrl = url.newBuilder().apply {
                token?.let { addQueryParameter("pageToken", it) }
            }.build()
            result = getApi<ComicList>(requestUrl)
            token = result.nextPageToken?.takeIf(String::isNotEmpty)
            if (currentPage < page && token == null) return@withLock MangasPage(emptyList(), false)
        } while (currentPage++ < page)

        cursor.url = url
        cursor.page = page + 1
        cursor.token = token
        MangasPage(result.toMangas(), token != null)
    }

    override fun getMangaUrl(manga: SManga) = "$baseUrl/zh-CN/comics/${manga.url}"

    override fun getChapterUrl(chapter: SChapter) = "$baseUrl/zh-CN/comics/${chapter.url}"

    override suspend fun getMangaByUrl(url: HttpUrl): SManga? {
        if (url.host != baseUrl.toHttpUrl().host) return null
        val segments = url.pathSegments
        if (segments.getOrNull(1) != "comics" || segments.first() !in listOf("zh-CN", "zh-hant", "en")) return null
        val identifier = segments.getOrNull(2) ?: return null
        val comicId = when {
            MONGO_ID.matches(identifier) -> identifier
            HUA_CODE.matches(identifier) -> client.get(url, cacheControl = CacheControl.FORCE_NETWORK).extractNextJs<ComicReference> {
                it is JsonObject && "comicId" in it && "initialEpisodes" in it
            }?.comicId ?: throw IOException("无法读取花咔漫画编号")
            else -> return null
        }
        return getApi<ComicDetail>(apiUrl("comics/$comicId").build()).comic.toSManga()
    }

    override suspend fun fetchMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate = coroutineScope {
        val details = async {
            if (fetchDetails) getApi<ComicDetail>(apiUrl("comics/${manga.url}").build()).comic.toSManga() else manga
        }
        val chapterList = async { if (fetchChapters) getChapters(manga) else chapters }
        SMangaUpdate(details.await(), chapterList.await())
    }

    private suspend fun getChapters(manga: SManga): List<SChapter> {
        val url = apiUrl("episodes")
            .addQueryParameter("comicId", manga.url)
            .addQueryParameter("sortOrder", "desc")
            .addQueryParameter("pageSize", "25")
            .build()
        val episodes = mutableListOf<Episode>()
        var token: String? = null
        do {
            val requestUrl = url.newBuilder().apply {
                token?.let { addQueryParameter("pageToken", it) }
            }.build()
            val result = getApi<EpisodeList>(requestUrl)
            episodes.addAll(result.episodes)
            token = result.nextPageToken?.takeIf(String::isNotEmpty)
        } while (token != null)
        return episodes.sortedByDescending { it.order }.map { it.toSChapter(manga.url) }
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val url = apiUrl("comic-pages")
            .addQueryParameter("episodeId", chapter.url.substringAfterLast('/'))
            .addQueryParameter("pageSize", "25")
            .addQueryParameter("mediaSize", preferences.getString(IMAGE_QUALITY, "read"))
            .build()
        val pages = mutableListOf<Page>()
        var token: String? = null
        do {
            val requestUrl = url.newBuilder().apply {
                token?.let { addQueryParameter("pageToken", it) }
            }.build()
            val result = getApi<ComicPageList>(requestUrl)
            result.pages.forEach { pages.add(Page(pages.size, imageUrl = it.mediaUrl)) }
            token = result.nextPageToken?.takeIf(String::isNotEmpty)
        } while (token != null)
        return pages
    }

    override fun getFilterList(data: JsonElement?) = FilterList(SortFilter(), StatusFilter())

    override fun setupPreferenceScreen(screen: PreferenceScreen) {
        val context = screen.context
        // The extension API stub omits Preference's Context constructor.
        Preference::class.java.getConstructor(Context::class.java).newInstance(context).apply {
            title = "登录哔咔 ID"
            summary = "在 WebView 中完成花咔漫画登录，返回后刷新漫画源；会话过期时再次登录"
            setOnPreferenceClickListener {
                val intent = Intent().apply {
                    component = ComponentName(context, "eu.kanade.tachiyomi.ui.webview.WebViewActivity")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra("url_key", "$baseUrl/zh-CN/login")
                    putExtra("source_key", id)
                    putExtra("title_key", "登录花咔漫画")
                }
                try {
                    context.startActivity(intent)
                } catch (_: ActivityNotFoundException) {
                    Toast.makeText(context, "请从漫画源打开 WebView，使用哔咔 ID 登录", Toast.LENGTH_LONG).show()
                }
                true
            }
        }.let(screen::addPreference)

        ListPreference(screen.context).apply {
            key = IMAGE_QUALITY
            title = "图片质量"
            entries = arrayOf("标准", "高清")
            entryValues = arrayOf("read", "read_hd")
            setDefaultValue("read")
        }.let(screen::addPreference)
    }

    private fun apiUrl(path: String) = "$baseUrl/api/bff/$path".toHttpUrl().newBuilder()

    private suspend inline fun <reified T> getApi(url: HttpUrl): T = client.get(url, cacheControl = CacheControl.FORCE_NETWORK, ensureSuccess = false)
        .parseAs<ApiResponse<T>>().getData()

    private class Cursor {
        val mutex = Mutex()
        var url: HttpUrl? = null
        var page = 1
        var token: String? = null
    }

    companion object {
        private const val IMAGE_QUALITY = "image_quality"
        private val MONGO_ID = Regex("[a-fA-F0-9]{24}")
        private val HUA_CODE = Regex("HC[0-9]{7}")
    }
}
