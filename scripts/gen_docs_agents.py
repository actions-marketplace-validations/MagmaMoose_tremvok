"""Make a built MkDocs site agent-ready: a skill that describes it, WebMCP tools, an auth.md.

Runs after ``mkdocs build``, the page-SEO step and the corpus step, for both docs targets
(``github-pages`` and ``cloudflare-docs``), and adds to the built site:

An Agent Skills index
    ``/.well-known/agent-skills/index.json`` (the Agent Skills Discovery RFC, v0.2.0) listing
    one skill, ``/.well-known/agent-skills/<name>/SKILL.md``. The skill tells an agent what the
    site covers, how to read it (llms.txt, llms-full.txt, each page's markdown copy,
    ``Accept: text/markdown``, the MCP server when one is configured) and how to cite it. Its
    ``digest`` is the SHA-256 of the bytes written, which is what a client verifies before it
    loads the skill into its context. Written into the built site rather than kept under
    ``docs/``, because MkDocs leaves dot-directories out of the build.

WebMCP tools
    ``assets/javascripts/webmcp.js``, a copy of ``scripts/docs_webmcp.js``, loaded from every
    page's head: ``search_docs``, ``read_page``, ``list_pages`` and ``open_page``, registered
    with the browser's model context on page load. Same-origin and dependency-free, so a site
    whose CSP is ``script-src 'self' ...`` runs it unchanged, and it does nothing in a browser
    without the API. That file says why each of its rules is there.

An auth.md
    ``/auth.md``, for a site served at the root of its host: the documentation needs no
    registration and no credentials, and the MCP server, when there is one, is the authority on
    its own access. A site mounted under a path gets none: ``wants_auth_md`` says why, and why
    the file cannot contradict a real one served in its place.

WHAT THE SKILL SAYS IS READ OFF THE BUILT SITE, NOT ASSUMED. ``github-pages`` writes no
llms.txt, ``pages-seo: false`` writes no markdown copies, and a skill promising either would
send an agent to a 404 first. So each is mentioned when the file is there, which is also why
this step runs after the steps that write them.

EVERY PART IS SKIPPED WHERE THE SITE ALREADY HAS ITS OWN. A site that publishes its own
``/.well-known/agent-skills/`` keeps it, whole. A ``webmcp.js`` at that path that is not this
one is the site's own WebMCP, so no page is pointed at another. An ``auth.md`` that exists is
left as it is. The same rules make a second run change nothing.

CONFIGURATION IS ``extra.agents``, READ FROM THE RESOLVED CONFIG, for the reason ``extra.seo``
is: ``extra`` is a dict, dicts merge through INHERIT, so a shared base names the MCP server
once for a fleet. Every key is optional::

    extra:
      agents:
        mcp: https://mcp.example.com/   # named in the skill and in auth.md
        skill:                          # or `false` for no skill at all
          name: example-docs            # default: site_name, lowercased and hyphenated
          description: ...              # default: built from site_name and site_description
        webmcp: true                    # false: no WebMCP script
        auth_md: auto                   # auto: only at the root of a host; true; false

Nothing here names a MagmaMoose URL. Tremvok is a public Marketplace action, and a default that
put mcp.magmamoose.com into a stranger's skill would be a bug.

Python on the runner is deliberate and bounded, as it is for ``gen_docs_seo.py`` and
``gen_docs_index.py``: this runs inside the docs toolchain ``mkdocs build`` has just used, and no
deploy adapter depends on it.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import posixpath
import re
import sys
import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_docs_index import markdown_twin
from gen_docs_seo import Edit, PageInfo, Scan, apply_edit, clip, load_site

#: The opaque identifier the RFC's clients match exactly, before they read anything else.
SKILLS_SCHEMA = "https://schemas.agentskills.io/discovery/0.2.0/schema.json"

SKILLS_DIR = ".well-known/agent-skills"

#: Where the WebMCP script lives in the built site, beside Material's own bundles. The script
#: derives the site root from its own URL (two directories up), so this path is part of its
#: contract: move one and the other has to move with it.
WEBMCP_ASSET = "assets/javascripts/webmcp.js"
WEBMCP_SOURCE = Path(__file__).resolve().parent / "docs_webmcp.js"

#: Agent Skills names: 1-64 of a-z, 0-9 and single hyphens, never at either end, and the name
#: of the directory the SKILL.md sits in.
SKILL_NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SKILL_NAME_CHARS = 64
SKILL_DESCRIPTION_CHARS = 1024

#: A skill's body is loaded into an agent's context whole, and the spec asks for under 5k
#: tokens. The section map is capped so a site of four hundred pages stays well inside that.
SECTION_CHILDREN = 10
SECTIONS = 30

# A script element whose src ends in webmcp.js, with or without a query. Enough to recognise
# this step's own tag, and a site's own WebMCP script by the same name.
_WEBMCP_TAG = re.compile(
    r"""<script\b[^>]*\bsrc\s*=\s*["']?[^"'\s>]*\bwebmcp\.js(?=[?#"'\s>])""", re.I
)


# --------------------------------------------------------------------------- configuration


@dataclass
class Agents:
    """``extra.agents``, with defaults applied and every problem kept as a warning."""

    mcp: str = ""
    skill: bool = True
    skill_name: str = ""
    skill_description: str = ""
    webmcp: bool = True
    #: ``None`` is ``auto``: decided by where the site is served, see ``wants_auth_md``.
    auth_md: bool | None = None
    warnings: list[str] = field(default_factory=list)


def _flag(value: Any, key: str, warnings: list[str], *, auto: bool = False) -> bool | None:
    if isinstance(value, bool):
        return value
    if auto and (value is None or str(value).strip().lower() == "auto"):
        return None
    allowed = "true, false or auto" if auto else "true or false"
    warnings.append(f"extra.agents.{key} must be {allowed}; ignored")
    return None


def agents_from(config: Any) -> Agents:
    """Read ``extra.agents`` from the resolved MkDocs config.

    Mapping, never dict, for the reason ``gen_docs_seo.settings_from`` gives: MkDocs hands
    ``extra`` back as a LegacyConfig, which is a Mapping and not a dict.
    """
    agents = Agents()
    extra = config.get("extra") or {}
    raw = extra.get("agents") if isinstance(extra, Mapping) else None
    if raw is None:
        return agents
    if not isinstance(raw, Mapping):
        agents.warnings.append("extra.agents is not a mapping; using the defaults")
        return agents

    mcp = raw.get("mcp")
    if isinstance(mcp, Mapping):
        mcp = mcp.get("url")
    if mcp not in (None, ""):
        text = str(mcp).strip()
        parts = urlsplit(text)
        if parts.scheme in ("http", "https") and parts.netloc:
            agents.mcp = text
        else:
            agents.warnings.append(f"extra.agents.mcp is not an http(s) URL ({text}); ignored")

    skill = raw.get("skill")
    if skill is False:
        agents.skill = False
    elif isinstance(skill, Mapping):
        name = str(skill.get("name") or "").strip()
        if name and not is_skill_name(name):
            agents.warnings.append(
                f"extra.agents.skill.name {name!r} is not an Agent Skills name (a-z, 0-9 and "
                "single hyphens, at most 64); deriving one from site_name instead"
            )
        elif name:
            agents.skill_name = name
        agents.skill_description = " ".join(str(skill.get("description") or "").split())
    elif skill is not None:
        agents.warnings.append("extra.agents.skill must be a mapping or false; ignored")

    if "webmcp" in raw:
        webmcp = _flag(raw.get("webmcp"), "webmcp", agents.warnings)
        agents.webmcp = True if webmcp is None else webmcp
    if "auth_md" in raw:
        agents.auth_md = _flag(raw.get("auth_md"), "auth_md", agents.warnings, auto=True)
    return agents


# --------------------------------------------------------------------------- the skill


def is_skill_name(name: str) -> bool:
    return len(name) <= SKILL_NAME_CHARS and bool(SKILL_NAME.fullmatch(name))


def slug(text: str) -> str:
    """``Caleb Sargeant's Docs`` -> ``caleb-sargeants-docs``: a valid skill name, or ``""``.

    An apostrophe is dropped rather than turned into a hyphen, so a possessive stays one word,
    and an accent comes off its letter rather than taking the letter with it.
    """
    text = text.replace("\u2019", "").replace("'", "")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii").lower()
    words = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return words[:SKILL_NAME_CHARS].rstrip("-")


def titled(site_name: str, *, article: bool = False) -> str:
    """``Tremvok`` -> ``Tremvok documentation`` (``the Tremvok documentation`` with the
    article), but ``Caleb Sargeant's Docs`` as it is, with or without: a site whose name
    already says it is documentation does not need saying twice, and takes no article."""
    if re.search(r"\b(docs|documentation|handbook|manual|guide|wiki)\b", site_name, re.I):
        return site_name
    return f"{'the ' if article else ''}{site_name} documentation"


def skill_description(site_name: str, site_description: str, base: str) -> str:
    """What the skill is and when to load it.

    The description is the only part of a skill an agent reads before deciding to load it, so
    it says what the site is about and the task that should load it. The site's own sentence is
    clipped to leave room for the rest; ``write_skill`` holds the whole to 1024 characters.
    """
    trigger = (
        f"Use when a task involves {site_name}: it says what the site covers, where each "
        "page's markdown is, and how to cite it."
    )
    if site_description:
        lead = f"{titled(site_name)}. "
        room = SKILL_DESCRIPTION_CHARS - len(lead) - len(trigger) - 1
        return f"{lead}{clip(site_description, max(room, 80))} {trigger}"
    where = f" at {base}" if base else ""
    subject = titled(site_name, article=True)
    return f"{subject[0].upper()}{subject[1:]}{where}. {trigger}"


@dataclass
class Site:
    """What the skill and auth.md describe, read off the config and the built site."""

    name: str
    description: str
    #: The site's absolute address, or "" when there is none and every link is relative.
    base: str
    llms_txt: bool
    llms_full_txt: bool
    twins: bool
    flat: bool
    example: PageInfo | None
    mcp: str
    webmcp: bool


def _link(site: Site, path: str) -> str:
    """An absolute URL when the site has an address, else a path relative to the SKILL.md.

    A skill is often read on its own, fetched and cached far from the site, so an absolute URL
    is the one that keeps working. The relative form is for a site with no address at all:
    SKILL.md sits three directories below the root.
    """
    return urljoin(site.base, path) if site.base else f"../../../{path}"


def section_map(infos: list[PageInfo], site: Site) -> list[str]:
    """The top of the nav, one line per entry: a page, or a section and what is in it.

    Titles only, not descriptions: the skill is a map, and llms.txt is the index.
    """
    order: list[str] = []
    first: dict[str, PageInfo] = {}
    children: dict[str, list[str]] = {}
    for info in infos:
        if not info.in_nav:
            continue
        if not info.trail:
            key = f"page:{info.src_uri}"
            order.append(key)
            first[key] = info
            continue
        key = f"section:{info.trail[0]}"
        if key not in first:
            order.append(key)
            first[key] = info
            children[key] = []
        # One level down: a subsection by its title, or a page directly in the section, but
        # not the section's own index page, which is what the section's line links to.
        if len(info.trail) > 1:
            child = info.trail[1]
        elif info is first[key] and posixpath.basename(info.src_uri) in ("index.md", "README.md"):
            continue
        else:
            child = info.title
        if child != info.trail[0] and child not in children[key]:
            children[key].append(child)

    lines = []
    for key in order[:SECTIONS]:
        info = first[key]
        title = info.trail[0] if key.startswith("section:") else info.title
        line = f"- [{_label(title)}]({_link(site, info.url)})"
        kids = children.get(key, [])
        if kids:
            shown = ", ".join(_label(kid) for kid in kids[:SECTION_CHILDREN])
            hidden = len(kids) - SECTION_CHILDREN
            line += f": {shown}" + (f", and {hidden} more" if hidden > 0 else "")
        lines.append(line)
    if len(order) > SECTIONS:
        lines.append(f"- and {len(order) - SECTIONS} more at the top of the navigation")
    return lines


def _label(text: str) -> str:
    """Link text that cannot end the link early."""
    return re.sub(r"([\\\[\]])", r"\\\1", " ".join(text.split()))


def twin_rule(site: Site) -> str:
    example = site.example
    if site.flat:
        rule = "the page URL with `.html` replaced by `.md` (the home page's is `index.md`)"
    else:
        rule = "the page URL followed by `index.md`"
    if example is not None and site.base:
        page = urljoin(site.base, example.url)
        twin = urljoin(site.base, markdown_twin(example.url))
        return f"{rule}: {page} has its markdown at {twin}"
    return rule


def render_skill(site: Site, name: str, description: str, infos: list[PageInfo]) -> str:
    lines = [
        "---",
        f"name: {name}",
        # JSON's string syntax is YAML's double-quoted scalar, escapes included, so no quote or
        # colon in a site's description can break the front matter.
        f"description: {json.dumps(description, ensure_ascii=False)}",
        "---",
        "",
        f"# {titled(site.name)}",
        "",
    ]
    if site.description:
        lines += [site.description, ""]
    where = f"It is published at <{site.base}>, and its" if site.base else "Its"
    lines += [f"{where} top-level sections are:", "", *section_map(infos, site), ""]

    steps = []
    if site.llms_txt:
        steps.append(
            f"Start with [llms.txt]({_link(site, 'llms.txt')}): every page on one line with a "
            "summary, linking the page's markdown."
        )
    if site.llms_full_txt:
        steps.append(
            f"For a question that spans pages, [llms-full.txt]({_link(site, 'llms-full.txt')}) "
            "holds every page's markdown in one file."
        )
    if site.twins:
        steps.append(
            f"Every page has its markdown beside it, at {twin_rule(site)}. Asking for the page URL "
            "itself with `Accept: text/markdown` returns that markdown where the host supports it, "
            "and the HTML page where it does not."
        )
    if site.mcp:
        steps.append(f"The same documentation is searchable over MCP at <{site.mcp}>.")
    if site.webmcp:
        steps.append(
            "In a browser with WebMCP, every page registers `search_docs`, `read_page`, "
            "`list_pages` and `open_page` for this site."
        )
    if not steps:
        steps.append("Read the pages above; each links the rest from its navigation.")
    lines += ["## Read it", "", *(f"{n}. {step}" for n, step in enumerate(steps, 1)), ""]

    cite = "Cite the page URL."
    if site.twins:
        cite = (
            "Cite the page URL, not the URL of its markdown copy. Each markdown copy names the "
            "page it belongs to on the line under its title."
        )
    lines += ["## Cite it", "", cite, ""]
    return "\n".join(lines)


def render_index(name: str, description: str, url: str, digest: str) -> str:
    document = {
        "$schema": SKILLS_SCHEMA,
        "skills": [
            {
                "name": name,
                "type": "skill-md",
                "description": description,
                "url": url,
                "digest": digest,
            }
        ],
    }
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def sha256_digest(data: bytes) -> str:
    return f"sha256:{hashlib.sha256(data).hexdigest()}"


def skill_url(base: str, name: str) -> str:
    """The SKILL.md's URL as the index gives it.

    Path-absolute when the site's address is known (``/<repo>/.well-known/...`` behind a
    router, ``/.well-known/...`` at a host's root), because that resolves to the same file
    whether a client resolves it against the index, as the RFC says, or against the host, as
    at least one scanner does. Relative to the index when there is no address, which the RFC
    also allows and which is right wherever the site is mounted.
    """
    if base:
        path = urlsplit(base).path or "/"
        return f"{path if path.endswith('/') else path + '/'}{SKILLS_DIR}/{name}/SKILL.md"
    return f"{name}/SKILL.md"


# --------------------------------------------------------------------------- WebMCP


def webmcp_tag(page: Path, site_dir: Path, version: str, site_name: str) -> str:
    """The script element for one page: relative, like Material's own asset links, so it
    resolves wherever the site is mounted; deferred, so it runs once the page is parsed and
    blocks nothing; and versioned by content, so a changed script is not served from cache."""
    directory = posixpath.dirname(page.relative_to(site_dir).as_posix()) or "."
    src = posixpath.relpath(WEBMCP_ASSET, directory)
    # Escaped once for a double-quoted attribute, as gen_docs_seo writes its tags: `'` cannot
    # end the attribute, so it stays as it is.
    name = html.escape(site_name, quote=False).replace('"', "&quot;")
    return f'<script src="{src}?v={version}" defer data-site="{name}"></script>'


def has_webmcp_tag(document: str) -> bool:
    return bool(_WEBMCP_TAG.search(document))


# --------------------------------------------------------------------------- auth.md


def protected_resource_metadata(resource: str) -> str:
    """RFC 9728 section 3.1: the well-known URI goes between the host and the path, and the
    path's terminating slash goes. ``https://mcp.example.com/`` ->
    ``https://mcp.example.com/.well-known/oauth-protected-resource``, and
    ``https://docs.example.com/mcp`` -> ``.../.well-known/oauth-protected-resource/mcp``."""
    parts = urlsplit(resource)
    path = parts.path.rstrip("/")
    return f"{parts.scheme}://{parts.netloc}/.well-known/oauth-protected-resource{path}"


