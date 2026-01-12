cat > install.sh <<'EOF'
set -euo pipefail

SERVICE_NAME="mindcore-app"
REGION="europe-west1"
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [ -z "${PROJECT_ID}" ]; then
  echo "ERROR: gcloud project is not set. Run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

WORKDIR="${HOME}/${SERVICE_NAME}"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/public"
cd "${WORKDIR}"

cat > package.json <<'EOP'
{
  "name": "mindcore-app",
  "version": "1.0.0",
  "private": true,
  "description": "Cloud Run static React 18 app with cache-busting + service worker",
  "main": "index.js",
  "type": "commonjs",
  "scripts": {
    "start": "node index.js"
  },
  "engines": {
    "node": ">=18"
  },
  "dependencies": {
    "express": "^4.19.2",
    "helmet": "^7.1.0"
  }
}
EOP

cat > index.js <<'EOP'
'use strict';

const express = require('express');
const path = require('path');
const helmet = require('helmet');

const app = express();
const PORT = process.env.PORT || 8080;

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      "default-src": ["'self'"],
      "img-src": ["'self'", "data:"],
      "style-src": ["'self'", "'unsafe-inline'"],
      "script-src": ["'self'", "'unsafe-inline'", "https://unpkg.com"],
      "connect-src": ["'self'"],
      "font-src": ["'self'", "data:"]
    }
  }
}));

app.set('etag', false);

app.use('/assets', express.static(path.join(__dirname, 'public', 'assets'), {
  etag: false,
  maxAge: '365d',
  immutable: true
}));

app.get('/sw.js', (req, res) => {
  res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.sendFile(path.join(__dirname, 'public', 'sw.js'));
});

