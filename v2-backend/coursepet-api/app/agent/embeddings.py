# MARK: - 文本向量化（模式 7 RAG 的地基层）
# 现状：agnes 网关没有 embeddings 通道（/v1/embeddings 对所有模型名都返回 model_not_found），
# 因此用本地零依赖方案：字符/词组 n-gram 哈希到 256 维稀疏计数向量 + L2 归一化（哈希嵌入）。
# 对中文课程资料的"关键词/短语"检索效果够用；以后接入真正的 embedding 模型
# 只需替换 embed() 一个函数（向量维度变了需同步迁移 course_docs 表）。
import hashlib
import math
import re

DIM = 256
# 中文字逐字切 + 英文/数字按词切，再组合出二元组（同时抓单字与短语）
_TOKEN_RE = re.compile(r"[\u4e00-\u9fff]|[a-z0-9]+")


def embed(text: str) -> list[float]:
    """文本 → 256 维 L2 归一化向量（哈希嵌入，无外部依赖、结果确定性可复现）"""
    vec = [0.0] * DIM
    tokens = _TOKEN_RE.findall((text or "").lower())
    grams = tokens + [tokens[i] + tokens[i + 1] for i in range(len(tokens) - 1)]
    if not grams:
        return vec
    for g in grams:
        h = int(hashlib.md5(g.encode("utf-8")).hexdigest(), 16)
        idx = h % DIM                    # 落桶位置
        sign = 1.0 if (h >> 8) & 1 else -1.0   # 用更高位的比特决定正负（避开与 idx 的低位关联）
        vec[idx] += sign
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]
