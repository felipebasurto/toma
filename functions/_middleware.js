// Sends "/" to the right language. English is the default; a browser whose
// preferred language is Spanish gets /es/. The visitor's country is not used,
// so an English browser in Spain still lands on /en/.
// ?lang=es or ?lang=en overrides the guess. Paths other than "/" go straight to the files.
export async function onRequest(context) {
  const { request } = context;
  const url = new URL(request.url);
  if (url.pathname !== '/') return context.next();

  const forced = url.searchParams.get('lang');
  let lang;
  if (forced === 'es' || forced === 'en') lang = forced;
  else lang = prefersSpanish(request.headers.get('Accept-Language')) ? 'es' : 'en';

  return new Response(null, {
    status: 302,
    headers: {
      Location: `/${lang}/`,
      Vary: 'Accept-Language',
      'Cache-Control': 'no-store',
    },
  });
}

// True when Spanish outranks English and every other language in Accept-Language.
function prefersSpanish(header) {
  let best = null;
  let bestQ = -1;
  for (const part of (header || '').split(',')) {
    const [tag, ...params] = part.trim().split(';');
    if (!tag || tag === '*') continue;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith('q='));
    const weight = q ? Number(q.slice(2)) : 1;
    if (weight > bestQ) {
      best = tag.toLowerCase();
      bestQ = weight;
    }
  }
  return best !== null && /^es\b/.test(best);
}
