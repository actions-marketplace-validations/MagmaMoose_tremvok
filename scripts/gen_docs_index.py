"""Emit the docs search corpus, llms.txt and llms-full.txt from a built MkDocs site.

Per ADR-0005 (MagmaMoose/nievah, docs/adr/0005-docs-sites-and-mcp-surfaces.md) the docs
build is the synchronisation mechanism for the fleet-wide documentation corpus. The build
has just rendered every markdown file, so an index emitted here is in sync with the site
that is about to deploy *by construction* — no GitHub API at request time, no token in a
Worker, and nothing to go stale between a merge and a cron.

Three artefacts, one pass:

``index/<repo>.json``   the search corpus, published to the shared R2 bucket
``llms.txt``            the link index, served from the site root
``llms-full.txt``       every page's markdown, concatenated, served from the site root

THE INDEX IS A CONTRACT WITH ITS READER, NOT A FORMAT OF OUR CHOOSING. The consumer is the
documentation MCP Worker in ``MagmaMoose/mcp``, and its ``schema/index.schema.json`` is the
contract: ``schema``, ``repo``, ``private`` and ``docs``, each document carrying its
repository-relative ``path`` and its markdown ``text``. An index that drifted from it would
not fail anywhere. The reader treats a missing ``docs`` as no documents and a missing
``private`` as private, so every surface would quietly serve nothing, which is the failure
this module is written against. ``test_the_index_meets_the_readers_contract`` pins it.

``private`` comes from the repository's visibility and fails closed: only an explicit
``public`` makes an index public. ``internal``, an empty value and anything unrecognised
are all private, because the other direction publishes a runbook on a typo.

WHY THIS IS NOT A MKDOCS PLUGIN. A plugin has to be named in ``plugins:``, and a repo
that declares ``plugins:`` in its own ``mkdocs.yml`` silently discards every entry in the
shared ``mkdocs.base.yml`` — MkDocs REPLACES lists rather than merging them, with nothing
reported. ``lint_docs.check_inherit_not_clobbered`` fails the build on exactly that. So
this runs as a step after ``mkdocs build`` instead, which needs no ``plugins:`` key in any
repo and therefore cannot trip the trap. If it ever does become a plugin, it belongs in
``MagmaMoose/admin`` -> ``files/docs/mkdocs.base.yml``, once, for the fleet.

URL SHAPE IS DETECTED, NOT DECLARED. ``use_directory_urls`` defaults to true but a repo
may turn it off, and a corpus whose citations 404 is worse than no corpus. Rather than
re-deriving MkDocs' rule from config, each page's URL is resolved by looking at which
file the build actually emitted. Same principle as ``pages-detect.sh``: the tree is the
fact.

THE SITE ALSO DECIDES WHICH PAGES ARE IN THE CORPUS. ``exclude_docs`` and ``draft_docs``
keep a file in ``docs/`` but out of the build, and walking the markdown still finds it.
Indexed at the URL it would have had, it becomes a citation that 404s on every MCP surface
reading the corpus. So when there is a built site, a source file it has no page for is
left out. Re-deriving that from ``exclude_docs`` would mean reimplementing MkDocs'
gitignore-style patterns and its defaults (``.*``, ``/templates/``); the build has
already applied them.

PyYAML is imported rather than hand-rolled, on the same grounds as ``lint_docs.py``: this
runs after the docs toolchain is installed, and MkDocs depends on PyYAML.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import yaml

#: The index schema version the reader in MagmaMoose/mcp understands.
INDEX_SCHEMA_VERSION = 1

# How much of a page's opening prose to carry as the snippet. Long enough to disambiguate
# two pages with similar titles, short enough that a search result set stays readable in
# an agent's context window.
SNIPPET_CHARS = 320


# --------------------------------------------------------------------------- model


@dataclass
class Entry:
    """One page in the corpus.

    ``repo`` is repeated on every entry even though the document carries it once, because
    the read side merges N of these files into one result set and a hit has to be able to
    say where it came from without its container.
    """

    repo: str
    #: Repository-relative, e.g. ``docs/setup.md``. The reader's ``read_doc`` takes this and
    #: its ranking boosts on the filename in it, so it is the real source path, not a slug.
    path: str
    title: str
    headings: list[str] = field(default_factory=list)
    snippet: str = ""
    url: str = ""
    #: The page's markdown as authored, front matter removed. Not rendered HTML: the reader
    #: scores ``#`` headings above prose, and ``read_doc`` returns the page itself.
    text: str = ""
    bytes: int = 0


# --------------------------------------------------------------------------- parsing


def load_yaml(path: Path) -> dict[str, Any]:
    """Parse a YAML file, tolerating MkDocs' python/name tags."""
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    # mkdocs.yml legitimately carries `!!python/name:...` for superfences custom_fences;
    # safe_load refuses it, and we only ever read plain keys, so neutralise the tag.
    text = re.sub(r"!!python/name:\S+", "'<python-name>'", text)
    try:
        return yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:  # pragma: no cover - mkdocs build fails on this first
        raise SystemExit(f"gen-docs-index: cannot parse {path}: {exc}") from exc


