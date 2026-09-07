# 零缓存静态服务器：解决浏览器启发式缓存导致加载旧版 JS 的问题
# 绑定 0.0.0.0 以便同一 WiFi 下的 iPhone 通过局域网访问
# 用法: python tools/serve.py 8017
import sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8017
ThreadingHTTPServer(('0.0.0.0', port), NoCacheHandler).serve_forever()
