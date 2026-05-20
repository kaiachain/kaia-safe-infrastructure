/**
 * CGW expects Safe Decoder API shapes (see safe-global/safe-client-gateway ContractSchema).
 * Local TXS returns slimmer contract JSON; Zod parse failures surface as "Delegate call is disabled".
 * This shim proxies TXS and enriches contract payloads with chainId, modified, project, abi, logoUrl.
 */
import axios from 'axios';
import express from 'express';

const PORT = Number.parseInt(process.env.PORT ?? '3001', 10);
const UPSTREAM =
  process.env.TXS_UPSTREAM_BASE_URL?.replace(/\/$/, '') ?? 'http://txs-web:8888';

const http = axios.create({
  baseURL: UPSTREAM,
  timeout: Number.parseInt(process.env.HTTP_TIMEOUT_MS ?? '60000', 10),
  validateStatus: () => true,
});

const parseChainId = (query) => {
  const raw = query.chain_ids;
  if (raw == null) return null;
  const s = Array.isArray(raw) ? raw[0] : String(raw);
  const first = s.split('&chain_ids=')[0]?.trim();
  const n = Number.parseInt(first, 10);
  return Number.isFinite(n) ? n : null;
};

/**
 * TXS JSON uses snake_case (trusted_for_delegate_call, display_name, logo_uri).
 * Reading only camelCase made trustedForDelegateCall always false → CGW "Delegate call is disabled".
 */
const enrichContract = (raw, chainIdNum) => {
  if (!raw || typeof raw !== 'object') return raw;
  const modified =
    typeof raw.modified === 'string'
      ? raw.modified
      : new Date().toISOString();
  const trusted =
    raw.trustedForDelegateCall ??
    raw.trusted_for_delegate_call ??
    false;
  const logo =
    raw.logoUrl ?? raw.logoUri ?? raw.logo_uri ?? null;
  return {
    address: raw.address,
    name: raw.name ?? null,
    displayName: raw.displayName ?? raw.display_name ?? null,
    chainId: chainIdNum,
    project: null,
    abi: null,
    modified,
    trustedForDelegateCall: !!trusted,
    ...(logo != null && logo !== '' ? { logoUrl: logo } : {}),
  };
};

/** CGW ContractPageSchema requires numeric count and string|null next/previous. */
const coercePageFields = (data) => {
  if (!data || typeof data !== 'object') return data;
  let count = data.count;
  if (count != null && typeof count !== 'number') {
    const n = Number.parseInt(String(count), 10);
    count = Number.isFinite(n) ? n : null;
  }
  const next =
    data.next == null || data.next === '' ? null : String(data.next);
  const previous =
    data.previous == null || data.previous === ''
      ? null
      : String(data.previous);
  return { ...data, count, next, previous };
};

const normalizeContractPage = (data, chainId) => {
  if (!data || typeof data !== 'object') return data;
  const base = coercePageFields(data);
  if (Array.isArray(base.results)) {
    if (chainId == null) return base;
    const results = base.results
      .filter((c) => c != null && typeof c === 'object')
      .map((c) => enrichContract(c, chainId));
    return {
      ...base,
      results,
      count:
        typeof base.count === 'number'
          ? base.count
          : results.length,
    };
  }
  if (chainId != null && typeof base.address === 'string') {
    const row = enrichContract(base, chainId);
    return {
      count: 1,
      next: null,
      previous: null,
      results: [row],
    };
  }
  return base;
};

const app = express();
app.use(express.json({ limit: '4mb' }));

app.get('/health', (_req, res) => {
  res.status(200).json({ ok: true });
});

app.post('/api/v1/data-decoder', async (req, res) => {
  try {
    const r = await http.post('/api/v1/data-decoder', req.body, {
      headers: {
        'content-type': req.headers['content-type'] ?? 'application/json',
      },
    });
    if (typeof r.data === 'object' && r.data !== null) {
      res.status(r.status).json(r.data);
    } else {
      res.status(r.status).send(r.data);
    }
  } catch (e) {
    res.status(502).json({ message: e instanceof Error ? e.message : String(e) });
  }
});

app.get('/api/v1/contracts', async (req, res) => {
  try {
    const chainId = parseChainId(req.query);
    // Trailing slash avoids APPEND_SLASH 301 → Location /txs/... (broken inside Docker).
    const r = await http.get('/api/v1/contracts/', { params: req.query });
    if (r.status >= 400) {
      return res.status(r.status).send(r.data);
    }
    const body = normalizeContractPage(r.data, chainId);
    res.status(r.status).json(body);
  } catch (e) {
    res.status(502).json({ message: e instanceof Error ? e.message : String(e) });
  }
});

app.get('/api/v1/contracts/:address', async (req, res) => {
  try {
    const chainId = parseChainId(req.query);
    const r = await http.get(`/api/v1/contracts/${req.params.address}/`, {
      params: req.query,
    });
    if (r.status >= 400) {
      return res.status(r.status).send(r.data);
    }
    const body = normalizeContractPage(r.data, chainId);
    res.status(r.status).json(body);
  } catch (e) {
    res.status(502).json({ message: e instanceof Error ? e.message : String(e) });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`decoder-shim listening on ${PORT}, upstream=${UPSTREAM}`);
});
