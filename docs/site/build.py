#!/usr/bin/env python3
"""Build the public site with Python's standard library and bundle its search with npm."""

import argparse
import json
import os
import posixpath
import re
import shutil
import subprocess
from html import escape
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[1]
OUTPUT = REPO / "dist/site"
SEARCH = SOURCE / "search"
DEFAULT_REPOSITORY = "https://github.com/redox/remora"

GROUPS = {
    "Get started": [
        ("", "Overview"),
        ("installation", "Installation"),
        ("quickstart", "Quickstart"),
    ],
    "Guides": [
        ("rewrite", "Draft and Rewrite"),
        ("dictation", "Voice dictation"),
        ("chat", "Chat"),
        ("memory", "Memory and activity"),
        ("meeting-sources", "Record and import meetings"),
        ("reminders", "Reminders and briefs"),
        ("mcp", "Connect AI clients"),
    ],
    "Privacy": [
        ("privacy", "Capture and data flow"),
        ("data-controls", "Pause, exclude, and delete"),
    ],
    "Reference": [
        ("settings", "Settings"),
        ("shortcuts", "Keyboard shortcuts"),
        ("mcp-tools", "MCP tools"),
        ("troubleshooting", "Troubleshooting"),
    ],
}


class Article(HTMLParser):
    """Collect heading links and searchable text from one article."""

    def __init__(self, title, group):
        super().__init__()
        self.group = group
        self.headings = []
        self.sections = [{"heading": "", "id": "", "text": []}]
        self.in_heading = False
        self.title = title

    def handle_starttag(self, tag, attrs):
        if tag == "h2":
            anchor = dict(attrs).get("id")
            if not anchor:
                raise ValueError(f"{self.title}: each h2 needs an id")
            self.sections.append({"heading": "", "id": anchor, "text": []})
            self.in_heading = True
        elif tag in {"p", "li", "td", "th", "dt", "dd", "h3", "div", "br", "pre"}:
            self.sections[-1]["text"].append(" ")

    def handle_endtag(self, tag):
        if tag == "h2":
            heading = self.sections[-1]
            heading["heading"] = heading["heading"].strip()
            self.headings.append((heading["id"], heading["heading"]))
            self.in_heading = False

    def handle_data(self, data):
        if self.in_heading:
            self.sections[-1]["heading"] += data
        else:
            self.sections[-1]["text"].append(data)

    def index(self, path):
        return [
            {"title": self.title, "heading": section["heading"], "group": self.group,
             "url": path + ("#" + section["id"] if section["id"] else ""),
             "text": " ".join("".join(section["text"]).split())}
            for section in self.sections
        ]


class PageLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = set()

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key == "id":
                if value in self.ids:
                    raise ValueError(f"Duplicate id: {value}")
                self.ids.add(value)
            elif key in ("href", "src"):
                self.links.add(value)


def validate(pages):
    for source, page in pages.items():
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            target = source
            if url.path:
                path = url.path + "index.html" if url.path.endswith("/") else url.path
                target = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
            if not (OUTPUT / target).is_file():
                raise ValueError(f"{source}: missing link target {link}")
            if url.fragment and (target not in pages or url.fragment not in pages[target].ids):
                raise ValueError(f"{source}: missing anchor {link}")


def docs_path(slug):
    return "docs/" + (slug + "/" if slug else "")


def sidebar(root, current):
    groups = []
    for label, links in GROUPS.items():
        items = []
        for slug, title in links:
            active = ' aria-current="page"' if slug == current else ""
            items.append(f'<li><a href="{root}{docs_path(slug)}"{active}>{escape(title)}</a></li>')
        groups.append(f'<div class="nav-group"><p>{label}</p><ul>{"".join(items)}</ul></div>')
    return "".join(groups)


def pager(root, pages, index):
    links = []
    for offset, label in [(-1, "Previous"), (1, "Next")]:
        target = index + offset
        if 0 <= target < len(pages):
            slug, title = pages[target]
            links.append(f'<a rel="{label.lower()}" href="{root}{docs_path(slug)}"><span>{label}</span>{escape(title)}</a>')
    return '<nav class="pager" aria-label="Adjacent pages">' + "".join(links) + "</nav>"


