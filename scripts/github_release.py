"""Check and publish a verified Actions build using the workflow's short-lived token."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


SPARKLE = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
VERSION_CONFIG = Path(__file__).resolve().parents[1] / "Config" / "Version.xcconfig"


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def version_key(version):
    if not re.fullmatch(r"(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){2}", version):
        raise ValueError(f"Invalid release version {version!r}. Expected x.y.z.")
    return tuple(map(int, version.split(".")))


def positive_build(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("Expected a positive integer Sparkle build.")
    return int(value)


def needs_release(version, build, records, appcast_for):
    published = [record for record in records if not record["draft"]]
    if any(record["tag_name"] == f"v{version}" for record in published):
        return False
    for record in published:
        tag = record["tag_name"]
        if version_key(tag.removeprefix("v")) >= version_key(version):
            raise ValueError(f"Version {version} must be newer than published {tag}.")
        versions = ET.fromstring(appcast_for(tag)).findall("./channel/item/sparkle:version", SPARKLE)
        if not versions or any(not (node.text or "").strip() for node in versions):
            raise ValueError(f"The appcast for {tag} is missing its Sparkle build.")
        previous_build = max(positive_build(node.text.strip()) for node in versions)
        if build <= previous_build:
            raise ValueError(f"Build {build} must be newer than {tag} build {previous_build}.")
    return True


def release_records(repository):
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"))
    return [record for page in pages for record in page]


def published_appcast(repository, tag):
    return gh("release", "download", tag, "--pattern", "appcast.xml", "--output", "-", "--repo", repository)


def tag_commit(tag):
    ref = f"refs/tags/{tag}"
    matching = subprocess.check_output(["git", "ls-remote", "origin", ref, f"{ref}^{{}}"], text=True)
    refs = {name: sha for sha, name in (line.split() for line in matching.splitlines())}
    return refs.get(f"{ref}^{{}}", refs.get(ref))


def require_current_main(repository, sha):
    main = gh("api", f"repos/{repository}/git/ref/heads/main", "--jq", ".object.sha")
    if main != sha:
        raise ValueError("Main advanced while the release was running. Only the current main commit can publish.")


def release_draft(records, tag, expected_assets):
    draft = next((record for record in records if record["draft"] and record["tag_name"] == tag), None)
    if draft and (
        draft["author"]["login"] != "github-actions[bot]"
        or draft["prerelease"]
        or draft["published_at"]
        or any(asset["name"] not in expected_assets for asset in draft["assets"])
    ):
        raise ValueError(f"Review the existing draft for {tag} before publishing.")
    return draft


def publish(repository, version, build, sha, records, files):
    tag = f"v{version}"
    tagged_sha = tag_commit(tag)
    if tagged_sha and tagged_sha != sha:
        raise ValueError(f"Tag {tag} points to a different commit.")
    expected_assets = {Path(file).name for file in files}
    draft = release_draft(records, tag, expected_assets)
    require_current_main(repository, sha)
    if draft:
        gh("release", "upload", tag, *files, "--clobber", "--repo", repository)
    else:
        gh("release", "create", tag, *files, "--draft", "--target", sha, "--title", f"Remora {version}",
           "--generate-notes", "--repo", repository)

    records = release_records(repository)
    if not needs_release(version, build, records, lambda tag: published_appcast(repository, tag)):
        return
    staged = release_draft(records, tag, expected_assets)
    if (
        staged is None
        or (draft and staged["id"] != draft["id"])
        or {asset["name"] for asset in staged["assets"] if asset["state"] == "uploaded"} != expected_assets
    ):
        raise ValueError(f"The draft for {tag} changed or is missing release files.")
    tagged_sha = tag_commit(tag)
    if tagged_sha and tagged_sha != sha:
        raise ValueError(f"Tag {tag} points to a different commit.")
    require_current_main(repository, sha)
    gh("api", "--method", "PATCH", f"repos/{repository}/releases/{staged['id']}",
       "-f", f"target_commitish={sha}", "-F", "draft=false", "-f", "make_latest=true")
    print(f"Published Remora {version} (build {build}).")


def release_files(directory, repository, version, build):
    dmg = directory / f"Remora-{version}.dmg"
    appcast = directory / "appcast" / "appcast.xml"
    item = ET.parse(appcast).find("./channel/item")
    url = f"https://github.com/{repository}/releases/download/v{version}/{dmg.name}"
    if item is not None:
        enclosure = item.find("enclosure")
        if (
            item.findtext("sparkle:shortVersionString", namespaces=SPARKLE) == version
            and item.findtext("sparkle:version", namespaces=SPARKLE) == str(build)
            and enclosure is not None
            and enclosure.get("url") == url
            and enclosure.get("length") == str(dmg.stat().st_size)
            and enclosure.get(f"{{{SPARKLE['sparkle']}}}edSignature")
        ):
            return [str(dmg), str(appcast)]
    raise ValueError("The appcast does not describe the requested signed release files.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    publication = commands.add_parser("publish")
    publication.add_argument("sha")
    publication.add_argument("directory", type=Path)
    args = parser.parse_args()

    config = dict(line.split(" = ", 1) for line in VERSION_CONFIG.read_text().splitlines())
    version = config["MARKETING_VERSION"]
    version_key(version)
    build = positive_build(config["CURRENT_PROJECT_VERSION"])
    repository = os.environ["GITHUB_REPOSITORY"]
    records = release_records(repository)
    needed = needs_release(version, build, records, lambda tag: published_appcast(repository, tag))
    if args.command == "check":
        print("true" if needed else "false")
    elif needed:
        files = release_files(args.directory, repository, version, build)
        publish(repository, version, build, args.sha, records, files)
    else:
        print(f"Remora {version} already has a published release.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"Release failed: {error}")