def strip_front_matter(text: str) -> tuple[dict[str, Any], str]:
    """Split a leading `---` YAML block off the body, if there is one."""
    if not text.startswith("---"):
        return {}, text
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.S)
    if not match:
        return {}, text
    try:
        meta = yaml.safe_load(match.group(1)) or {}
    except yaml.YAMLError:
        return {}, text
    return (meta if isinstance(meta, dict) else {}), match.group(2)


def plain_text(markdown: str) -> str:
    """Flatten inline markdown to something worth putting in a snippet.

    Deliberately not a markdown parser. This feeds a snippet and a heading list, where
    being approximately right costs nothing and a dependency costs a pin.
    """
    text = markdown
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)  # images, before links
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # inline links
    text = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", text)  # reference links
    text = re.sub(r"`{1,3}([^`]*)`{1,3}", r"\1", text)  # code spans
    text = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", text)  # emphasis, asterisk form
    # Underscore emphasis only at a word boundary. Markdown itself ignores an intraword
    # underscore, and treating one as emphasis turns `gen_action_reference.py` into
    # `genactionreference.py` — a snippet naming a file that does not exist, in a corpus
    # whose whole job is letting an agent find the file.
    text = re.sub(r"(?<![\w])_{1,3}([^_]+)_{1,3}(?![\w])", r"\1", text)
    text = re.sub(r"\{[^}]*\}", "", text)  # attr_list, e.g. `{ #anchor }`
    text = re.sub(r"<[^>]+>", "", text)  # stray inline HTML
    return re.sub(r"\s+", " ", text).strip()


def body_without_fences(markdown: str) -> str:
    """Drop fenced code blocks.

    A ```mermaid block is diagram source: indexing it means a search for "flowchart"
    matches every architecture page in the fleet, which is noise on every query.
    """
    return re.sub(r"^```.*?^```", "", markdown, flags=re.S | re.M)


def extract_title(meta: dict[str, Any], body: str, path: Path) -> str:
    if isinstance(meta.get("title"), str) and meta["title"].strip():
        return meta["title"].strip()
    match = re.search(r"^#\s+(.+?)\s*$", body, re.M)
    if match:
        return plain_text(match.group(1))
    return path.stem.replace("-", " ").replace("_", " ").strip().capitalize()


def extract_headings(body: str) -> list[str]:
    """H2 and H3 only.

    H1 is the title and is already carried separately; H4 and below are almost always
    parameter names in reference pages, which bloat the corpus without helping a query
    land on the right page.
    """
    found: list[str] = []
    for match in re.finditer(r"^(#{2,3})\s+(.+?)\s*$", body_without_fences(body), re.M):
        text = plain_text(match.group(2))
        if text and text not in found:
            found.append(text)
    return found