def render_auth_md(site: Site, skills_index: bool) -> str:
    """The auth.md for a site that asks nothing of its readers. One line per paragraph."""
    public = ["every page"]
    if site.twins:
        public.append("its markdown copy")
    if site.llms_txt:
        public.append("`llms.txt`")
    if site.llms_full_txt:
        public.append("`llms-full.txt`")
    if skills_index:
        public.append(f"the Agent Skills index at `/{SKILLS_DIR}/index.json`")
    listed = ", ".join(public[:-1]) + f" and {public[-1]}" if len(public) > 1 else public[0]
    audience = f"<{site.base}>" if site.base else "this site"

    paragraphs = [
        f"# {site.name} auth.md",
        "Reading this documentation needs no registration and no credentials. This file says so "
        "for an agent that looks for an auth.md before it reads.",
        "## Audience",
        f"Anyone, person or agent, reading {titled(site.name, article=True)} at {audience}.",
        "## Registration",
        "None. The documentation is a static site. It has no sign-up, no registration endpoint "
        "and no OAuth flow, and it issues no credentials, so there is nothing to register for, "
        "claim or revoke.",
        "## Credentials",
        f"Send none. {listed[0].upper()}{listed[1:]} answer an anonymous `GET`.",
        "## Other services",
    ]
    if site.mcp:
        paragraphs.append(
            f"The same documentation is searchable over MCP at <{site.mcp}>. That server is a "
            "separate service and the authority on its own access. An MCP server that requires "
            "authorization publishes OAuth protected-resource metadata (RFC 9728), for this one "
            f"at <{protected_resource_metadata(site.mcp)}>. Read that before connecting, not "
            "this file."
        )
    paragraphs.append(
        "This file describes the documentation only. Any other service on this host is "
        "described by its own metadata."
    )
    return "\n\n".join(paragraphs) + "\n"


