/**
 * Cloudflare Worker: Hanoi 60-Zone Hyper-Local Weather & Flood Edge Proxy
 * - Caches the 60-node Hanoi Open-Meteo batch + AQI at Cloudflare's edge (120 seconds)
 * - Zero cost (fits 100% inside Cloudflare Workers Free Tier: 100,000 req/day)
 * - Endpoints:
 *     GET /hanoi-batch  -> Returns 60-node Hanoi weather array (cached 120s)
 *     GET /hanoi-aqi    -> Returns 60-node Hanoi US AQI & PM2.5 array (cached 300s)
 *     GET /radar        -> Returns RainViewer Doppler Radar manifest (cached 120s)
 */

const HANOI_LATS = [
  21.0285,21.0242,21.0318,21.0368,21.0315,21.0465,21.0038,21.0102,21.0182,21.0258,
  21.0045,21.0145,20.9958,21.0368,21.0095,21.0462,20.9965,20.9935,21.0032,20.9675,
  20.9852,20.9612,21.0645,21.0695,21.0845,21.0435,21.0412,21.0595,21.0215,21.0205,
  21.0165,21.0035,20.9865,21.0585,21.0692,21.0545,20.9795,20.9685,20.9895,20.9505,
  21.0005,21.0815,21.1385,21.1045,20.9445,20.9285,21.0015,21.0665,21.2187,21.2575,
  21.1645,21.0885,21.0125,20.9905,20.9185,20.8925,20.8705,21.1395,21.1985,20.7385
].join(',');

const HANOI_LNGS = [
  105.8542,105.8415,105.8612,105.8346,105.8142,105.8458,105.8206,105.8265,105.8295,105.8335,
  105.8438,105.8512,105.8675,105.7895,105.7988,105.7965,105.8095,105.7985,105.8045,105.8295,
  105.8568,105.8585,105.8235,105.8065,105.8145,105.8755,105.9145,105.8695,105.9015,105.7665,
  105.7838,105.7415,105.7645,105.7812,105.7945,105.7365,105.7865,105.7715,105.7515,105.7445,
  105.9395,105.9315,105.8485,105.8245,105.8455,105.8395,105.7185,105.7045,105.8042,105.8485,
  105.7615,105.6615,105.5265,105.6415,105.7025,105.7695,105.8625,105.5045,105.4245,105.9135
].join(',');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type'
};

async function fetchWithEdgeCache(ctx, cacheKeyUrl, upstreamUrl, ttlSeconds) {
  const cache = caches.default;
  const cacheReq = new Request(cacheKeyUrl, { method: 'GET' });
  let resp = await cache.match(cacheReq);

  if (!resp) {
    const upstreamResp = await fetch(upstreamUrl, {
      cf: { cacheTtl: ttlSeconds, cacheEverything: true }
    });
    const bodyText = await upstreamResp.text();
    resp = new Response(bodyText, {
      status: upstreamResp.status,
      headers: {
        ...CORS_HEADERS,
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': `public, max-age=${ttlSeconds}`,
        'X-HN-Edge-Cache': 'MISS'
      }
    });
    if (upstreamResp.ok) {
      ctx.waitUntil(cache.put(cacheReq, resp.clone()));
    }
    return resp;
  }

  const cachedHeaders = new Headers(resp.headers);
  Object.entries(CORS_HEADERS).forEach(([k, v]) => cachedHeaders.set(k, v));
  cachedHeaders.set('X-HN-Edge-Cache', 'HIT');
  return new Response(resp.body, { status: resp.status, headers: cachedHeaders });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/hanoi-batch';

    if (path === '/hanoi-batch') {
      const upstream =
        `https://api.open-meteo.com/v1/forecast?latitude=${HANOI_LATS}&longitude=${HANOI_LNGS}` +
        `&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,rain,showers,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m` +
        `&hourly=precipitation_probability,precipitation,uv_index&timezone=Asia%2FBangkok&forecast_days=1`;
      return fetchWithEdgeCache(ctx, `${url.origin}/__cache/hanoi-batch-v1`, upstream, 120);
    }

    if (path === '/hanoi-aqi') {
      const upstream =
        `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${HANOI_LATS}&longitude=${HANOI_LNGS}` +
        `&current=us_aqi,pm2_5,pm10&timezone=Asia%2FBangkok`;
      return fetchWithEdgeCache(ctx, `${url.origin}/__cache/hanoi-aqi-v1`, upstream, 300);
    }

    if (path === '/radar') {
      const upstream = 'https://api.rainviewer.com/public/weather-maps.json';
      return fetchWithEdgeCache(ctx, `${url.origin}/__cache/rainviewer-v1`, upstream, 120);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        service: 'Hanoi 60-Zone Weather & Flood Edge Worker',
        endpoints: ['/hanoi-batch', '/hanoi-aqi', '/radar']
      }),
      { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } }
    );
  }
};
