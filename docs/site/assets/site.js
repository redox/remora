const root = document.documentElement.dataset.root;
const dialog = document.querySelector(".search-dialog");
const trigger = document.querySelector(".search-trigger");
const input = document.querySelector("#search-input");
const status = dialog.querySelector(".search-status");
const results = dialog.querySelector(".search-results");
let searchIndex;

function normalized(text) {
  return text.toLowerCase().normalize("NFKD").replace(/\p{Mark}/gu, "");
}

function rank(section, words) {
  const title = normalized(section.title);
  const heading = normalized(section.heading);
  const text = normalized(section.text);
  let score = 0;
  for (const word of words) {
    if (title.includes(word)) score += 8;
    else if (heading.includes(word)) score += 5;
    else if (text.includes(word)) score += 1;
    else return 0;
  }
  return score + Number(section.heading === "");
}

async function search() {
  const query = input.value;
  const words = normalized(query).match(/[\p{Letter}\p{Number}]+/gu) ?? [];
  results.replaceChildren();
  if (!words.length) {
    status.textContent = "Enter a word or feature name.";
    return;
  }

  status.textContent = "Searching…";
  searchIndex ??= fetch(root + "assets/search.json").then(response => {
    if (!response.ok) throw new Error("Search index unavailable");
    return response.json();
  });
  let index;
  try {
    index = await searchIndex;
  } catch {
    searchIndex = undefined;
    if (input.value === query) status.textContent = "Search is unavailable. Try again or browse the documentation.";
    return;
  }
  if (input.value !== query) return;

  const matches = index
    .map(section => ({ section, score: rank(section, words) }))
    .filter(match => match.score)
    .sort((first, second) => second.score - first.score)
    .slice(0, 10);

  status.textContent = matches.length ? "" : "No results. Try a shorter query.";
  const items = matches.map(({ section }) => {
    const item = document.createElement("li");
    const link = document.createElement("a");
    link.href = root + section.url;
    link.textContent = section.heading ? section.title + " · " + section.heading : section.title;
    if (section.text) {
      const preview = document.createElement("span");
      const text = section.text;
      preview.textContent = text.length > 135 ? text.slice(0, 132).trimEnd() + "…" : text;
      link.append(preview);
    }
    item.append(link);
    return item;
  });
  results.replaceChildren(...items);
}

function openSearch() {
  if (dialog.open) return;
  dialog.showModal();
  input.focus();
  input.select();
  search();
}

trigger.hidden = false;
trigger.setAttribute("aria-label", "Search documentation");
trigger.addEventListener("click", openSearch);
dialog.querySelector(".search-close").addEventListener("click", () => dialog.close());
input.addEventListener("input", search);

document.addEventListener("keydown", event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    openSearch();
  }
});

dialog.querySelector("form").addEventListener("submit", event => {
  event.preventDefault();
  results.querySelector("a")?.click();
});

results.addEventListener("click", event => {
  if (event.target.closest("a")) dialog.close();
});

dialog.addEventListener("keydown", event => {
  if (!["ArrowDown", "ArrowUp"].includes(event.key)) return;
  const links = Array.from(results.querySelectorAll("a"));
  const current = links.indexOf(document.activeElement);
  if (!links.length || (current === -1 && event.target !== input)) return;
  event.preventDefault();
  if (event.key === "ArrowDown") links[Math.min(current + 1, links.length - 1)].focus();
  else if (current <= 0) input.focus();
  else links[current - 1].focus();
});

const demo = document.querySelector(".demo-controls");
if (demo) {
  demo.hidden = false;
  demo.addEventListener("click", event => {
    const button = event.target.closest("[data-demo]");
    if (!button) return;
    for (const option of demo.querySelectorAll("[data-demo]")) {
      option.setAttribute("aria-pressed", String(option === button));
    }
    for (const panel of document.querySelectorAll("[data-demo-panel]")) {
      panel.hidden = panel.dataset.demoPanel !== button.dataset.demo;
    }
  });
}
