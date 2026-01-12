'use strict';

const express = require('express');
const crypto = require('crypto');
const axios = require('axios');

const app = express();

/* BEGIN AUTO_CORS_MIDDLEWARE */
const ALLOWED_ORIGINS = new Set([
  'https://talent.mindcore.club',
]);

app.use((req, res, next) => {
  const origin = req.headers.origin;

  if (origin && ALLOWED_ORIGINS.has(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }

  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Max-Age', '86400');

  if (req.method === 'OPTIONS') return res.status(204).end();
  next();
});
/* END AUTO_CORS_MIDDLEWARE */


// Cloud Run behind proxy
app.set('trust proxy', true);

// Raw body for webhook signature verification (optional)
app.use('/mono/webhook', express.raw({ type: '*/*', limit: '1mb' }));
app.use(express.json({ limit: '1mb' }));

const PORT = process.env.PORT || 8080;

const MONO_TOKEN = process.env.MONO_TOKEN || '';
const MONO_API_BASE = process.env.MONO_API_BASE || 'https://api.monobank.ua';
const BASE_URL = process.env.BASE_URL || ''; // optional override of service URL
const MONO_WEBHOOK_URL = process.env.MONO_WEBHOOK_URL || ''; // optional
const MONO_REDIRECT_URL = process.env.MONO_REDIRECT_URL || ''; // optional
const MONO_WEBHOOK_SECRET = process.env.MONO_WEBHOOK_SECRET || ''; // optional HMAC secret if you use it on your side

// Minimal in-memory store (good enough for MVP; replace with Firestore later)
const store = {
  byOrderId: new Map(), // orderId -> { invoiceId, createdAt, destination, amount, status, lastWebhookAt }
  byInvoiceId: new Map(), // invoiceId -> orderId
};

function mustEnv(name, value) {
  if (!value) {
    const e = new Error(`Missing env: ${name}`);
    e.statusCode = 500;
    throw e;
  }
  return value;
}

function toKopiyky(amountUah) {
  // Accept number or string, convert UAH to kopiyky (integer)
  const n = typeof amountUah === 'string' ? Number(amountUah) : amountUah;
  if (!Number.isFinite(n) || n <= 0) throw badReq('amountUah must be > 0');
  return Math.round(n * 100);
}

function badReq(msg) {
  const e = new Error(msg);
  e.statusCode = 400;
  return e;
}

function ok(res, data) {
  res.status(200).json(data);
}

function safeJsonParse(buf) {
  try {
    return JSON.parse(buf.toString('utf8'));
  } catch {
    return null;
  }
}

function nowIso() {
  return new Date().toISOString();
}

function getPublicBaseUrl(req) {
  if (BASE_URL) return BASE_URL.replace(/\/+$/, '');
  const proto = req.get('x-forwarded-proto') || req.protocol || 'https';
  const host = req.get('x-forwarded-host') || req.get('host');
  return `${proto}://${host}`;
}

function monoClient() {
  const token = mustEnv('MONO_TOKEN', MONO_TOKEN);
  return axios.create({
    baseURL: MONO_API_BASE,
    timeout: 15000,
    headers: {
      'X-Token': token,
      'Content-Type': 'application/json',
    },
    validateStatus: () => true,
  });
}

// Health
app.get('/health', (req, res) => ok(res, { ok: true, ts: nowIso() }));

// Your missing route
app.get('/mono/webhook/health', (req, res) => ok(res, { ok: true, ts: nowIso() }));

// Create invoice
// Body: { orderId, amountUah, orderDesc, destination }
app.post('/api/create-invoice', async (req, res, next) => {
  try {
    const { orderId, amountUah, orderDesc, destination } = req.body || {};
    if (!orderId || typeof orderId !== 'string') throw badReq('orderId required');
    if (!orderDesc || typeof orderDesc !== 'string') throw badReq('orderDesc required');
    if (!destination || typeof destination !== 'string') throw badReq('destination required');

    const amount = toKopiyky(amountUah);

    const baseUrl = getPublicBaseUrl(req);

    // Webhook URL: explicit env wins, else use service endpoint
    const webHookUrl = (MONO_WEBHOOK_URL || `${baseUrl}/mono/webhook`).trim();

    // Redirect URL: optional, if you want to return user after payment
    const redirectUrl = (MONO_REDIRECT_URL || '').trim();

    const payload = {
      amount,     // in kopiyky
      ccy: 980,   // UAH
      merchantPaymInfo: {
        reference: orderId,
        destination: destination,
        comment: orderDesc,
      },
      webHookUrl,
    };

    if (redirectUrl) payload.redirectUrl = redirectUrl;

    const client = monoClient();
    const r = await client.post('/api/merchant/invoice/create', payload);

    if (r.status !== 200 || !r.data || !r.data.invoiceId || !r.data.pageUrl) {
      const details = {
        status: r.status,
        data: r.data,
      };
      return res.status(502).json({ ok: false, error: 'mono_create_failed', details });
    }

    const invoiceId = r.data.invoiceId;
    const pageUrl = r.data.pageUrl;

    store.byOrderId.set(orderId, {
      invoiceId,
      createdAt: nowIso(),
      destination,
      amount,
      status: 'created',
    });
    store.byInvoiceId.set(invoiceId, orderId);

    ok(res, { invoiceId, pageUrl });
  } catch (e) {
    next(e);
  }
});

// Poll invoice by orderId (your current path)
app.get('/mono/invoice/:orderId', async (req, res, next) => {
  try {
    const orderId = req.params.orderId;
    if (!orderId) throw badReq('orderId required');

    const row = store.byOrderId.get(orderId);
    if (!row || !row.invoiceId) {
      return res.status(404).json({ ok: false, error: 'order_not_found', orderId });
    }

    const client = monoClient();
    const r = await client.get('/api/merchant/invoice/status', {
      params: { invoiceId: row.invoiceId },
    });

    if (r.status !== 200) {
      return res.status(502).json({
        ok: false,
        error: 'mono_status_failed',
        details: { status: r.status, data: r.data },
      });
    }

    // Cache last known status
    row.status = r.data.status || row.status;
    row.modifiedDate = r.data.modifiedDate;
    row.lastStatusAt = nowIso();
    store.byOrderId.set(orderId, row);

    ok(res, {
      ok: true,
      orderId,
      invoiceId: row.invoiceId,
      status: r.data,
    });
  } catch (e) {
    next(e);
  }
});

// Optional: poll by invoiceId
app.get('/mono/invoice-by-id/:invoiceId', async (req, res, next) => {
  try {
    const invoiceId = req.params.invoiceId;
    if (!invoiceId) throw badReq('invoiceId required');

    const client = monoClient();
    const r = await client.get('/api/merchant/invoice/status', {
      params: { invoiceId },
    });

    if (r.status !== 200) {
      return res.status(502).json({
        ok: false,
        error: 'mono_status_failed',
        details: { status: r.status, data: r.data },
      });
    }

    ok(res, { ok: true, invoiceId, status: r.data });
  } catch (e) {
    next(e);
  }
});

// Webhook receiver (Monobank will POST here)
// Note: signature verification depends on Monobank webhook signature scheme.
// This handler stores status and returns 200 fast.
app.post('/mono/webhook', async (req, res) => {
  const raw = req.body; // Buffer
  const body = safeJsonParse(raw) || {};

  // Optional: your own HMAC check if you set MONO_WEBHOOK_SECRET
  // This is NOT Monobank official verification unless you configured it accordingly.
  if (MONO_WEBHOOK_SECRET) {
    const sig = req.get('x-signature') || req.get('x-sign') || '';
    const mac = crypto.createHmac('sha256', MONO_WEBHOOK_SECRET).update(raw).digest('hex');
    if (sig && sig !== mac) {
      return res.status(401).json({ ok: false, error: 'bad_signature' });
    }
  }

  // Try map invoiceId -> orderId, else reference from payload
  const invoiceId = body.invoiceId || body.data?.invoiceId || null;
  const reference = body.reference || body.data?.reference || null; // expected to be orderId
  const status = body.status || body.data?.status || null;

  const orderId = reference || (invoiceId ? store.byInvoiceId.get(invoiceId) : null);

  if (orderId) {
    const row = store.byOrderId.get(orderId) || {};
    if (invoiceId) {
      row.invoiceId = invoiceId;
      store.byInvoiceId.set(invoiceId, orderId);
    }
    row.status = status || row.status || 'unknown';
    row.lastWebhookAt = nowIso();
    row.webhookPayload = body;
    store.byOrderId.set(orderId, row);
  }

  // Always 200 to avoid retries storm; log to stdout for Cloud Run logs
  console.log('mono_webhook', { ts: nowIso(), invoiceId, reference, status });
  return res.status(200).json({ ok: true });
});

// Error handler
app.use((err, req, res, next) => {
  const code = err.statusCode || 500;
  const msg = err.message || 'error';
  res.status(code).json({ ok: false, error: msg });
});

app.listen(PORT, () => {
  console.log(`listening on ${PORT}`);
});
