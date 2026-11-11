#!/usr/bin/env python3
"""Synthetic comic fixture: python3 scripts/fixtures/comic-flow-server.py.
No external book sources or copyrighted comic pages are served.
"""
import argparse
import html
import json
import struct
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def page_png(index):
    width, height = 600, 800 if index != 3 else 1600
    palettes = [(225, 240, 255), (255, 234, 213), (225, 247, 232)]
    background = palettes[(index - 1) % 3]
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            color = background
            if 25 < x < 575 and (35 < y % 800 < 380 or 410 < y % 800 < 765):
                color = (250, 250, 245)
                if x < 31 or x > 569 or y % 800 in range(36, 42) or y % 800 in range(410, 416):
                    color = (35, 55, 75)
                if (x - 300) ** 2 + (y % 400 - 190) ** 2 < 65 ** 2:
                    color = (65, 105 + 20 * index, 150)
                if 265 < x < 335 and 240 < y % 400 < 325:
                    color = (65, 105 + 20 * index, 150)
            pixels.extend(color)
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


PAGES = {i: page_png(i) for i in range(1, 4)}
ATTEMPTS = set()
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        session = parse_qs(parsed.query).get('session', ['default'])[0]
        base = 'http://' + self.headers['Host']
        if parsed.path.startswith('/chapter/'):
            content = []
            for index in range(1, 4):
                address = f'{base}/page/{index}.png?session={session}'
                # Image-specific Referer must override the automatic chapter header.
                address += ',' + json.dumps({'headers': {'Referer': base + '/allowed'}}, separators=(',', ':'))
                content.append(f'<img data-original="{html.escape(address, quote=True)}">')
            body = ('<div class="page">' + '\n'.join(content) + '</div>').encode()
            self.reply(200, 'text/html; charset=utf-8', body)
        elif parsed.path.startswith('/page/'):
            if self.headers.get('Referer') != base + '/allowed' or self.headers.get('X-Comic-Test') != 'fixture':
                self.reply(403, 'text/plain', b'Missing image headers')
                return
            index = int(parsed.path.split('/')[-1].split('.')[0])
            with LOCK:
                fail = index == 2 and session not in ATTEMPTS
                ATTEMPTS.add(session) if index == 2 else None
            self.reply(503 if fail else 200, 'image/png', b'retry fixture' if fail else PAGES[index])
        else:
            self.reply(404, 'text/plain', b'not found')

    def reply(self, status, content_type, body):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18089)
    args = parser.parse_args()
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
