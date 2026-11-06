const http = require('http');
const fs = require('fs');
const path = require('path');

const root = __dirname;
const port = 8899;

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8'
};

http.createServer((req, res) => {
  let rel = decodeURIComponent(req.url.split('?')[0]);
  if (rel === '/') rel = '/index.html';
  const file = path.join(root, rel);
  if (!file.startsWith(root)) { res.writeHead(403).end('no'); return; }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404).end('not found'); return; }
    res.writeHead(200, {
      'Content-Type': types[path.extname(file)] || 'application/octet-stream',
      // Without this the browser caches app.js and styles.css heuristically, and an
      // edit only appears after a hard reload or a hand-written ?v= on the URL.
      'Cache-Control': 'no-store, max-age=0'
    });
    res.end(buf);
  });
}).listen(port, () => console.log('serving on http://localhost:' + port));