def render(template, **values):
    for name, value in values.items():
        template = template.replace(f"@{name.upper()}@", value)
    return template


def latest_download_url(repository):
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    path = urlsplit(repository).path
    request = Request(f"{api}/repos{path}/releases/latest", headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("REMORA_SITE_GITHUB_TOKEN")
    if token:
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    try:
        with urlopen(request, timeout=10) as response:
            release = json.load(response)
    except HTTPError as error:
        if error.code == 404:
            return ""
        raise
    return next((asset["browser_download_url"] for asset in release["assets"] if asset["name"].endswith(".dmg")), "")


def bundle_search():
    """Bundle the Docspot search module into assets/search.js and assets/search.css."""
    npm = shutil.which("npm")
    if not npm:
        raise SystemExit("The site search needs Node.js and npm. Install Node.js, then build again.")
    if not (SEARCH / "node_modules").is_dir():
        subprocess.run([npm, "ci", "--no-audit", "--no-fund"], cwd=SEARCH, check=True)
    # Chunk names carry a content hash, so clear the previous build's chunks before writing new ones.
    for chunk in (OUTPUT / "assets").glob("search-*.js"):
        chunk.unlink()
    metafile = OUTPUT / "search-meta.json"
    subprocess.run([npm, "run", "--silent", "build", "--", f"--outdir={OUTPUT / 'assets'}", f"--metafile={metafile}"],
                   cwd=SEARCH, check=True)
    write_search_licenses(json.loads(metafile.read_text(encoding="utf-8")))
    metafile.unlink()


def write_search_licenses(metafile):
    """Publish the license of every npm package bundled into the search, as their MIT terms require."""
    packages = set()
    for source in metafile["inputs"]:
        parts = Path(source).parts
        if "node_modules" in parts:
            start = parts.index("node_modules") + 1
            packages.add("/".join(parts[start:start + (2 if parts[start].startswith("@") else 1)]))
    notices = []
    for name in sorted(packages):
        folder = SEARCH / "node_modules" / name
        manifest = json.loads((folder / "package.json").read_text(encoding="utf-8"))
        if "license" not in manifest:
            raise SystemExit(f"{name} declares no license, so the site search can't publish it")
        files = sorted(folder.glob("LICEN[CS]E*")) + sorted(folder.glob("license*"))
        # A few packages ship only the license name; point to their source for the full text.
        text = files[0].read_text(encoding="utf-8").strip() if files else \
            f"The package ships no license file. See {manifest.get('homepage') or 'its repository'}."
        notices.append(f"{name} {manifest['version']} ({manifest['license']})\n\n{text}")
    (OUTPUT / "assets/search-licenses.txt").write_text(
        "The site search bundles these packages.\n\n" + "\n\n---\n\n".join(notices) + "\n", encoding="utf-8")


def build(repository, branch, download_url):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    shutil.copytree(SOURCE / "assets", OUTPUT / "assets", dirs_exist_ok=True)
    bundle_search()
    icons = REPO / "App/Remora/Assets.xcassets/AppIcon.appiconset"
    glyph = icons.parent / "RemoraGlyph.imageset" / "remora_2x.png"
    shutil.copyfile(icons / "icon_128x128_2x.png", OUTPUT / "assets/remora.png")
    shutil.copyfile(glyph, OUTPUT / "assets/remora-glyph.png")
    shutil.copyfile(icons / "icon_16x16.png", OUTPUT / "assets/favicon-16.png")
    shutil.copyfile(icons / "icon_32x32.png", OUTPUT / "assets/favicon.png")
    template = (SOURCE / "layout.html").read_text(encoding="utf-8")
    page_links = {}
    search = []

    def write(path, root, title, description, kind, content):
        file = OUTPUT / path
        file.parent.mkdir(parents=True, exist_ok=True)
        github = f'<a href="{repository}" class="github-link">GitHub</a>' if repository else ""
        docs_current = ' aria-current="true"' if kind == "docs" else ""
        home_current = ' aria-current="page"' if kind == "home" else ""
        home = root if path != "index.html" else "./"
        document = render(template, root=root, home=home, title=escape(title), description=escape(description),
                          kind=kind, github=github, docs_current=docs_current, home_current=home_current,
                          content=render(content, root=root))
        document = render(document, download=download_url or f"{root}docs/installation/")
        file.write_text(document, encoding="utf-8")
        links = PageLinks()
        links.feed(document)
        page_links[path] = links

    home = (SOURCE / "pages/home.html").read_text(encoding="utf-8")
    filename = posixpath.basename(urlsplit(download_url).path)
    version = re.fullmatch(r"Remora-([0-9]+\.[0-9]+\.[0-9]+)\.dmg", filename)
    home = render(home, version_label=f"Version {version[1]} · " if version else "")
    write("index.html", "./", "Remora — A local memory for your Mac",
          "Rewrite in place, dictate on your Mac, and ask questions about what you’ve seen.", "home", home)
    pages = [page for group in GROUPS.values() for page in group]
    article_layout = (SOURCE / "article.html").read_text(encoding="utf-8")
    for index, (slug, title) in enumerate(pages):
        path = docs_path(slug)
        source_file = (slug or "overview") + ".html"
        body = (SOURCE / "pages" / source_file).read_text(encoding="utf-8")
        if slug == "installation":
            releases = f'<a href="{repository}/releases">Releases</a>' if repository else "the repository’s Releases page"
            if download_url:
                download = f'<a href="{download_url}">Download the Remora disk image</a> (<code>.dmg</code>).'
            else:
                download = f'Download the Remora disk image (<code>.dmg</code>) from {releases} when a release is available.'
            body = render(body, install_download=download)
        group = next(label for label, links in GROUPS.items() if (slug, title) in links)
        article = Article(title, group)
        article.feed(body)
        results = article.index(path)
        search.extend(results)
        description = results[0]["text"].split(". ")[0].rstrip(".") + "."
        root = "../" if not slug else "../../"
        toc = "".join(f'<li><a href="#{anchor}">{escape(heading)}</a></li>' for anchor, heading in article.headings)
        edit = ""
        if repository:
            url = f"{repository}/edit/{quote(branch, safe='')}/docs/site/pages/{source_file}"
            edit = f'<a class="edit-link" href="{url}">Edit this page on GitHub</a>'
        crumb = f'<a href="{root}docs/">Documentation</a><span aria-hidden="true">/</span>{group}' if slug else ""
        content = render(article_layout, sidebar=sidebar(root, slug), toc=toc, crumb=crumb,
                         article_title=escape(title if slug else "Remora documentation"),
                         body=body, pager=pager(root, pages, index), edit=edit)
        write(path + "index.html", root, f"{title} — Remora docs", description, "docs", content)

    (OUTPUT / "assets/search.json").write_text(json.dumps(search, ensure_ascii=False), encoding="utf-8")
    (OUTPUT / ".nojekyll").touch()
    validate(page_links)
    print(f"Built {len(page_links)} pages and indexed {len(search)} sections in {OUTPUT.relative_to(REPO)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("REMORA_SITE_REPOSITORY", DEFAULT_REPOSITORY),
                        help="GitHub repository URL, used for the download, Releases and page edits")
    parser.add_argument("--download-url", default=os.environ.get("REMORA_SITE_DOWNLOAD_URL"),
                        help="Override the release download URL. Pass an empty string for an offline build.")
    parser.add_argument("--branch", default="main", help="branch for GitHub edit links")
    args = parser.parse_args()
    repository = args.repository.rstrip("/")
    download_url = args.download_url
    if download_url is None and repository:
        download_url = latest_download_url(repository)
    build(escape(repository, quote=True), args.branch, escape(download_url or "", quote=True))
