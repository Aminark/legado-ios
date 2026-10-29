"""Local, synthetic RSS responses for the LegadoRSSFlowUITests scheme."""

import http.server
import json
import urllib.parse

BASE_URL = "http://127.0.0.1:18763"


class Fixture(http.server.BaseHTTPRequestHandler):
    article_reads = {}

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        key = query.get("key", [""])[0]
        page = query.get("page", ["1"])[0]
        if parsed.path == "/source.json":
            self.article_reads.clear()
            payload = {
                "sourceUrl": BASE_URL,
                "sourceName": "RSS 全流程测试",
                "sortUrl": "全部::" + BASE_URL + "/feed?page={{page}}",
                "searchUrl": BASE_URL + "/feed?key={{key}}&page={{page}}",
                "ruleArticles": "$.items",
                "ruleTitle": "$.title",
                "ruleLink": "$.link",
                "ruleContent": "$.content",
                "ruleNextPage": "PAGE",
            }
            if query.get("legacy"):
                payload.pop("ruleContent")
                payload["ruleDescription"] = "$.description"
        elif parsed.path.startswith("/article/"):
            count = self.article_reads.get(parsed.path, 0) + 1
            self.article_reads[parsed.path] = count
            payload = {"content": f"<p>第{count}次加载的订阅正文</p>"}
        else:
            title = f"搜索结果 {key} 第{page}页" if key else "首页文章"
            payload = {"items": [{
                "title": title,
                "link": BASE_URL + "/article/" + key + "/" + page,
                "description": "<p>这是用于全流程测试的自造订阅正文。</p>",
            }]}
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", 18763), Fixture).serve_forever()
