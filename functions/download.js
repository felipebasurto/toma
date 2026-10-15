// Counts a download, then sends the browser to the latest notarized disk image on GitHub.
// Each click is one Analytics Engine row: blobs are [lang, from, country, referrer host].
// Without the DOWNLOADS binding the redirect still works; it just isn't counted.
const DMG = 'https://github.com/felipebasurto/toma/releases/latest/download/Toma.dmg';

export async function onRequest({ request, env }) {
  const url = new URL(request.url);
  const lang = url.searchParams.get('lang') === 'es' ? 'es' : 'en';
  const from = (url.searchParams.get('from') || 'direct').slice(0, 32);
  let referrer = '';
  try { referrer = new URL(request.headers.get('Referer') || '').host; } catch {}

  env.DOWNLOADS?.writeDataPoint({
    blobs: [lang, from, request.cf?.country || '', referrer],
    doubles: [1],
    indexes: [lang],
  });

  return new Response(null, {
    status: 302,
    headers: { Location: DMG, 'Cache-Control': 'no-store' },
  });
}
