# MARK: - 取件短信/文本解析（翻译自 ParcelSmsParser.swift，纯正则零网络零 token）
# 设计原则不变：解析失败返回 None 由调用方兜底，绝不猜数据。
import re

# 常见驿站/代收点关键词（长词在前，避免"菜鸟"截断"菜鸟驿站"）
_STATION_KEYWORDS = [
    "菜鸟驿站", "妈妈驿站", "菜鸟", "兔喜生活", "兔喜", "丰巢",
    "京东派", "顺丰驿站", "快递超市", "驿站", "代收点", "快递柜",
]

# 取件码识别：
# 1) 优先取"取件码/提货码"关键词后面的 X-X-XXXX 三段式
# 2) 兜底匹配全文首个三段式（负向断言排除 2024-10-28 这类日期）
_PATTERNS = [
    r"(?:取件码|提货码)[^0-9]{0,8}(\d{1,4}[-\-－—–]\d{1,4}[-\-－—–]\d{1,6})",
    r"(?<!\d)(?!(?:19|20)\d{2}[-－])(\d{1,4}[-\-－—–]\d{1,4}[-\-－—–]\d{1,6})(?!\d)",
]

# 驿站名截取的终止字符（标点/空白/括号）
_STOP_CHARS = set("，。,、；;！!？?\n\t 【】[]\u201c\u201d")


def parse_sms(text: str) -> tuple[str, str | None] | None:
    """从短信文本解析 (取件码, 驿站名)；至少识别出取件码才算成功"""
    if not text:
        return None

    code: str | None = None
    for pattern in _PATTERNS:
        m = re.search(pattern, text)
        if m:
            code = m.group(1).replace("－", "-").replace("—", "-").replace("–", "-")
            break
    if code is None:
        return None

    # 驿站名：取出现位置最靠前的关键词，从关键词起向后截取到标点/空白为止（最长 14 字）
    station: str | None = None
    best_pos = min(
        (text.find(kw) for kw in _STATION_KEYWORDS if kw in text),
        default=-1,
    )
    if best_pos >= 0:
        end = best_pos
        while end < len(text) and end - best_pos < 14 and text[end] not in _STOP_CHARS:
            end += 1
        name = text[best_pos:end].strip()
        # 括号内的店名保留（如"菜鸟驿站(东门店)"），去掉首尾括号后非空才用
        if name:
            station = name
    return (code, station)