def wants_auth_md(agents: Agents, base: str, *, gated: bool = False) -> bool:
    """Whether to write /auth.md: ``extra.agents.auth_md`` when set, and by default only for a
    site served at the root of its host (an address whose path is ``/``).

    ONLY AT A HOST'S ROOT, because /auth.md is a statement about the host. A site mounted at
    ``<host>/<repo>/`` does not speak for the host: its copy would sit at ``/<repo>/auth.md``,
    where no client looks, as a second description beside whatever the host serves at /auth.md.

    WRITTEN SO THAT IT CANNOT CONTRADICT A REAL ONE. A host that routes /auth.md to an MCP
    Worker never serves this file at that path, because a Workers route for /auth.md is more
    specific than the site's own ``<host>/*`` route (or a router's custom domain) and answers
    first. The copy only surfaces if that route goes, and it is true either way: it speaks for
    the static documentation alone, which needs no credential whatever else runs on the host,
    and it restates nothing about the MCP server's access. It points at that server's own RFC
    9728 metadata instead, and says that document, not this file, is the authority.

    NEVER BEHIND A GATE. A site the deploy refuses to publish unless Cloudflare Access covers it
    is one nobody reads without signing in, so "needs no credentials" would be false, and no
    setting makes it true.
    """
    if gated:
        return False
    if agents.auth_md is not None:
        return agents.auth_md
    return bool(base) and (urlsplit(base).path or "/") == "/"


