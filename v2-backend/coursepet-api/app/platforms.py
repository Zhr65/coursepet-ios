# MARK: - 作业平台协议客户端（服务器轮询拉作业）
# 学习通（超星）：纯协议全自动——AES-CBC 账密登录 → 课程列表 → 每门课作业列表。
#   登录/接口细节逆向自 yatori-go-core（api/xuexitong）：
#   - POST passport2.chaoxing.com/fanyalogin，key=iv="u2oh6Vu^HWe4_AES" CBC+PKCS7，
#     uname/password 分别加密后 base64；成功返回 JSON status=true，凭 Cookie 会话
#   - GET mooc1-api.chaoxing.com/mycourse/backclazzdata（课程，channelList 树）
#   - GET mooc1-api.chaoxing.com/work/task-list?courseId&classId&cpi（作业，HTML）
#     结构：ul.nav li[data=跳转URL]，div>p=标题，span[0]=状态，span[1]=剩余时间
# 智慧树：账密登录强制网易易盾滑块验证（逆向自 z5882852/zhihuishu-script 确认），
#   纯协议不可行 → 走官方扫码登录（fuckZHS 实测纯 requests 可行）：
#   getLoginQrImg 出码 → 轮询 getLoginQrInfo（-1 未扫/0 已扫/1 确认得 oncePassword/
#   2 过期/3 取消）→ login?pwd= 跳板落 cookie → cookie 序列化加密存库长期复用。
#   作业链路（AES Key 逆向自页面 yxyz 函数，VermiIIi0n/fuckZHS zd_utils.py，
#   本地解密样例验证）：queryShareCourseInfo(HOME_KEY) 出课程 →
#   getStudentHomework(EXAM_KEY, flag=1 未提交 / 2 已提交) 出作业。
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

    def __init__(self, headers: dict | None = None) -> None:
        self._headers = {"User-Agent": _mobile_ua(), "Accept-Language": "zh_CN"}
        if headers:
            self._headers.update(headers)
        if _HAS_CFFI:
            self._client = _cffi.Session(
                headers=self._headers, impersonate="chrome120", timeout=20)
        else:
            import httpx
            self._client = httpx.Client(
                timeout=20, follow_redirects=True, headers=self._headers)

    @staticmethod
    def _wrap_net_error(e: Exception) -> Exception:
        """curl 47（30 次重定向仍不落地）多为平台对机房出口 IP 的风控，
        译成人话而不是把 curl 错误码甩给用户。"""
        if type(e).__name__ == "TooManyRedirects":
            return PlatformError("平台把请求反复重定向（疑似拦截了服务器出口 IP），请稍后再试")
        return e

    def get(self, url: str) -> tuple[int, str]:
        try:
            r = self._client.get(url)
        except Exception as e:  # noqa: BLE001 —— 统一翻译网络层异常
            raise self._wrap_net_error(e) from e
        return r.status_code, r.text

    def post_form(self, url: str, data: dict, follow: bool = True) -> tuple[int, str]:
        try:
            r = self._client.post(url, data=data, allow_redirects=follow)
        except Exception as e:  # noqa: BLE001
            raise self._wrap_net_error(e) from e
        # 不跟随重定向时精准识别学习通 IP 拦截页（passport403.html）
        if not follow and 300 <= r.status_code < 400 \
                and "passport403" in str(r.headers.get("Location") or ""):
            raise AuthError("学习通拦截了服务器出口 IP（机房 IP 限制），暂时无法直连，请稍后再试")
        return r.status_code, r.text

    # ── cookie 序列化（智慧树扫码登录后存库，轮询时恢复会话用）──
    def cookies_json(self) -> str:
        import http.cookiejar
        jar: http.cookiejar.CookieJar = self._client.cookies.jar
        rows = [{"name": c.name, "value": c.value, "domain": c.domain, "path": c.path}
                for c in jar]
        return json.dumps(rows, ensure_ascii=False)

    def load_cookies_json(self, data: str) -> None:
        import http.cookiejar
        jar: http.cookiejar.CookieJar = self._client.cookies.jar
        for item in json.loads(data):
            domain = str(item.get("domain") or "")
            jar.set_cookie(http.cookiejar.Cookie(
                version=0, name=item["name"], value=item["value"],
                port=None, port_specified=False,
                domain=domain, domain_specified=domain.startswith("."),
                domain_initial_dot=domain.startswith("."),
                path=item.get("path") or "/", path_specified=True,
                secure=False, expires=None, discard=True,
                comment=None, comment_url=None, rest={}, rfc2109=False))


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
    # follow=False：被 IP 风控拦截时学习通 302 到 passport403.html，
    # 不跟进重定向循环，第一时间给出可解释的报错
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
    }, follow=False)
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
    """智慧树：扫码绑定后的会话 cookie 复用拉作业（password 位置存 cookie JSON，
    由调用方 Fernet 解密还原）。cookie 失效抛 AuthError → 状态标 auth_failed，
    用户去设置页重新扫码（fuckZHS 实测 cookie 长期有效，重扫是低频事件）"""
    if not password.strip().startswith("["):
        raise AuthError("智慧树请使用扫码绑定（设置页 → 作业平台同步）")
    sess = _Session(headers=_ZHS_HEADERS)
    try:
        sess.load_cookies_json(password)
    except (ValueError, KeyError) as e:
        raise AuthError("智慧树会话数据损坏，请重新扫码绑定") from e
    _zhs_verify_session(sess)
    courses = _zhs_courses(sess)
    out: list[dict] = []
    complete = True
    for course in courses[:30]:
        try:
            out.extend(_zhs_works(sess, course))
        except PlatformError:
            complete = False  # 单课程失败不拖垮整体，但标记不完整
    return out, complete


