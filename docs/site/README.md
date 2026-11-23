# Remora website

The website and its documentation are built with Python 3. The build copies Remora’s app icon and
glyph, renders static HTML, validates local links and anchors, and creates a browser-side search index.

## Preview

From the repository root, run:

```sh
make preview
```

Open [the local preview](http://127.0.0.1:8000/). Press `Ctrl+C` to stop the server.
After editing, run `python3 docs/site/build.py` in another terminal and refresh the page.
The build looks up the latest published DMG for Remora on GitHub. Pass
`--repository https://github.com/OWNER/REPO` to preview another repository or `--download-url ''`
to build offline.

## Edit

- Edit the homepage in `pages/home.html` and documentation in the other files under `pages/`.
- The homepage demo uses Apple's macOS 27 Golden Gate wallpaper and built-in app icons. The
  repository README image is a render of the demo's Recall view.
- Give each article section an `h2` with a stable `id`. The build uses these for the table of
  contents and search results.
- Use `@ROOT@` for links to this site. For example, link to `@ROOT@docs/rewrite/#edit-mode`.
  The build makes links relative so they work on a GitHub Pages project path or a custom domain.
- Register new articles in `GROUPS` in `build.py`.

## Publish

In the GitHub repository, open **Settings › Pages** and select **GitHub Actions** as the source.
On `main`, the **Website** workflow publishes changes to the site sources or app icon. You can
also run it on demand from **Actions › Website › Run workflow**. The deployment records the site
URL in the `github-pages` environment.

Release changes also rebuild the website from the default branch. The build links the download
buttons to the latest release's DMG when one is available.

The workflow uploads the contents of `dist/site`. GitHub generates the repository links from the
repository that runs the workflow. See [GitHub’s publishing guide](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site).