def extract_snippet(body: str) -> str:
    """The first real paragraph, minus the title and any admonition scaffolding."""
    stripped = body_without_fences(body)
    stripped = re.sub(r"^#\s+.+?$", "", stripped, count=1, flags=re.M)
    for block in re.split(r"\n\s*\n", stripped):
        candidate = block.strip()
        if not candidate or candidate.startswith(("#", "|", "---", "===")):
            continue
        # `!!! note` / `> ` openers are scaffolding; keep the prose inside them.
        candidate = re.sub(r"^!!!.*$", "", candidate, flags=re.M)
        candidate = re.sub(r"^>\s?", "", candidate, flags=re.M)
        text = plain_text(candidate)
        if not text:
            continue
        if len(text) <= SNIPPET_CHARS:
            return text
        return text[:SNIPPET_CHARS].rsplit(" ", 1)[0] + "…"
    return ""


# --------------------------------------------------------------------------- urls


def url_path_for(rel: Path, site_dir: Path) -> str | None:
    """Resolve a source path to the site-relative URL the build actually emitted.

    Detection, not declaration — see the module docstring. ``None`` means the site exists
    and has no page for this source: the build excluded it, so there is no URL to cite.
    The fallback is the ``use_directory_urls: true`` convention, which is MkDocs' default,
    used only when there is no built site to look at (unit tests, a --check run).
    """
    stem = rel.with_suffix("")
    parent = stem.parent

    # `index.md` is the directory itself under either URL style — `use_directory_urls: false`
    # renders it to `<dir>/index.html`, which is still served as `<dir>/`. MkDocs renders a
    # `README.md` to the same file, so `<dir>/README/` never exists. The shape needs no
    # detecting here, only whether the page was built at all.
    if stem.name in ("index", "README"):
        directory_url = "" if str(parent) == "." else parent.as_posix() + "/"
        if site_dir.is_dir() and not (site_dir / directory_url / "index.html").is_file():
            return None
        return directory_url

    directory_url = stem.as_posix() + "/"
    flat_url = stem.as_posix() + ".html"

    if not site_dir.is_dir():
        return directory_url
    if (site_dir / directory_url / "index.html").is_file():
        return directory_url
    if (site_dir / flat_url).is_file():
        return flat_url
    return None


def markdown_twin(url_path: str) -> str:
    """The site-relative path of a page's markdown twin, which ``gen_docs_seo.py`` writes.

    llmstxt.org: the clean markdown of a page sits at the page's own URL with the extension
    replaced by ``.md``, and a URL with no file name takes ``index.md``. So ``setup/`` ->
    ``setup/index.md``, ``setup.html`` -> ``setup.md``, and the site root -> ``index.md``.
    A build's ``dest_uri`` (``setup/index.html``) maps to the same file as its URL does.
    Defined here, beside ``url_path_for``, because llms.txt is what links to it.
    """
    if not url_path or url_path.endswith("/"):
        return f"{url_path}index.md"
    return f"{url_path.removesuffix('.html')}.md"


def canonical_url(site_url: str, url_path: str) -> str:
    """``<site_url>/<path>`` — for the fleet, ``https://docs.magmamoose.com/<repo>/<path>``.

    The base is the site's own ``site_url`` rather than a host this script knows about.
    Tremvok is a public Marketplace action and third parties pin ``@v2``; a MagmaMoose
    hostname baked in here would put magmamoose.com URLs in a stranger's corpus. ADR-0005
    gets its ``docs.magmamoose.com/<repo>/`` citations because that is what each repo's
    ``site_url`` becomes, which is the same fact MkDocs already needs in order to emit
    correct canonical links.
    """
    return f"{site_url.rstrip('/')}/{url_path.lstrip('/')}"


# --------------------------------------------------------------------------- build