# --------------------------------------------------------------------------- main


@dataclass
class Tally:
    skill: str = ""
    skill_kept: bool = False
    webmcp_pages: int = 0
    webmcp_kept: bool = False
    auth_md: str = ""


def _warn(message: str) -> None:
    print(f"::warning::gen-docs-agents: {message}", file=sys.stderr)


def write_skill(
    site_dir: Path, site: Site, agents: Agents, infos: list[PageInfo], tally: Tally
) -> None:
    """The skill and its index, unless the site publishes its own ``.well-known/agent-skills``."""
    root = site_dir / SKILLS_DIR
    if root.exists():
        tally.skill_kept = True
        return
    name = agents.skill_name or slug(site.name)
    if not is_skill_name(name):
        _warn(
            f"site_name {site.name!r} gives no Agent Skills name; set extra.agents.skill.name. "
            "No skill written."
        )
        return
    description = agents.skill_description or skill_description(
        site.name, site.description, site.base
    )
    if len(description) > SKILL_DESCRIPTION_CHARS:
        _warn(f"the skill's description is over {SKILL_DESCRIPTION_CHARS} characters; clipped")
        description = clip(description, SKILL_DESCRIPTION_CHARS)
    # Written as bytes, and the digest taken from the same bytes: a digest of a string that was
    # then encoded differently on the way to disk would be a digest of nothing served.
    body = render_skill(site, name, description, infos).encode("utf-8")
    (root / name).mkdir(parents=True)
    (root / name / "SKILL.md").write_bytes(body)
    index = render_index(name, description, skill_url(site.base, name), sha256_digest(body))
    (root / "index.json").write_text(index, encoding="utf-8")
    tally.skill = name


