#!/usr/bin/env python3
"""Generate an original EPUB 3 fixture for Files import and reader UI tests."""
import base64
import sys
import zipfile
from pathlib import Path

output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    files = {
        "META-INF/container.xml": '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        "OPS/book.opf": '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">legado-ui-epub</dc:identifier><dc:title>EPUB 导入测试</dc:title><dc:creator>测试作者</dc:creator><dc:language>zh</dc:language><meta property="dcterms:modified">2026-10-23T00:00:00Z</meta></metadata>
          <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="body" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="image" href="cover.png" media-type="image/png" properties="cover-image"/></manifest>
          <spine><itemref idref="body"/></spine></package>''',
        "OPS/nav.xhtml": '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><span>上卷</span><ol><li><span>正文篇</span><ol><li><a href="chapter.xhtml#one">第一章 EPUB</a></li><li><a href="chapter.xhtml#two">第二章 EPUB</a></li></ol></li></ol></li></ol></nav></body></html>''',
        "OPS/chapter.xhtml": '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>EPUB 正文</title></head><body><section><h1 id="one">第一章 EPUB</h1><p>这是 EPUB 导入后的第一章正文。</p><img src="cover.png" alt="测试插图"/></section><section><h1 id="two">第二章 EPUB</h1><p>这是 EPUB 的第二章正文，目录锚点跳转成功。</p></section></body></html>''',
    }
    for name, contents in files.items():
        archive.writestr(name, contents.encode("utf-8"), compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("OPS/cover.png", base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAABxklEQVR4nNXCA3YjAABF0becsW12bNdIGptt7Nq2bXeMjc06/j2XI8UG6RwtMUrnWGmtdI6XmaRzotwsnZMVFumcqrRK53SVTTpnqu3SOVvjkM45g1M6540u6VyodUvnoskjnUtmr3QuW3zSuWL1S+eqLSCda/agdK47QtK54QxL56arTjq33PXSue2JSOeONyqdu76YdO7549K5H0hI50EwKZ2HoZR0isJp6Tyqy0jncX1WOk8iOek8jeal8yxWkM7zeIN0XiQapfMy2SSdV6lm6bxOt0jnTaZVOm+zbdJ5l2uXzvt8h3Q+FDql87GhSzqfGrul87mpRzpfmnulU9zSJ52S1n7plLYNSKesfVA65R1D0qnoHJZOZdeIdKq6R6VT3TMmnZrecekY+iakY+yflE7twJR0TIPT0jEPzUjHMjwrHevInHRso/PSsY8tSMcxvigd58SSdFyTy9JxT61IxzO9Kh3vzJp0fLPr0vHPbUgnML8pneDClnRCi9vSCS/tSKdueVc69St70oms7ksnunYgndj6oXTiG1+lk9j8Jp3k1nfppLZ/SCe981M6md1f0snu/ZZObv+PdPIHf6VTOPwn/T/zbe3/96qaXAAAAABJRU5ErkJggg=="))
