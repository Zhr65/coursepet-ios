# MARK: - 网页浏览（Muse 式"像真人一样上网看资料"，只读）
# 双通道抓取，产出统一格式（标题 + 正文 Markdown）：
#   1. Playwright + Chromium（VM 上 pip install playwright && playwright install chromium
#      后自动启用）：能渲染 JS 动态页面（SPA/需要执行脚本的站点）
#   2. httpx 静态抓取（零额外依赖兜底）：Playwright 未安装或启动失败时自动退回，
#      新闻/文档/博客等静态页面足够用
# 安全边界：只读不交互——不登录、不填表单、不下单；拒绝内网/环回地址（防 SSRF）。
import ipaddress
import re
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

import httpx

_MAX_CHARS = 8000     # 喂给 LLM 的正文上限（超出按行边界截断）
_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
       "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# 噪声标签：整体剔除（含内部文本）
_SKIP_TAGS = {"script", "style", "noscript", "svg", "iframe", "template", "select", "button"}
# 块级标签：前后补换行，让正文有基本分段
_BLOCK_TAGS = {"p", "div", "section", "article", "aside", "header", "footer", "main", "nav",
               "ul", "ol", "table", "tr", "blockquote", "pre", "figure", "figcaption",
               "hr", "br", "form", "dl", "dt", "dd"}
_HEADING_TAGS = {"h1": "# ", "h2": "## ", "h3": "### ",
                 "h4": "#### ", "h5": "##### ", "h6": "###### "}


class _MarkdownHarvester(HTMLParser):
    """HTML → 粗粒度 Markdown：标题加 #、列表加 -、链接转 [text](href)，其余拼正文。"""

    def __init__(self, base_url: str):
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.title = ""
        self.pieces: list[str] = []
        self._skip_depth = 0        # 处于 script/style 等噪声标签内的层级
        self._title_depth = 0       # 处于 <title> 内
        self._link_href: str | None = None
        self._link_buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "title":
            self._title_depth += 1
            return
        if tag in _SKIP_TAGS:
            self._skip_depth += 1
            return
        if self._skip_depth:
            return
        if tag in _HEADING_TAGS:
            self.pieces.append("\n\n" + _HEADING_TAGS[tag])
        elif tag == "li":
            self.pieces.append("\n- ")
        elif tag in _BLOCK_TAGS:
            self.pieces.append("\n")
        elif tag == "a":
            href = dict(attrs).get("href") or ""
            if href and not href.startswith(("#", "javascript:")):
                self._link_href = urljoin(self.base_url, href)
                self._link_buf = []

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "title":
            self._title_depth = max(0, self._title_depth - 1)
            return
        if tag in _SKIP_TAGS:
            self._skip_depth = max(0, self._skip_depth - 1)
            return
        if self._skip_depth:
            return
        if tag == "a" and self._link_href is not None:
            text = "".join(self._link_buf).strip()
            if text:
                self.pieces.append(f"[{text}]({self._link_href})")
            self._link_href = None
            self._link_buf = []
        elif tag in _HEADING_TAGS or tag in _BLOCK_TAGS:
            self.pieces.append("\n")

    def handle_data(self, data):
        if self._title_depth:
            self.title += data.strip()
            return
        if self._skip_depth:
            return
        if self._link_href is not None:
            self._link_buf.append(data)
        else:
            self.pieces.append(data)


def html_to_markdown(html: str, base_url: str) -> tuple[str, str]:
    """HTML → (标题, Markdown 正文)。噪声剔除、空白折叠、超长按行边界截断。"""
    harvester = _MarkdownHarvester(base_url)
    try:
        harvester.feed(html)
    except Exception:  # noqa: BLE001 —— 残缺 HTML 也尽力吐正文
        pass
    text = "".join(harvester.pieces)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)       # 折叠水平空白
    text = re.sub(r"\n{3,}", "\n\n", text).strip()   # 折叠连续空行
    if len(text) > _MAX_CHARS:
        cut = text.rfind("\n", 0, _MAX_CHARS)
        text = text[:cut if cut > 2000 else _MAX_CHARS] + "\n\n（正文过长，已截断）"
    return harvester.title.strip()[:100], text


def _reject_reason(url: str) -> str | None:
    """SSRF 边界：只放行公网 http(s)，拒绝内网/环回/链路本地地址"""
    try:
        parts = urlparse(url)
    except ValueError:
        return "这个链接格式不对，解析不了。"
    if parts.scheme not in ("http", "https"):
        return "只支持 http/https 网页链接。"
    host = (parts.hostname or "").lower()
    if not host:
        return "这个链接没有主机名，打不开。"
    if host == "localhost" or host.endswith((".localhost", ".internal", ".local")):
        return "这是内网地址，我不能访问。"
    try:
        ip = ipaddress.ip_address(host)
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            return "这是内网地址，我不能访问。"
    except ValueError:
        pass  # 普通域名，放行（DNS 级防护不做：个人项目、URL 只来自模型与用户）
    return None


async def _rendered_html(url: str) -> str | None:
    """Playwright 通道：返回 JS 渲染后的完整 HTML；未安装/启动失败返回 None 走兜底"""
    try:
        from playwright.async_api import async_playwright
    except ImportError:
        return None
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True, args=["--no-sandbox"])
            try:
                page = await browser.new_page(user_agent=_UA)
                await page.goto(url, timeout=20000, wait_until="domcontentloaded")
                return await page.content()
            finally:
                await browser.close()
    except Exception:  # noqa: BLE001 —— 渲染通道任何失败都降级静态抓取
        return None


async def _static_html(url: str) -> str:
    """httpx 兜底通道：直接抓 HTML（不执行 JS）"""
    async with httpx.AsyncClient(timeout=15, headers={"User-Agent": _UA},
                                 follow_redirects=True) as client:
        resp = await client.get(url)
        if resp.status_code >= 400:
            raise RuntimeError(f"网页返回了 {resp.status_code}，可能已失效或需要登录。")
        return resp.text


async def browse(url: str) -> str:
    """给工具层用的浏览入口：校验 URL → 双通道抓取 → 转 Markdown → 截断"""
    url = url.strip()
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    if reason := _reject_reason(url):
        return reason
    html = await _rendered_html(url)
    note = ""
    if html is None:
        try:
            html = await _static_html(url)
            note = "（未启用浏览器渲染，按静态页面抓取）"
        except Exception as e:  # noqa: BLE001
            return f"网页打不开：{e} 请确认链接是否正确，或稍后再试。"
    title, md = html_to_markdown(html, url)
    if not md:
        return "网页打开了，但没读到有效正文（可能是全动态渲染或反爬站点）。"
    return f"网页标题：{title or '（无标题）'}{note}\n\n{md}"
