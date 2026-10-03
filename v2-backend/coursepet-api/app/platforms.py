# MARK: - 作业平台协议客户端（服务器轮询拉作业）
# 学习通（超星）：纯协议全自动——AES-CBC 账密登录 → 课程列表 → 每门课作业列表。
#   登录/接口细节逆向自 yatori-go-core（api/xuexitong）：
#   - POST passport2.chaoxing.com/fanyalogin，key=iv="u2oh6Vu^HWe4_AES" CBC+PKCS7，
#     uname/password 分别加密后 base64；成功返回 JSON status=true，凭 Cookie 会话
#   - GET mooc1-api.chaoxing.com/mycourse/backclazzdata（课程，channelList 树）
#   - GET mooc1-api.chaoxing.com/work/task-list?courseId&classId&cpi（作业，HTML）
#     结构：ul.nav li[data=跳转URL]，div>p=标题，span[0]=状态，span[1]=剩余时间
# 智慧树：账密登录强制网易易盾滑块验证（逆向自 z5882852/zhihuishu-script 确认），
#   纯协议无法全自动——绑定端点直接拒绝并说明，避免假绑定。
# TLS 指纹：优先 curl_cffi 模拟 Chrome，未安装降级 httpx（学习通老接口风控较松）。
import hashlib
import html as html_mod
import json
import random
import re
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

_TZ_BJ = ZoneInfo("Asia/Shanghai")

# ── 学习通客户端参数（照抄 yatori-go-core，签名 UA 是过风控的关键）──
_AES_KEY = b"u2oh6Vu^HWe4_AES"
_SCHILD_SALT = "(schild:ipL$TkeiEmfy1gTXb2XHrdLN0a@7c^vu)"
_DEVICE = "MI10"
_APP_VERSION = "6.7.2"
_BUILD = "10941_314"
_IMEI = "".join(random.choices("0123456789abcdef", k=16))


def _mobile_ua() -> str:
    """学习通安卓端签名 UA：schild 字段是固定盐拼接串的 md5，缺了会被风控断连"""
    schild = hashlib.md5(" ".join([
        _SCHILD_SALT,
        f"(device:{_DEVICE})",
        "Language/zh_CN",
        f"com.chaoxing.mobile/ChaoXingStudy_3_{_APP_VERSION}_android_phone_{_BUILD}",
        f"(@Kalimdor)_{_IMEI}",
    ]).encode()).hexdigest()
    return " ".join([
        f"Mozilla/5.0 (Linux; Android 16; {_DEVICE} Build/OPM1.171019.019; wv)",
        "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/71.0.3578.99 Mobile Safari/537.36",
        f"(schild:{schild})",
        f"(device:{_DEVICE})",
        "Language/zh_CN",
        f"com.chaoxing.mobile/ChaoXingStudy_3_{_APP_VERSION}_android_phone_{_BUILD}",
        f"(@Kalimdor)_{_IMEI}",
    ])


# ── HTTP 会话（curl_cffi 优先，httpx 降级）────────────
try:
    from curl_cffi import requests as _cffi
    _HAS_CFFI = True
except ImportError:  # pragma: no cover
    _HAS_CFFI = False


class _Session:
    """统一封装：用 Session 对象自动管理 Cookie（登录 Set-Cookie → 后续请求自动带上）。
    不手动拼 cookie 串——各家库的 Cookies 对象版本行为有差异，实测会踩
    'str' object has no attribute '_cookies_lock' 这类坑（2026-10-04 真机绑定实录）。"""

    def __init__(self) -> None:
        self._headers = {"User-Agent": _mobile_ua(), "Accept-Language": "zh_CN"}
        if _HAS_CFFI:
            self._client = _cffi.Session(
                headers=self._headers, impersonate="chrome120", timeout=20)
        else:
            import httpx
            self._client = httpx.Client(
                timeout=20, follow_redirects=True, headers=self._headers)

    def get(self, url: str) -> tuple[int, str]:
        r = self._client.get(url)
        return r.status_code, r.text

    def post_form(self, url: str, data: dict) -> tuple[int, str]:
        r = self._client.post(url, data=data)
        return r.status_code, r.text