def write_webmcp(site_dir: Path, site_name: str, infos: list[PageInfo], tally: Tally) -> None:
    source = WEBMCP_SOURCE.read_bytes()
    target = site_dir / WEBMCP_ASSET
    if target.exists():
        if target.read_bytes() != source:
            # The site's own WebMCP, or someone's file at our address. Either way it is not ours
            # to point pages at.
            tally.webmcp_kept = True
            return
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source)
    version = hashlib.sha256(source).hexdigest()[:12]
    for info in infos:
        document = info.dest.read_text(encoding="utf-8")
        if has_webmcp_tag(document):
            continue
        tag = webmcp_tag(info.dest, site_dir, version, site_name)
        edited = apply_edit(document, Scan(), Edit(tags=[tag]))
        if edited != document:
            info.dest.write_text(edited, encoding="utf-8")
            tally.webmcp_pages += 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="gen_docs_agents.py",
        description="An Agent Skills index, WebMCP tools and an auth.md for a built MkDocs site.",
    )
    parser.add_argument("--root", type=Path, default=Path("."), help="repository root")
    parser.add_argument("--site-dir", default="site", help="built site directory")
    parser.add_argument(
        "--config-file",
        default="",
        help="MkDocs config, relative to --root (default: mkdocs.yml, then mkdocs.yaml)",
    )
    parser.add_argument(
        "--site-url",
        default="",
        help="the address the site is actually served at. Preferred over site_url for the "
        "files an agent fetches, as the corpus step prefers it for citations.",
    )
    parser.add_argument(
        "--access-required",
        default="",
        help="cloudflare-docs-require-access, as the workflow passed it. True means the site is "
        "behind Cloudflare Access, so no auth.md saying it needs no credentials is written.",
    )
    args = parser.parse_args(argv)

    root: Path = args.root.resolve()
    site_dir = (root / args.site_dir).resolve()
    names = [args.config_file] if args.config_file else ["mkdocs.yml", "mkdocs.yaml"]
    config_file = next((root / n for n in names if (root / n).is_file()), root / names[0])
    if not site_dir.is_dir():
        print(f"::error::gen-docs-agents: no built site at {site_dir}", file=sys.stderr)
        return 1
    if not config_file.is_file():
        print(f"::error::gen-docs-agents: no {config_file.name} in {root}", file=sys.stderr)
        return 1
    try:
        from mkdocs.exceptions import MkDocsException
    except ImportError:
        print(
            "::error::gen-docs-agents: MkDocs is not importable here. This step runs inside the "
            "docs toolchain that built the site.",
            file=sys.stderr,
        )
        return 1

    served = args.site_url.strip()
    if served and not served.endswith("/"):
        served += "/"
    try:
        config, infos, _ = load_site(config_file, site_dir, served)
    except (MkDocsException, OSError, ValueError) as exc:
        print(f"::error::gen-docs-agents: cannot load {config_file.name}: {exc}", file=sys.stderr)
        return 1
    if not infos:
        print(
            f"::error::gen-docs-agents: {site_dir} has no page for any markdown file in the docs "
            "directory. Is --site-dir the directory `mkdocs build` wrote?",
            file=sys.stderr,
        )
        return 1

    configured = (config.get("site_url") or "").strip()
    if configured and not configured.endswith("/"):
        configured += "/"
    base = served or configured

    agents = agents_from(config)
    for message in agents.warnings:
        _warn(message)
    site_name = str(config.get("site_name") or "").strip() or root.name
    non_home = [info for info in infos if not info.home]
    site = Site(
        name=site_name,
        description=" ".join(str(config.get("site_description") or "").split()),
        base=base,
        llms_txt=(site_dir / "llms.txt").is_file(),
        llms_full_txt=(site_dir / "llms-full.txt").is_file(),
        twins=any(info.twin.is_file() for info in infos),
        flat=any(info.url.endswith(".html") for info in non_home),
        example=next((info for info in non_home if info.twin.is_file()), None),
        mcp=agents.mcp,
        webmcp=agents.webmcp,
    )

    tally = Tally()
    if agents.skill:
        write_skill(site_dir, site, agents, infos, tally)
    if agents.webmcp:
        write_webmcp(site_dir, site_name, infos, tally)
    gated = args.access_required.strip().lower() in ("true", "1", "yes", "on")
    if wants_auth_md(agents, base, gated=gated):
        target = site_dir / "auth.md"
        if target.exists():
            tally.auth_md = "kept the site's own"
        else:
            skills_index = (site_dir / SKILLS_DIR / "index.json").is_file()
            target.write_text(render_auth_md(site, skills_index), encoding="utf-8")
            tally.auth_md = "written"

    parts = []
    if tally.skill:
        parts.append(f"skill {tally.skill} at /{SKILLS_DIR}/{tally.skill}/SKILL.md")
    elif tally.skill_kept:
        parts.append(f"kept the site's own /{SKILLS_DIR}/")
    if tally.webmcp_kept:
        parts.append(f"kept the site's own {WEBMCP_ASSET}")
    elif agents.webmcp:
        parts.append(f"WebMCP script added to {tally.webmcp_pages} pages")
    if tally.auth_md:
        parts.append(f"auth.md {tally.auth_md}")
    print(f"gen-docs-agents: {len(infos)} pages; {'; '.join(parts) or 'nothing to add'}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
