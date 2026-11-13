"""Synthetic HTTP book sources for the LegadoSearchFlowUITests scheme.

The slow source keeps the first search active after the fast source's last row
is visible. This reproduces pagination depending only on that row's onAppear.
"""

import http.server
import json
import time
import urllib.parse

BASE_URL = "http://127.0.0.1:18764"


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/source.json":
            source = {
                "bookSourceUrl": BASE_URL,
                "bookSourceName": "搜索分页回归源",
                "enabled": True,
                "searchUrl": BASE_URL + "/search?page={{page}}&key={{key}}",
                "ruleSearch": {"bookList": "$.books", "name": "$.name", "author": "$.author", "bookUrl": "$.url"},
                "ruleBookInfo": {"name": "$.name", "author": "$.author", "tocUrl": "$.toc"},
                "ruleToc": {"chapterList": "$.chapters", "chapterName": "$.name", "chapterUrl": "$.url"},
                "ruleContent": {"content": "$.content"},
            }
            slow = dict(source, bookSourceUrl=BASE_URL + "/slow", bookSourceName="搜索延迟回归源", searchUrl=BASE_URL + "/slow")
            payload = [source, slow]
        elif parsed.path == "/slow":
            time.sleep(3)
            payload = {"books": []}
        elif parsed.path == "/search":
            page = int(query.get("page", ["1"])[0])
            names = {1: "迁移回归第一页", 2: "迁移回归第二页"}
            payload = {"books": [{"name": names[page], "author": "测试作者", "url": BASE_URL + f"/book/{page}"}] if page in names else []}
        elif parsed.path.startswith("/book/"):
            payload = {"name": "迁移回归第二页", "author": "测试作者", "toc": BASE_URL + "/toc"}
        elif parsed.path == "/toc":
            payload = {"chapters": [{"name": "分页回归第一章", "url": BASE_URL + "/chapter/1"}]}
        elif parsed.path == "/chapter/1":
            payload = {"content": "这是搜索分页回归的合成正文，用于确认第二页结果能够打开阅读。"}
        else:
            self.send_error(404)
            return
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", 18764), Fixture).serve_forever()