class PlatformError(Exception):
    """平台交互异常（网络/解析）——账号状态标 error"""


class AuthError(PlatformError):
    """登录失败/失效——账号状态标 auth_failed，提示用户重新绑定"""


class UnsupportedPlatform(PlatformError):
    """平台暂不支持全自动（智慧树滑块验证）"""


# ── 学习通：AES-CBC/PKCS7 加密（依赖 pycryptodome）────
def _cx_encrypt(text: str) -> str:
    import base64
    from Crypto.Cipher import AES
    cipher = AES.new(_AES_KEY, AES.MODE_CBC, iv=_AES_KEY)  # 学习通固定 key 即 iv
    data = text.encode()
    data += bytes([16 - len(data) % 16]) * (16 - len(data) % 16)  # PKCS7
    return base64.b64encode(cipher.encrypt(data)).decode()


# ── 学习通：登录 → 课程 → 作业 ────────────────────────
def _cx_login(sess: _Session, username: str, password: str) -> None:
    code, body = sess.post_form("https://passport2.chaoxing.com/fanyalogin", {
        "fid": "-1",
        "uname": _cx_encrypt(username),
        "password": _cx_encrypt(password),
        "refer": "http%3A%2F%2Fi.mooc.chaoxing.com",
        "t": "true",
        "forbidotherlogin": "0",
        "validate": "",
        "doubleFactorLogin": "0",
        "independentId": "0",
        "independentNameId": "0",
    })
    if "很抱歉，您所浏览的页面暂时不能访问" in body:
        raise AuthError("触发学习通风控，请稍后再试")
    try:
        obj = json.loads(body)
    except ValueError as e:
        raise PlatformError(f"登录响应异常（HTTP {code}）") from e
    if not obj.get("status"):
        msg = str(obj.get("msg2") or obj.get("msg") or "用户名或密码错误")
        raise AuthError(msg)


def _cx_courses(sess: _Session) -> list[dict]:
    """backclazzdata → 开课中的课程列表 [{course_id, class_id, cpi, name}]"""
    code, body = sess.get("https://mooc1-api.chaoxing.com/mycourse/backclazzdata")
    if code == 403 or "输入验证码" in body:
        raise AuthError("学习通要求验证码，请在 App 里登录一次后再绑定")
    try:
        obj = json.loads(body)
    except ValueError as e:
        raise PlatformError("课程列表解析失败") from e
    courses: list[dict] = []
    seen: set[str] = set()
    for channel in obj.get("channelList") or []:
        content = channel.get("content") or {}
        if content.get("state") != 0:  # 非开课状态（已结课）不拉作业
            continue
        for course in ((content.get("course") or {}).get("data") or []):
            square = course.get("courseSquareUrl") or ""
            m_cid = re.search(r"courseId=(\d+)", square)
            m_clz = re.search(r"classId=(\d+)", square)
            if not (m_cid and m_clz):
                continue
            class_id = m_clz.group(1)
            if class_id in seen:
                continue
            seen.add(class_id)
            courses.append({
                "course_id": m_cid.group(1),
                "class_id": class_id,
                "cpi": str(channel.get("cpi") or ""),
                "name": str(course.get("name") or "").strip(),
            })
            break
    return courses


_RE_LI = re.compile(r'<li[^>]*\bdata="([^"]+)"[^>]*>(.*?)</li>', re.S)
_RE_P = re.compile(r"<p[^>]*>(.*?)</p>", re.S)
_RE_SPAN = re.compile(r"<span[^>]*>(.*?)</span>", re.S)
_RE_TAG = re.compile(r"<[^>]+>")
_RE_DAYS = re.compile(r"(\d+)\s*天")
_RE_HOURS = re.compile(r"(\d+)\s*(?:小?时)")
_RE_MINUTES = re.compile(r"(\d+)\s*分")
_DONE_HINTS = ("已提交", "已完成", "已批阅", "已过期", "已结束")


