const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const routes = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/artwork.svg': ['artwork.svg', 'image/svg+xml'],
};
const server = http.createServer((request, response) => {
  if (request.url === '/favicon.ico') { response.writeHead(204); response.end(); return; }
  const route = routes[request.url];
  if (!route) { response.writeHead(404); response.end('Missing local fixture asset'); return; }
  response.writeHead(200, { 'Content-Type': route[1], 'Cache-Control': 'no-store' });
  response.end(fs.readFileSync(path.join(__dirname, route[0])));
});
server.listen(41739, '127.0.0.1', () => console.log('Wolfi visual fixture listening on localhost'));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