app.get('/', (req, res) => {
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.get('/healthz', (req, res) => res.status(200).send('ok'));

app.listen(PORT, () => console.log(`Listening on :${PORT}`));
EOP

APP_VERSION="$(date +%Y%m%d_%H%M%S)"

cat > public/index.html <<EOP
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <meta name="theme-color" content="#ffffff" />
  <title>MindCore App</title>
  <style>
    html, body { height: 100%; margin: 0; background: #fff; color: #111; font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; }
    .wrap { min-height: 100%; display: flex; align-items: center; justify-content: center; padding: 24px; }
    .card { width: 100%; max-width: 860px; border: 1px solid rgba(0,0,0,.08); border-radius: 16px; box-shadow: 0 10px 30px rgba(0,0,0,.06); padding: 20px; }
    .top { display: flex; gap: 12px; align-items: center; justify-content: space-between; flex-wrap: wrap; }
    .h { font-size: 18px; font-weight: 700; }
    .meta { font-size: 12px; opacity: .65; }
    .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 16px; }
    @media (max-width: 900px) { .grid { grid-template-columns: repeat(2, 1fr); } }
    @media (max-width: 600px) { .grid { grid-template-columns: 1fr; } }
    .tile { border: 1px solid rgba(0,0,0,.08); border-radius: 14px; padding: 14px; }
    .tile b { display: block; margin-bottom: 6px; }
    .btn { border: 1px solid rgba(0,0,0,.15); background: #fff; padding: 10px 12px; border-radius: 12px; cursor: pointer; }
    .btn:active { transform: translateY(1px); }
    .warn { margin-top: 10px; font-size: 12px; opacity: .7; }
    .err { margin-top: 10px; padding: 10px 12px; border-radius: 12px; background: #fff5f5; border: 1px solid rgba(255,0,0,.15); display: none; }
    .ok { margin-top: 10px; padding: 10px 12px; border-radius: 12px; background: #f3fff5; border: 1px solid rgba(0,128,0,.15); display: none; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="top">
        <div>
          <div class="h">MindCore App (React 18)</div>
          <div class="meta">build: ${APP_VERSION}</div>
        </div>
        <button class="btn" id="hardReload">Hard reload</button>
      </div>

      <div id="root"></div>

      <div class="warn">
        Если раньше был React 19 или сломанный service worker, кнопка Hard reload чистит SW и перезагружает.
      </div>
      <div class="err" id="errBox"></div>
      <div class="ok" id="okBox"></div>
    </div>
  </div>

  <script>
    (function () {
      const errBox = document.getElementById('errBox');
      const okBox = document.getElementById('okBox');

      function showErr(msg) {
        errBox.style.display = 'block';
        errBox.textContent = msg;
      }
      function showOk(msg) {
        okBox.style.display = 'block';
        okBox.textContent = msg;
      }

      async function nukeSW() {
        if (!('serviceWorker' in navigator)) return;
        try {
          const regs = await navigator.serviceWorker.getRegistrations();
          for (const r of regs) await r.unregister();
          if (window.caches) {
            const keys = await caches.keys();
            await Promise.all(keys.map(k => caches.delete(k)));
          }
          showOk('Service Worker и Cache Storage очищены');
        } catch (e) {
          showErr('Не смог очистить SW/Cache: ' + (e && e.message ? e.message : String(e)));
        }
      }

      document.getElementById('hardReload').addEventListener('click', async () => {
        await nukeSW();
        const url = new URL(location.href);
        url.searchParams.set('v', String(Date.now()));
        location.replace(url.toString());
      });

      window.addEventListener('load', () => {
        if (!('serviceWorker' in navigator)) return;
        navigator.serviceWorker.register('/sw.js', { scope: '/' })
          .catch(e => showErr('SW register failed: ' + (e && e.message ? e.message : String(e))));
      });
    })();
  </script>

  <script crossorigin src="https://unpkg.com/react@18.2.0/umd/react.production.min.js"></script>
  <script crossorigin src="https://unpkg.com/react-dom@18.2.0/umd/react-dom.production.min.js"></script>

  <script src="/assets/app.js?v=${APP_VERSION}"></script>
</body>
</html>
EOP

cat > public/sw.js <<EOP
'use strict';

const SW_VERSION = '${APP_VERSION}';
const CACHE_NAME = 'mindcore-cache-' + SW_VERSION;

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll([
      '/',
      '/assets/app.js?v=${APP_VERSION}'
    ]))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map((k) => (k.startsWith('mindcore-cache-') && k !== CACHE_NAME) ? caches.delete(k) : Promise.resolve()));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  if (req.mode === 'navigate' || url.pathname === '/') {
    event.respondWith((async () => {
      try {
        return await fetch(req, { cache: 'no-store' });
      } catch (_) {
        const cache = await caches.open(CACHE_NAME);
        const cached = await cache.match('/');
        return cached || new Response('offline', { status: 503 });
      }
    })());
    return;
  }

  if (url.pathname.startsWith('/assets/')) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE_NAME);
      const cached = await cache.match(req);
      if (cached) return cached;
      const fresh = await fetch(req);
      cache.put(req, fresh.clone());
      return fresh;
    })());
  }
});
EOP

mkdir -p public/assets
cat > public/assets/app.js <<'EOP'
'use strict';

(function () {
  const e = React.createElement;

  function Tile(props) {
    return e('div', { className: 'tile' },
      e('b', null, props.title),
      e('div', null, props.text)
    );
  }

  function App() {
    const items = [
      { title: 'Status', text: 'App loaded on React 18.2.0' },
      { title: 'Cache', text: 'Assets versioned, index no-store, SW versioned' },
      { title: 'Prod', text: 'Stable baseline to unblock deployment' },
      { title: 'Next', text: 'Replace tiles with your real UI/modules' },
      { title: 'Rule', text: 'Do not add React 19 scripts here' },
      { title: 'Health', text: 'GET /healthz returns ok' }
    ];
    return e('div', null,
      e('div', { className: 'grid' }, items.map((it, i) => e(Tile, { key: i, title: it.title, text: it.text })))
    );
  }

  const root = ReactDOM.createRoot(document.getElementById('root'));
  root.render(e(App));
})();
EOP

echo "Deploying to Cloud Run: ${SERVICE_NAME} (${REGION})"
gcloud run deploy "${SERVICE_NAME}" \
  --region "${REGION}" \
  --source . \
  --allow-unauthenticated

URL="$(gcloud run services describe "${SERVICE_NAME}" --region "${REGION}" --format='value(status.url)')"
echo "DONE: ${URL}"
EOF