def collect(
    docs_dir: Path,
    site_dir: Path,
    repo: str,
    site_url: str,
    source_prefix: str = "docs",
) -> tuple[list[Entry], dict[str, str], list[str]]:
    """Walk the docs tree once, returning entries and each entry's raw markdown body.

    Also returns the source paths left out because the built site has no page for them,
    so the caller can say what it dropped rather than drop it silently.

    ``source_prefix`` is the docs directory as the repository names it, so an entry's
    ``path`` is repository-relative while its URL is still resolved from the path inside
    the docs tree, which is what MkDocs renders from.
    """
    entries: list[Entry] = []
    bodies: dict[str, str] = {}
    unbuilt: list[str] = []
    prefix = source_prefix.strip("/")

    for path in sorted(docs_dir.rglob("*.md")):
        rel = path.relative_to(docs_dir)
        source = f"{prefix}/{rel.as_posix()}" if prefix else rel.as_posix()
        url_path = url_path_for(rel, site_dir)
        if url_path is None:
            unbuilt.append(source)
            continue
        meta, body = strip_front_matter(path.read_text(encoding="utf-8"))
        entry = Entry(
            repo=repo,
            path=source,
            title=extract_title(meta, body, path),
            headings=extract_headings(body),
            snippet=extract_snippet(body),
            url=canonical_url(site_url, url_path),
            text=body,
            bytes=len(body.encode("utf-8")),
        )
        entries.append(entry)
        bodies[entry.path] = body

    return entries, bodies, unbuilt


def is_private(visibility: str) -> bool:
    """Only an explicit ``public`` is public. See the module docstring for why."""
    return visibility.strip().lower() != "public"


def render_index(
    repo: str,
    site_url: str,
    entries: list[Entry],
    commit: str,
    *,
    private: bool = True,
) -> str:
    document = {
        "schema": INDEX_SCHEMA_VERSION,
        "repo": repo,
        "private": private,
        "site_url": site_url,
        "generated": datetime.now(UTC).isoformat(timespec="seconds"),
        "commit": commit,
        "docs": [asdict(entry) for entry in entries],
    }
    # sort_keys so a rebuild of unchanged docs produces a byte-identical file, which is
    # what lets the publish step skip an upload that would change nothing.
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def render_llms_txt(
    site_name: str,
    site_description: str,
    site_url: str,
    entries: list[Entry],
    twins: dict[str, str] | None = None,
) -> str:
    """The llms.txt link index, per https://llmstxt.org/.

    ``twins`` maps an entry's source path to its markdown twin's URL. The spec asks for the
    links to point at "LLM-friendly content, such as the markdown versions of pages", so a
    page that has one is listed by it, and a page that has none keeps its HTML URL.
    """
    twins = twins or {}
    lines = [f"# {site_name}", ""]
    if site_description:
        lines += [f"> {site_description}", ""]
    lines += [
        f"Canonical documentation for {site_name}, served at {site_url}.",
        "The full text of every page below is at `llms-full.txt`.",
    ]
    if twins:
        # An agent that cites what it read should cite the page, not its markdown copy.
        lines.append(
            "Each link is the page's markdown. The page itself is the same address without "
            "the `index.md`, or with `.html` in place of `.md`."
        )
    lines += ["", "## Docs", ""]
    for entry in entries:
        suffix = f": {entry.snippet}" if entry.snippet else ""
        lines.append(f"- [{entry.title}]({twins.get(entry.path, entry.url)}){suffix}")
    return "\n".join(lines) + "\n"


def render_llms_full_txt(
    site_name: str,
    site_url: str,
    entries: list[Entry],
    bodies: dict[str, str],
) -> str:
    parts = [
        f"# {site_name}",
        "",
        f"Every documentation page, concatenated. Canonical site: {site_url}",
        "",
    ]
    for entry in entries:
        # The page's own H1 is dropped: the heading emitted just above carries the title,
        # and two identical H1s in a row reads to a model as two documents.
        body = re.sub(r"^#\s+.+?$", "", bodies.get(entry.path, ""), count=1, flags=re.M)
        parts += [
            "---",
            "",
            f"# {entry.title}",
            "",
            f"Source: {entry.path}",
            f"URL: {entry.url}",
            "",
            body.strip(),
            "",
        ]
    return "\n".join(parts) + "\n"


