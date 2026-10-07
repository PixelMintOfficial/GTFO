// Local-only design preview. Run: node tools/serve_wire_repair.cjs
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const files = new Map([
  ['/', ['tools/wire_repair.html', 'text/html; charset=utf-8']],
  ['/tools/wire_repair.html', ['tools/wire_repair.html', 'text/html; charset=utf-8']],
  ['/tools/wire_repair_core.js', ['tools/wire_repair_core.js', 'text/javascript; charset=utf-8']],
  ['/wire_repair_core.js', ['tools/wire_repair_core.js', 'text/javascript; charset=utf-8']],
  ['/tools/wire_repair_preview.js', ['tools/wire_repair_preview.js', 'text/javascript; charset=utf-8']],
  ['/data/repair_circuits.json', ['data/repair_circuits.json', 'application/json; charset=utf-8']],
  ['/assets/maps/base_interior/preview_half.png', ['assets/maps/base_interior/preview_half.png', 'image/png']]
]);
const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  if (pathname === '/favicon.ico') { response.writeHead(204); response.end(); return; }
  const file = files.get(pathname);
  if (!file || !['GET', 'HEAD'].includes(request.method)) { response.writeHead(404); response.end('Not found'); return; }
  fs.readFile(path.join(root, file[0]), (error, data) => {
    if (error) { response.writeHead(500); response.end('Preview file unavailable'); return; }
    response.writeHead(200, {'Content-Type':file[1], 'Cache-Control':'no-store'});
    response.end(request.method === 'HEAD' ? undefined : data);
  });
});
server.on('error', error => { console.error(error.code === 'EADDRINUSE' ? 'Port 8765 is already in use. Open the existing preview or stop its server first.' : error.message); process.exitCode = 1; });
server.listen(8765, '127.0.0.1', () => console.log('Wire repair preview: http://127.0.0.1:8765/tools/wire_repair.html\nPress Ctrl+C to stop.'));
