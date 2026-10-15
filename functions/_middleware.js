// Sends "/" to the right language. Spanish-speaking countries get /es/, everyone else /en/.
// Pages gives every request its country (request.cf.country), so no client JavaScript runs first.
// ?lang=es or ?lang=en overrides the guess. Pages paths other than "/" go straight to the files.
const SPANISH_SPEAKING = new Set([
  'ES', 'MX', 'AR', 'CO', 'CL', 'PE', 'VE', 'EC', 'GT', 'CU', 'BO', 'DO', 'HN',
  'PY', 'SV', 'NI', 'CR', 'PA', 'UY', 'GQ', 'PR',
]);

export async function onRequest(context) {
  const { request } = context;
  const url = new URL(request.url);
  if (url.pathname !== '/') return context.next();

  const forced = url.searchParams.get('lang');
  const country = request.cf?.country;
  let lang;
  if (forced === 'es' || forced === 'en') lang = forced;
  else if (country) lang = SPANISH_SPEAKING.has(country) ? 'es' : 'en';
  else lang = /^es\b/i.test(request.headers.get('Accept-Language') || '') ? 'es' : 'en';

  return new Response(null, {
    status: 302,
    headers: {
      Location: `/${lang}/`,
      Vary: 'CF-IPCountry, Accept-Language',
      'Cache-Control': 'no-store',
    },
  });
}
