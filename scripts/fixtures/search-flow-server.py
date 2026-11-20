"""Synthetic HTTP book sources for the LegadoSearchFlowUITests scheme.

The slow source keeps the first search active after the fast source's last row
is visible. This reproduces pagination depending only on that row's onAppear.
"""

import http.server
import json
import threading
import time
import urllib.parse
import uuid

BASE_URL = "http://127.0.0.1:18764"
CHAPTERS = [
    ("分页回归第一章", "这是搜索分页回归的合成正文，用于确认第二页结果能够打开阅读。"),
    ("渡口", "船家在渡口拾到了那枚铜钱。"),
    ("落日", "旧渡口的太阳沉入了水中。"),
]


class Fixture(http.server.BaseHTTPRequestHandler):
    failed_once = set()
    retry_lock = threading.Lock()

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = parsed.path.strip("/").split("/")
        if parsed.path == "/source.json":
            source = {
                "bookSourceUrl": BASE_URL + "/search-flow/fast",
                "bookSourceName": "搜索分页回归源",
                "bookSourceGroup": "00 阅读回归",
                "enabled": True,
                "searchUrl": BASE_URL + "/search?page={{page}}&key={{key}}",
                "ruleSearch": {"bookList": "$.books", "name": "$.name", "author": "$.author", "bookUrl": "$.url"},
                "ruleBookInfo": {"name": "$.name", "author": "$.author", "tocUrl": "$.toc"},
                "ruleToc": {"chapterList": "$.chapters", "chapterName": "$.name", "chapterUrl": "$.url"},
                "ruleContent": {"content": "$.content"},
                "ruleReview": {"reviewUrl": "{{chapter.url}}/comments", "reviewList": "$.comments",
                               "contentRule": "$.body", "authorRule": "$.author", "idRule": "$.id",
                               "nextReviewUrl": "$.next"},
            }
            slow = dict(source, bookSourceUrl=BASE_URL + "/search-flow/slow", bookSourceName="搜索延迟回归源", searchUrl=BASE_URL + "/slow")
            payload = [source, slow]
        elif parsed.path == "/slow":
            time.sleep(3)
            payload = {"books": []}
        elif parsed.path == "/search":
            page = int(query.get("page", ["1"])[0])
            names = {1: "迁移回归第一页", 2: "迁移回归第二页"}
            # Isolate persisted reading positions and the one-shot retry between test runs.
            payload = {"books": [{"name": names[page], "author": "测试作者",
                                  "url": BASE_URL + f"/book/{uuid.uuid4().hex}/{page}"}] if page in names else []}
        elif len(parts) == 3 and parts[0] == "book":
            payload = {"name": "迁移回归第二页", "author": "测试作者", "toc": BASE_URL + f"/toc/{parts[1]}"}
        elif len(parts) == 2 and parts[0] == "toc":
            payload = {"chapters": [
                {"name": chapter[0], "url": BASE_URL + f"/chapter/{parts[1]}/{number}"}
                for number, chapter in enumerate(CHAPTERS, 1)
            ]}
        elif len(parts) == 3 and parts[0] == "chapter" and parts[2] in ("1", "2", "3"):
            payload = {"content": CHAPTERS[int(parts[2]) - 1][1]}
        elif len(parts) == 4 and parts[0] == "chapter" and parts[3] == "comments":
            second_page = query.get("page") == ["2"]
            if parts[2] == "2" or second_page:
                with self.retry_lock:
                    first_request = self.path not in self.failed_once
                    self.failed_once.add(self.path)
                if first_request:
                    self.send_error(503, "Temporarily unavailable")
                    return
            if parts[2] == "1":
                first = {"id": "a1", "author": "听雨", "body": "开头埋下的伏笔是那枚铜钱。"}
                if second_page:
                    payload = {"comments": [first, {"id": "a2", "author": "拾秋", "body": "雨夜的细节让我记住了这个开头。"}]}
                else:
                    payload = {"comments": [first], "next": parsed.path + "?page=2"}
            elif parts[2] == "2":
                payload = {"comments": [{"id": "b1", "author": "渡江人", "body": "船家的动作正好呼应了第一章。"}]}
            elif parts[2] == "3":
                payload = {"comments": []}
            else:
                self.send_error(404)
                return
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