# ── 智慧树：扫码登录 + 作业拉取 ────────────────────────
_ZHS_IV = b"1g3qqdh4jvbskb9x"
_ZHS_HOME_KEY = b"7q9oko0vqb3la20r"   # 学生首页/课程列表（onlineservice-api）
_ZHS_EXAM_KEY = b"onbfhdyvz8x7otrp"   # 考试/作业（studentexam-api）
_ZHS_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
    "Referer": "https://onlineweb.zhihuishu.com/",
    "Accept-Language": "zh-CN,zh;q=0.9",
}
_ZHS_TIME_KEYS = ("endTime", "endDateTime", "endDate", "homeworkEndTime",
                  "examEndTime", "overEndTime", "deadline")


def _zhs_secret(params: dict, key: bytes) -> str:
    """智慧树 secretStr：页面 yxyz 函数的还原——AES-CBC(固定 Key+IV)+PKCS7+base64。
    fuckZHS zd_utils.py 内置样例本地解密验证通过（参数明文是紧凑 JSON）。"""
    import base64
    from Crypto.Cipher import AES
    raw = json.dumps(params, separators=(",", ":"), ensure_ascii=False).encode()
    raw += bytes([16 - len(raw) % 16]) * (16 - len(raw) % 16)
    cipher = AES.new(key, AES.MODE_CBC, iv=_ZHS_IV)
    return base64.b64encode(cipher.encrypt(raw)).decode()


def _zhs_qr_create() -> tuple[_Session, str, str]:
    """生成扫码登录会话。返回 (会话, qrToken, 二维码PNG的base64)"""
    sess = _Session(headers=_ZHS_HEADERS)
    code, body = sess.get("https://passport.zhihuishu.com/qrCodeLogin/getLoginQrImg")
    try:
        obj = json.loads(body)
        return sess, str(obj["qrToken"]), str(obj["img"])
    except (ValueError, KeyError) as e:
        raise PlatformError(f"智慧树二维码获取失败（HTTP {code}）") from e


def _zhs_qr_poll(sess: _Session, qr_token: str) -> dict:
    """轮询扫码状态：status -1 未扫 / 0 已扫 / 1 确认（oncePassword）/ 2 过期 / 3 取消"""
    code, body = sess.get(
        "https://passport.zhihuishu.com/qrCodeLogin/getLoginQrInfo?qrToken=" + qr_token)
    try:
        obj = json.loads(body)
    except ValueError as e:
        raise PlatformError(f"扫码状态查询异常（HTTP {code}）") from e
    return {
        "status": int(obj.get("status", -99)),
        "msg": str(obj.get("msg") or ""),
        "oncePassword": obj.get("oncePassword"),
    }


def _zhs_qr_login(sess: _Session, once_password: str) -> tuple[str, str]:
    """oncePassword 换正式会话：passport 登录链 → studyservice 跳板 → 验活。
    返回 (cookie JSON, 账号昵称)，cookie 加密落库供轮询复用"""
    # 登录跳板（URL 格式照抄 zhs_api.py 实测可用的写法，含嵌套 service 参数）
    sess.get("https://passport.zhihuishu.com/login?pwd=" + once_password
             + "&service=https://onlineservice-api.zhihuishu.com/gateway/f/v1/login/gologin"
               "?fromurl=https%3A%2F%2Fonlineweb.zhihuishu.com%2F")
    # studyservice 域会话（考试 API 与视频页共用此跳板，多跳一次是廉价保险）
    sess.get("https://studyservice-api.zhihuishu.com/login/gologin"
             "?fromurl=https%3A%2F%2Fstudyh5.zhihuishu.com%2Fapp%2Fstuexamweb.html")
    nickname = _zhs_verify_session(sess)  # 验活失败会在这一步抛 AuthError
    return sess.cookies_json(), nickname