# --------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="gen_docs_index.py",
        description="Emit the docs search corpus, llms.txt and llms-full.txt.",
    )
    parser.add_argument("--root", type=Path, default=Path("."), help="repository root")
    parser.add_argument("--docs-dir", default="docs", help="markdown source directory")
    parser.add_argument("--site-dir", default="site", help="built site directory")
    parser.add_argument("--repo", required=True, help="repository name, e.g. tremvok")
    parser.add_argument(
        "--site-url",
        default="",
        help="canonical base for this repo's pages. Defaults to `site_url` from mkdocs.yml.",
    )
    parser.add_argument(
        "--index-out",
        type=Path,
        default=None,
        help="where index/<repo>.json is written (default: <site-dir>/../.docs-index)",
    )
    parser.add_argument("--commit", default="", help="commit sha recorded in the index")
    parser.add_argument(
        "--visibility",
        default="",
        help="the repository's visibility. Only `public` marks the index public; anything "
        "else, including nothing, marks it private.",
    )
    args = parser.parse_args(argv)

    root: Path = args.root
    docs_dir = root / args.docs_dir
    site_dir = root / args.site_dir

    if not docs_dir.is_dir():
        print(f"::error::gen-docs-index: no {args.docs_dir}/ in {root}", file=sys.stderr)
        return 1

    config = load_yaml(root / "mkdocs.yml")
    site_name = str(config.get("site_name") or args.repo)
    site_description = str(config.get("site_description") or "")

    # `site_url` is already the canonical base MkDocs emits its own <link rel="canonical">
    # from, so deriving the corpus URLs from it means a citation cannot disagree with the
    # page it cites. An empty one is a hard error rather than a guess: a corpus of URLs
    # that 404 is worse than no corpus, and it fails quietly at read time, in an agent,
    # days later.
    site_url = (args.site_url or str(config.get("site_url") or "")).strip()
    if not site_url:
        print(
            "::error::gen-docs-index: no `site_url:` in mkdocs.yml and no --site-url. "
            "The corpus cites absolute URLs, so there is nothing to build them from.",
            file=sys.stderr,
        )
        return 1
    if not site_url.endswith("/"):
        site_url += "/"

    entries, bodies, unbuilt = collect(docs_dir, site_dir, args.repo, site_url, args.docs_dir)
    if not entries:
        # Every source left out means the site is the wrong one (another --site-dir, a stale
        # build), not that there is no markdown. "No markdown" would send whoever reads it
        # to docs/, where nothing is wrong.
        reason = (
            f"{site_dir} has no page for any markdown file under {docs_dir}"
            if unbuilt
            else f"no markdown under {docs_dir}"
        )
        print(f"::error::gen-docs-index: {reason}", file=sys.stderr)
        return 1

    index_out: Path = args.index_out or (root / ".docs-index")
    (index_out / "index").mkdir(parents=True, exist_ok=True)
    index_path = index_out / "index" / f"{args.repo}.json"
    private = is_private(args.visibility)
    index_path.write_text(
        render_index(args.repo, site_url, entries, args.commit, private=private),
        encoding="utf-8",
    )

    # llms.txt and llms-full.txt go into the built site so they are served from the docs
    # host alongside the pages they describe. They are emitted only when the site exists;
    # a --strict build failure means there is nothing to attach them to.
    written = [str(index_path)]
    if site_dir.is_dir():
        # Detected, not declared, like every URL above: a twin is linked when the page-SEO
        # step wrote one, and a site built without that step keeps its HTML links.
        twins = {}
        for entry in entries:
            twin = markdown_twin(entry.url.removeprefix(site_url))
            if (site_dir / twin).is_file():
                twins[entry.path] = canonical_url(site_url, twin)
        for name, body in (
            ("llms.txt", render_llms_txt(site_name, site_description, site_url, entries, twins)),
            ("llms-full.txt", render_llms_full_txt(site_name, site_url, entries, bodies)),
        ):
            (site_dir / name).write_text(body, encoding="utf-8")
            written.append(str(site_dir / name))

    print(f"gen-docs-index: {len(entries)} pages -> {', '.join(written)}")
    if unbuilt:
        print(f"gen-docs-index: no page in {site_dir}, left out: {', '.join(unbuilt)}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
