/**
 * Load test: ~100 users, each requesting different symbols (simulates real usage).
 * Run: k6 run workers/scripts/load-test-100-users.js
 * Install k6: choco install k6  OR  https://k6.io/docs/getting-started/installation/
 *
 * Adjust BASE_URL for prod or dev:
 *   k6 run -e BASE_URL=https://rsi-workers.vovan4ikukraine.workers.dev workers/scripts/load-test-100-users.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://rsi-workers.vovan4ikukraine.workers.dev';

// ~100 different symbols (mix of stocks and crypto) — each "user" gets different symbol
const SYMBOLS = [
  'AAPL', 'MSFT', 'GOOGL', 'AMZN', 'META', 'NVDA', 'TSLA', 'JPM', 'V', 'WMT',
  'JNJ', 'PG', 'MA', 'HD', 'DIS', 'PYPL', 'BAC', 'ADBE', 'XOM', 'NFLX',
  'CRM', 'PEP', 'CSCO', 'KO', 'COST', 'ABT', 'AVGO', 'TMO', 'ACN', 'DHR',
  'NEE', 'CMCSA', 'INTC', 'TXN', 'NKE', 'PM', 'UNP', 'RTX', 'HON', 'UPS',
  'LOW', 'IBM', 'QCOM', 'INTU', 'AMAT', 'CAT', 'GE', 'AMD', 'SPGI', 'BKNG',
  'DE', 'AXP', 'GS', 'PLD', 'LMT', 'SBUX', 'ADI', 'MDT', 'GILD', 'SRE',
  'BTC-USD', 'ETH-USD', 'XRP-USD', 'SOL-USD', 'DOGE-USD', 'ADA-USD', 'AVAX-USD', 'DOT-USD', 'MATIC-USD', 'LINK-USD',
  'UNI-USD', 'ATOM-USD', 'LTC-USD', 'BCH-USD', 'ETC-USD', 'XLM-USD', 'ALGO-USD', 'VET-USD', 'FIL-USD', 'TRX-USD',
  'EOS-USD', 'AAVE-USD', 'GRT-USD', 'XTZ-USD', 'THETA-USD', 'NEAR-USD', 'FTM-USD', 'SAND-USD', 'MANA-USD', 'APE-USD',
  'AXS-USD', 'CRV-USD', 'MKR-USD', 'SNX-USD', 'COMP-USD', 'YFI-USD', 'SUSHI-USD', 'BAT-USD', 'ENJ-USD', 'CHZ-USD',
];

const TIMEFRAMES = ['1m', '5m', '15m', '1h', '1d'];

export const options = {
  scenarios: {
    // Ramp up to 100 users over 30s, hold 2 min, then ramp down
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 100 },
        { duration: '2m', target: 100 },
        { duration: '15s', target: 0 },
      ],
      gracefulRampDown: '10s',
      gracefulStop: '10s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<5000', 'p(99)<10000'], // 95% < 5s, 99% < 10s
    http_req_failed: ['rate<0.05'],                    // < 5% errors (429 or 5xx)
    http_reqs: ['rate>5'],                             // at least 5 req/s sustained
  },
};

export default function () {
  const symbol = SYMBOLS[__VU % SYMBOLS.length];
  const tf = TIMEFRAMES[__VU % TIMEFRAMES.length];
  const url = `${BASE_URL}/yf/candles?symbol=${symbol}&tf=${tf}&limit=100`;

  const res = http.get(url, { tags: { name: 'candles' } });

  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'no 429': (r) => r.status !== 429,
  });

  if (!ok) {
    console.warn(`[VU ${__VU}] ${res.status} ${symbol} ${tf}`);
  }

  sleep(0.5 + Math.random() * 1.5); // 0.5–2s between requests per user
}