def _zhs_verify_session(sess: _Session) -> str:
    """会话验活：getLoginUserInfo 不需要加密。返回昵称/姓名，失效抛 AuthError"""
    code, body = sess.get(
        "https://onlineservice-api.zhihuishu.com/gateway/f/v1/login/getLoginUserInfo")
    try:
        obj = json.loads(body)
    except ValueError as e:
        raise PlatformError(f"智慧树登录态检查异常（HTTP {code}）") from e
    result = obj.get("result") or {}
    name = str(result.get("realName") or result.get("nickName") or "").strip()
    if not name and not result.get("uuid"):
        raise AuthError("智慧树登录已失效，请重新扫码绑定")
    return name[:60] or "智慧树用户"


def _zhs_courses(sess: _Session) -> list[dict]:
    """共享学分课列表（进行中）：queryShareCourseInfo → courseOpenDtos"""
    out: list[dict] = []
    for page_no in (1, 2, 3):  # 3 页 × 50 封顶，异常账号兜底
        code, body = sess.post_form(
            "https://onlineservice-api.zhihuishu.com/gateway/t/v1/student/course/share/queryShareCourseInfo",
            {"secretStr": _zhs_secret(
                {"status": 0, "pageNo": page_no, "pageSize": 50}, _ZHS_HOME_KEY)})
        try:
            obj = json.loads(body)
        except ValueError as e:
            raise PlatformError(f"智慧树课程列表解析失败（HTTP {code}）") from e
        if str(obj.get("status")) != "200":
            raise PlatformError("智慧树课程列表拉取失败（会话可能失效）")
        rows = (obj.get("result") or {}).get("courseOpenDtos") or []
        for r in rows:
            out.append({
                "course_id": str(r.get("courseId") or ""),
                "recruit_id": str(r.get("recruitId") or ""),
                "name": str(r.get("courseName") or r.get("courseOpenName")
                            or r.get("courseTitle") or "").strip(),
            })
        if len(rows) < 50:
            break
    return [c for c in out if c["course_id"] and c["recruit_id"]]


def _zhs_work_time(row: dict) -> str | None:
    """截止时间：字段名未知（作业列表响应未实测），按候选键逐一探测；
    兼容 epoch 毫秒/秒 与 'yyyy-MM-dd HH:mm' 字符串两种格式"""
    for key in _ZHS_TIME_KEYS:
        v = row.get(key)
        if v in (None, "", 0):
            continue
        if isinstance(v, (int, float)) or (isinstance(v, str) and v.isdigit()):
            try:
                ms = int(v)
                if ms < 10**12:
                    ms *= 1000  # 秒级时间戳容错
                return datetime.fromtimestamp(ms / 1000, _TZ_BJ).replace(
                    tzinfo=None).strftime("%Y-%m-%d %H:%M")
            except (ValueError, OSError):
                continue
        text = str(v).strip()[:16].replace("T", " ")
        return text if len(text) == 16 else None
    return None


def _zhs_works(sess: _Session, course: dict) -> list[dict]:
    """单门课作业列表：flag=1 未提交 + flag=2 已提交两个 tab 各拉一次再合并，
    出现在已提交列表的条目标 isDone（flag 语义来自 Online-Course-Assistant 页面逆向）"""
    rows: dict[str, dict] = {}
    submitted: set[str] = set()
    for flag in (1, 2):
        code, body = sess.post_form(
            "https://studentexam-api.zhihuishu.com/studentExam/gateway/t/v1/student/getStudentHomework",
            {"secretStr": _zhs_secret(
                {"courseId": course["course_id"], "flag": flag,
                 "pageNum": 0, "pageSize": 100, "recruitId": course["recruit_id"]},
                _ZHS_EXAM_KEY)})
        try:
            obj = json.loads(body)
        except ValueError as e:
            raise PlatformError(f"智慧树作业列表解析失败（HTTP {code}）") from e
        if str(obj.get("status")) != "200":
            raise PlatformError(f"智慧树作业列表拉取失败（status={obj.get('status')}）")
        for r in (obj.get("rt") or {}).get("studentHomeworkList") or []:
            wid = str(r.get("id") or r.get("examId") or "")
            if not wid:
                continue
            rows[wid] = r
            if flag == 2:
                submitted.add(wid)
    out: list[dict] = []
    for wid, r in rows.items():
        title = str(r.get("examName") or r.get("title") or "").strip()
        if not title:
            continue
        out.append({
            "key": f"zhihuishu:{wid}",
            "title": title[:120],
            "courseName": course["name"] or None,
            "dueDate": _zhs_work_time(r),
            "isDone": wid in submitted,
        })
    return out


def sync_platform(platform: str, username: str, password: str) -> tuple[list[dict], bool]:
    if platform == "chaoxing":
        return sync_chaoxing(username, password)
    if platform == "zhihuishu":
        return sync_zhihuishu(username, password)
    raise UnsupportedPlatform(f"未知平台：{platform}")
