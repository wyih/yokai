"""Local verification-page fixture for testLatestBackgroundArticleLoading."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = 'Full article after automatic verification. ' * 15
        script = (
            "<script>setTimeout(()=>{document.title='Article';document.body.innerHTML='<article>"
            + body + "</article>';},1200)</script>"
        ) if self.path == '/article' else ''
        data = (
            '<meta charset="utf-8"><title>请稍候…</title>'
            '<main id="challenge-running">Verifying</main>' + script
        ).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18143), Handler).serve_forever()
