// Documentation search for the Remora website, built on Docspot.
//
// The Python site build writes `assets/search.json`, one entry per article
// section. This module turns it into a MiniSearch index in the browser the
// first time search is about to be used, so the site stays fully static: no
// search service and no requests beyond the site's own files. Docspot's Ask AI
// chat is left out because the site has no backend to answer with.
import { Docspot } from 'docspot';
import { createMiniSearchSearch } from 'docspot/minisearch';
import MiniSearch from 'minisearch';
import { createRoot } from 'react-dom/client';

import 'docspot/styles.css';

// Links in the index are relative to the site root, which the layout records
// as a relative path so the site works on a GitHub Pages project path.
const root = document.documentElement.dataset.root ?? './';

async function loadIndex() {
  const response = await fetch(root + 'assets/search.json');
  if (!response.ok) throw new Error('Search index unavailable');
  const sections = await response.json();
  const index = new MiniSearch({
    fields: ['heading', 'title', 'text'],
    storeFields: ['heading', 'title', 'url', 'text', 'group'],
    searchOptions: {
      boost: { heading: 3, title: 2 },
      prefix: true,
      fuzzy: 0.2,
      combineWith: 'AND',
    },
  });
  index.addAll(sections.map((section, id) => ({ id, ...section })));
  return index;
}

const search = createMiniSearchSearch({
  index: loadIndex,
  getDocument: hit => ({
    url: root + hit.url,
    title: hit.heading || hit.title,
    pageTitle: hit.title,
    type: hit.heading ? 'section' : 'page',
    breadcrumb: hit.heading ? [hit.title] : [],
    group: hit.group,
    content: hit.text,
  }),
});

const slot = document.querySelector('.search-slot');
if (slot) {
  createRoot(slot).render(
    <Docspot
      search={search}
      history
      shortcuts={{ chat: false }}
    />
  );
}