def _parse_remain(text: str) -> timedelta | None:
    """'剩余2天5小时' / '3天后截止' → 时长；解析不出返回 None"""
    m_d, m_h, m_mi = _RE_DAYS.search(text), _RE_HOURS.search(text), _RE_MINUTES.search(text)
    if not (m_d or m_h or m_mi):
        return None
    return timedelta(
        days=int(m_d.group(1)) if m_d else 0,
        hours=int(m_h.group(1)) if m_h else 0,
        minutes=int(m_mi.group(1)) if m_mi else 0,
    )


def _parse_works_html(body: str) -> list[dict]:
    """task-list HTML → [{key, title, status_text, remain_text}]（纯解析，便于单测）"""
    works: list[dict] = []
    for raw_url, inner in _RE_LI.findall(body):
        if "taskrefId" not in raw_url and "workId" not in raw_url:
            continue  # 跳过非作业条目（章节任务等）
        p_m = _RE_P.search(inner)
        spans = [html_mod.unescape(_RE_TAG.sub("", s)).strip() for s in _RE_SPAN.findall(inner)]
        title = html_mod.unescape(_RE_TAG.sub("", p_m.group(1))).strip() if p_m else ""
        if not title:
            title = spans[0] if spans else ""
        status_text = spans[0] if len(spans) > (1 if p_m else 0) else ""
        remain_text = spans[-1] if len(spans) > 1 else ""
        # external key：taskrefId 优先，退化用 URL 指纹
        m_task = re.search(r"taskrefId=(\d+)", html_mod.unescape(raw_url))
        ext_key = m_task.group(1) if m_task else hashlib.md5(raw_url.encode()).hexdigest()[:16]
        works.append({
            "key": f"chaoxing:{ext_key}",
            "title": title[:120],
            "status_text": status_text,
            "remain_text": remain_text,
        })
    return works


def _cx_works(sess: _Session, course: dict) -> list[dict]:
    """拉单门课的作业列表"""
    url = ("https://mooc1-api.chaoxing.com/work/task-list"
           f"?courseId={course['course_id']}&classId={course['class_id']}&cpi={course['cpi']}")
    code, body = sess.get(url)
    if code >= 400:
        raise PlatformError(f"作业列表拉取失败（HTTP {code}）")
    return _parse_works_html(body)


def sync_chaoxing(username: str, password: str) -> tuple[list[dict], bool]:
    """登录学习通并拉全部课程的作业。返回 (items, complete)

    items=[{key, title, courseName, dueDate, isDone}]；
    complete=False 表示有课程拉取失败（结果仍可用，但调用方不应据此清理陈旧行）。
    dueDate：平台只给"剩余时间"相对量，按拉取时刻换算成北京时间的绝对截止。"""
    sess = _Session()
    _cx_login(sess, username, password)
    courses = _cx_courses(sess)
    now_bj = datetime.now(_TZ_BJ).replace(tzinfo=None)
    out: list[dict] = []
    complete = True
    for course in courses[:30]:  # 上限兜底：防止异常账号课程过多拖垮轮询
        try:
            for w in _cx_works(sess, course):
                done = any(h in w["status_text"] for h in _DONE_HINTS)
                remain = _parse_remain(w["remain_text"])
                due = (now_bj + remain) if remain else None
                out.append({
                    "key": w["key"],
                    "title": w["title"],
                    "courseName": course["name"] or None,
                    "dueDate": due.strftime("%Y-%m-%d %H:%M") if due else None,
                    "isDone": done,
                })
        except PlatformError:
            complete = False  # 单课程失败不拖垮整体，但标记不完整
    return out, complete


def sync_zhihuishu(username: str, password: str) -> tuple[list[dict], bool]:
    """智慧树：账密登录强制网易易盾滑块（逆向确认），协议层无法全自动。"""
    raise UnsupportedPlatform(
        "智慧树登录需要滑块验证，暂不支持自动同步；作业先手动记，后续版本适配")


def sync_platform(platform: str, username: str, password: str) -> tuple[list[dict], bool]:
    if platform == "chaoxing":
        return sync_chaoxing(username, password)
    if platform == "zhihuishu":
        sync_zhihuishu(username, password)
        return [], True  # 不可达：sync_zhihuishu 必抛 UnsupportedPlatform
    raise UnsupportedPlatform(f"未知平台：{platform}")
