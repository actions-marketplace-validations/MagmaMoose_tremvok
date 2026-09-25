"""Give every page of a built MkDocs site its own search, social and agent metadata.

Runs after ``mkdocs build`` on the HTML the build just wrote, for both docs targets
(``github-pages`` and ``cloudflare-docs``), and edits each page in place:

``<meta name="description">``
    Material prints ``site_description`` into every page that has no ``description:`` in
    its front matter, so a site of forty pages advertises one sentence forty times. Search
    engines read that as duplicate metadata and write their own snippet from whatever they
    find first, which on a docs page is usually navigation. The page's first real paragraph
    is a better description than either, and it is already written. The home page keeps
    ``site_description``: that sentence was written for it.

Open Graph and Twitter tags
    Material emits neither without its social plugin, which needs Cairo and Pillow on the
    runner to draw a card per page. Without them a link pasted into Slack, LinkedIn or an
    issue unfurls as a bare URL. The card image is configured once instead.

JSON-LD
    One ``@graph`` per page: the ``WebSite`` and its publisher on every page, and on every
    page but the home page a ``TechArticle`` and a ``BreadcrumbList`` built from the nav.
    The publisher carries the ``@id`` its own website already publishes, so a crawler
    attaches these pages to the entity it knows rather than inventing a second one.

A markdown twin
    Each page's source markdown, written beside its HTML as ``index.md`` (``<page>.md``
    under ``use_directory_urls: false``) and announced with ``<link rel="alternate"
    type="text/markdown">``. That is the llmstxt.org convention for "the same page, for an
    agent", and ``gen_docs_index.py`` points llms.txt at these files when they exist.
    Relative links are resolved the way MkDocs resolves them for the HTML: the twin sits one
    directory deeper than its source, so every ``setup.md`` link in it would otherwise 404.

WHY THIS IS NOT A MKDOCS PLUGIN, OR A HOOK. For the reason ``gen_docs_index.py`` is not: a
plugin has to be named in ``plugins:`` and a hook in ``hooks:``, and a repo that declares
either list in its own mkdocs.yml silently discards every entry the shared
``mkdocs.base.yml`` provides, because MkDocs REPLACES lists under INHERIT. A step after the
build needs no key in any repo, so it cannot be what forces a repo into that trap.

EVERY PART IS SKIPPED WHERE THE PAGE ALREADY HAS IT. docs.calebsargeant.com writes its own
Open Graph tags, JSON-LD and descriptions from a MkDocs hook, and any repo can set
``description:`` on a page. So a description that is not the site-wide default is left
alone, and so are the Open Graph tags when ``og:title`` is present, the Twitter tags when
``twitter:card`` is, the JSON-LD when any ``application/ld+json`` block is, and the twin
link when one exists. The same rules make a second run change nothing, which is what
idempotent has to mean for a step that edits files in place.

CONFIGURATION IS ``extra.seo``, READ FROM THE RESOLVED CONFIG. ``extra`` is a dict and
dicts merge through INHERIT, so the MagmaMoose fleet sets its publisher and card image once,
in ``MagmaMoose/admin`` -> ``files/docs/mkdocs.base.yml``, and a repo can still override a
single key. The config is loaded with MkDocs' own ``load_config``, INHERIT applied, because
reading mkdocs.yml as plain YAML would see none of the base. Nothing in this file names a
MagmaMoose URL: Tremvok is a public Marketplace action, and a default that put
magmamoose.com into a stranger's structured data would be a bug.

THE PAGE LIST AND THE NAV COME FROM MKDOCS, THE TEXT FROM THE HTML. ``get_files`` and
``get_navigation`` give the pages, titles and sections the build used, without running a
single plugin event: a plugin whose ``on_config`` never ran must not be handed a page. The
description is read from the rendered article rather than the markdown, because the HTML is
what a reader sees first. Admonitions, tables, code and details are elements there, not
syntax to be guessed at, and whatever a markdown extension expanded is already expanded.

Python on the runner is deliberate and bounded: this runs inside the docs toolchain that
``mkdocs build`` has just used, like ``lint_docs.py`` and ``gen_docs_index.py``, so it costs
no ``setup-python`` step, and no deploy adapter depends on it.
"""

from __future__ import annotations

import argparse
import html
import json
import logging
import posixpath
import re
import sys
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urljoin, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_docs_index import markdown_twin

#: Where Google and Bing cut a description off in a result. A longer one is not an error,
#: just a sentence that ends in an ellipsis nobody chose.
DESCRIPTION_CHARS = 155

#: An opening paragraph shorter than this has the paragraph straight after it added. A
#: description of forty characters wastes most of the result it is shown in.
SHORT_DESCRIPTION_CHARS = 100

#: A description is cut at the end of a sentence rather than mid-way only when that keeps
#: at least this much of it. Otherwise one short opening sentence would win every time.
SENTENCE_FLOOR = 70

#: The longest home-page title this derives. Past about sixty characters a result title is
#: truncated, and a derived one that gets truncated is worse than the bare site name.
TITLE_CHARS = 65

#: Google's limit for an Article headline.
HEADLINE_CHARS = 110

ELLIPSIS = "\u2026"


# --------------------------------------------------------------------------- reading a page

#: Elements with no end tag. Pushing one onto the open-element stack would leave it open for
#: the rest of the document and put every later paragraph "inside" it.
VOID_ELEMENTS = frozenset(
    {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }
)

#: A paragraph inside any of these is not the page's own opening prose: a list item, a
#: table cell, a quotation, a collapsed block, the navigation. Judged on ancestors only, so
#: the inline `<code>` in "set `site_url` first" does not disqualify its paragraph.
NOT_PROSE_TAGS = frozenset(
    {
        "aside",
        "blockquote",
        "button",
        "code",
        "dd",
        "details",
        "dl",
        "dt",
        "figcaption",
        "figure",
        "footer",
        "form",
        "header",
        "label",
        "li",
        "nav",
        "noscript",
        "pre",
        "script",
        "select",
        "style",
        "summary",
        "svg",
        "table",
        "template",
        "textarea",
    }
)

#: The same, by class. `admonition` is Material's `!!! note` box, which is where a page
#: puts the warning it wants read first and never the thing it is about.
NOT_PROSE_CLASSES = frozenset(
    {
        "admonition",
        "footnote",
        "md-banner",
        "md-dialog",
        "md-footer",
        "md-header",
        "md-nav",
        "md-search",
        "md-sidebar",
        "md-source",
        "tabbed-set",
        "toc",
    }
)

#: Text inside these is dropped even within a paragraph or a heading: the pilcrow permalink
#: `toc` adds to every heading, a footnote marker's number, an icon's SVG.
SILENT_TAGS = frozenset({"noscript", "script", "style", "svg", "template"})
SILENT_CLASSES = frozenset({"arithmatex", "footnote-ref", "headerlink", "md-annotation"})


@dataclass
class HeadTag:
    """A start tag in `<head>`, as written, so it can be replaced byte for byte."""

    raw: str
    attrs: dict[str, str]


#: Block-level elements. Two paragraphs with one of these between them are not one thought:
#: "runs" and "and reads every report" are the two halves of a sentence around a code block,
#: and joined they describe a command that is not there.
BLOCK_TAGS = frozenset(
    {
        "address",
        "article",
        "aside",
        "blockquote",
        "details",
        "dialog",
        "div",
        "dl",
        "fieldset",
        "figure",
        "footer",
        "form",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "hr",
        "main",
        "nav",
        "ol",
        "pre",
        "section",
        "table",
        "ul",
    }
)


@dataclass
class Paragraph:
    text: str
    #: 2 inside `<article>`, 1 inside `<main>` or `role="main"`, 0 anywhere else.
    region: int
    #: Nothing but links. "See [Setup](setup.md) and [API](api.md)." describes nothing.
    link_only: bool
    #: Opens on a lower-case word written straight into the <p>, not in a code span. After a
    #: paragraph that stopped mid-sentence, that is the second half of the sentence a code
    #: block interrupted ("and reads every report it produced."). See `description_candidates`.
    starts_lower: bool = False
    #: Opens in bold: a run-in heading ("**Action surface.** The composite action..."), which
    #: starts a new entry rather than carrying on the paragraph before it.
    run_in: bool = False
    #: Block elements seen before it opened and by the time it closed. Equal numbers across
    #: two paragraphs mean nothing stood between them.
    blocks_before: int = 0
    blocks_after: int = 0


@dataclass
class Scan:
    """What one built page already carries, and the prose it opens with."""

    lang: str = ""
    title: str | None = None
    description: HeadTag | None = None
    canonical: str = ""
    og: set[str] = field(default_factory=set)
    twitter: set[str] = field(default_factory=set)
    jsonld: bool = False
    markdown_link: bool = False
    h1: str = ""
    has_article: bool = False
    has_main: bool = False
    paragraphs: list[Paragraph] = field(default_factory=list)

    def prose(self) -> list[Paragraph]:
        """Paragraphs from the content region only, never the navigation or the footer."""
        if self.has_article:
            region = 2
        elif self.has_main:
            region = 1
        else:
            region = 0
        return [p for p in self.paragraphs if p.region >= region and not p.link_only]


@dataclass
class _Open:
    tag: str
    not_prose: bool
    silent: bool
    link: bool
    article: bool
    main: bool


def _squash(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


class _Scanner(HTMLParser):
    """One pass over a page. Not a DOM: an open-element stack is all the questions need."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.scan = Scan()
        self._stack: list[_Open] = []
        self._in_head = False
        self._title: list[str] | None = None
        self._p: list[str] | None = None
        self._p_region = 0
        self._p_has_own_words = False
        self._p_started = False
        self._p_starts_lower = False
        self._p_run_in = False
        self._p_blocks = 0
        self._h1: list[str] | None = None
        self._blocks = 0

    # HTMLParser's own names, hence no snake-case quibbles.
    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {key: (value or "") for key, value in attrs}
        if tag == "html":
            self.scan.lang = a.get("lang", "").strip()
        elif tag == "head":
            self._in_head = True
        elif tag == "body":
            self._in_head = False
        if self._in_head:
            self._head_tag(tag, a)
        if tag == "script" and a.get("type", "").strip().lower() == "application/ld+json":
            self.scan.jsonld = True
        if tag == "br":
            # "line one<br>line two" has no whitespace in its data; without this the two
            # words become one in the description.
            if self._p is not None:
                self._p.append(" ")
            if self._h1 is not None:
                self._h1.append(" ")
        if tag in BLOCK_TAGS and not self._in_head:
            self._blocks += 1
        if tag in VOID_ELEMENTS:
            return

        classes = frozenset(a.get("class", "").split())
        element = _Open(
            tag=tag,
            not_prose=tag in NOT_PROSE_TAGS or bool(classes & NOT_PROSE_CLASSES),
            silent=tag in SILENT_TAGS or bool(classes & SILENT_CLASSES),
            link=tag == "a",
            article=tag == "article",
            main=tag == "main" or a.get("role", "") == "main",
        )
        self.scan.has_article |= element.article
        self.scan.has_main |= element.main

        if not self._in_head:
            if tag == "p":
                # An unclosed <p> ends where the next one begins.
                self._close_paragraph()
                if not any(e.not_prose for e in self._stack):
                    self._p = []
                    self._p_has_own_words = False
                    self._p_started = False
                    self._p_starts_lower = False
                    self._p_run_in = False
                    self._p_blocks = self._blocks
                    if any(e.article for e in self._stack):
                        self._p_region = 2
                    elif any(e.main for e in self._stack):
                        self._p_region = 1
                    else:
                        self._p_region = 0
            elif tag == "h1" and not self.scan.h1 and self._h1 is None:
                self._h1 = []
        elif tag == "title" and self.scan.title is None:
            self._title = []
        self._stack.append(element)

    def _head_tag(self, tag: str, a: dict[str, str]) -> None:
        if tag == "meta":
            name = a.get("name", "").strip().lower()
            prop = a.get("property", "").strip().lower()
            if name == "description" and self.scan.description is None:
                self.scan.description = HeadTag(self.get_starttag_text() or "", a)
            if prop.startswith("og:"):
                self.scan.og.add(prop)
            # X documents `name=`, and plenty of generators write `property=`. Either counts.
            for key in (name, prop):
                if key.startswith("twitter:"):
                    self.scan.twitter.add(key)
        elif tag == "link":
            rel = set(a.get("rel", "").lower().split())
            if "canonical" in rel and not self.scan.canonical:
                self.scan.canonical = a.get("href", "").strip()
            kind = a.get("type", "").split(";")[0].strip().lower()
            if "alternate" in rel and kind == "text/markdown":
                self.scan.markdown_link = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "head":
            self._in_head = False
        if tag in VOID_ELEMENTS:
            return
        for depth in range(len(self._stack) - 1, -1, -1):
            if self._stack[depth].tag == tag:
                break
        else:
            return  # a stray end tag closes nothing
        while len(self._stack) > depth:
            closed = self._stack.pop()
            if closed.tag == "p":
                self._close_paragraph()
            elif closed.tag == "h1" and self._h1 is not None:
                self.scan.h1 = _squash("".join(self._h1))
                self._h1 = None
            elif closed.tag == "title" and self._title is not None:
                self.scan.title = "".join(self._title)
                self._title = None

    def handle_data(self, data: str) -> None:
        if self._title is not None:
            self._title.append(data)
            return
        if any(e.silent for e in self._stack):
            return
        if self._p is not None:
            self._p.append(data)
            if not self._p_started and data.strip():
                # Only text written straight into the <p>: a paragraph that opens with
                # `target` in a code span is a sentence about `target`, not a fragment.
                self._p_started = True
                self._p_starts_lower = self._stack[-1].tag == "p" and data.lstrip()[0].islower()
                self._p_run_in = self._stack[-1].tag in ("strong", "b")
            if re.search(r"\w", data) and not any(e.link for e in self._stack):
                self._p_has_own_words = True
        if self._h1 is not None:
            self._h1.append(data)

    def _close_paragraph(self) -> None:
        if self._p is None:
            return
        text = _squash("".join(self._p))
        if text:
            self.scan.paragraphs.append(
                Paragraph(
                    text,
                    region=self._p_region,
                    link_only=not self._p_has_own_words,
                    starts_lower=self._p_starts_lower,
                    run_in=self._p_run_in,
                    blocks_before=self._p_blocks,
                    blocks_after=self._blocks,
                )
            )
        self._p = None

    def close(self) -> None:
        super().close()
        self._close_paragraph()


def scan_html(document: str) -> Scan:
    scanner = _Scanner()
    scanner.feed(document)
    scanner.close()
    return scanner.scan


# --------------------------------------------------------------------------- descriptions

#: A token that reads as a word: letters first, then word characters, apostrophes and
#: hyphens, with ordinary punctuation either side. `site_url` counts; `a/b.py` and `--x` do
#: not, which is what separates a sentence from a command line.
_WORDY = re.compile(
    r"[\"'(\[\u2018\u201c]*[^\W\d_][\w'\u2019-]*[\"')\].,;:!?\u2019\u201d]*",
)


def is_prose(text: str, *, lenient: bool = False) -> bool:
    """Enough real words to describe a page, rather than a label, a path or a command."""
    words = text.split()
    if not words:
        return False
    wordy = sum(1 for word in words if _WORDY.fullmatch(word)) / len(words)
    if lenient:
        return len(words) >= 3 and wordy >= 0.5
    return len(words) >= 6 and len(text) >= 40 and wordy >= 0.6


def clip(text: str, limit: int = DESCRIPTION_CHARS) -> str:
    """At most ``limit`` characters, in order of preference: ended at a sentence, at a
    semicolon (which closes a clause that stands alone, so it becomes a full stop), or at a
    word boundary with an ellipsis that is counted in the limit. The first two only when they
    keep at least ``SENTENCE_FLOOR`` characters."""
    text = text.strip()
    if len(text) <= limit:
        return text
    window = text[: limit + 1]
    ends = [
        match.end()
        for match in re.finditer(r"[.!?][\"')\u2019\u201d]?(?=\s+[A-Z0-9\"'(\u2018\u201c])", window)
        if SENTENCE_FLOOR <= match.end() <= limit
    ]
    if ends:
        return text[: ends[-1]]
    clauses = [m.start() for m in re.finditer(r";(?=\s)", window) if m.start() >= SENTENCE_FLOOR]
    if clauses:
        return text[: clauses[-1]].rstrip() + "."
    head = text[: limit - 1]
    # Only drop the last word when the cut actually landed inside it.
    if not text[limit - 1].isspace() and " " in head:
        head = head.rsplit(" ", 1)[0]
    return head.rstrip(" ,;:([{-\u2013\u2014") + ELLIPSIS


def _period(text: str) -> str:
    """A paragraph that introduces a list ends in a colon. As a description it is a sentence."""
    return text[:-1].rstrip() + "." if text.endswith(":") else text


def _ends_sentence(text: str) -> bool:
    return bool(re.search(r"[.!?\u2026][\"')\]\u2019\u201d]*$", text))


def is_complete(text: str) -> bool:
    """Ends like a sentence. "Brimyr detects a Maven repo from pom.xml, runs" stops where a
    code block takes over, and read on its own it is a sentence with its verb missing."""
    return bool(re.search(r"[.!?:\u2026][\"')\]\u2019\u201d]*$", text))


def description_candidates(paragraphs: list[Paragraph]) -> list[str]:
    """Descriptions this page could carry, best first.

    More than one, so that a page whose first paragraph another page already uses word for
    word can fall back to its second rather than straight to boilerplate. A short paragraph
    is joined to the next only when nothing stands between them in the page.
    """
    position = {id(p): index for index, p in enumerate(paragraphs)}
    # A lower-case opening only marks a fragment when the paragraph before it stopped short of
    # a sentence. On its own it is just a sentence about `v1` or `dotnet`.
    whole = [
        p
        for index, p in enumerate(paragraphs)
        if not (p.starts_lower and index > 0 and not _ends_sentence(paragraphs[index - 1].text))
    ]
    pool = [p for p in whole if is_prose(p.text) and is_complete(p.text)]
    if not pool:
        pool = [p for p in whole if is_prose(p.text, lenient=True)]
    candidates: list[str] = []
    for index, paragraph in enumerate(pool):
        text = paragraph.text
        following = pool[index + 1] if index + 1 < len(pool) else None
        if (
            len(text) < SHORT_DESCRIPTION_CHARS
            and is_complete(text)
            and not text.endswith(":")
            and following is not None
            and not following.run_in
            and position[id(following)] == position[id(paragraph)] + 1
            and following.blocks_before == paragraph.blocks_after
        ):
            text = f"{text} {_period(following.text)}"
        candidates.append(clip(_period(text)))
    return candidates


def fallback_description(site_name: str, trail: list[str], title: str) -> str:
    """For a page with no prose at all. Unique because the nav path to it is."""
    return clip(f"{site_name} documentation: {' / '.join([*trail, title])}.")


def home_title(site_name: str, site_description: str) -> str:
    """`Tremvok - One GitHub Action for the whole deploy side`, or nothing.

    Material titles the home page with the bare site name, which is a brand, not an answer
    to anything a person searches for. The lead clause of ``site_description`` is. Nothing
    is derived when that clause is too short to mean anything, repeats the site name, or
    would push the title past the length a result shows.
    """
    lead = re.split(
        r"[.:;!?](?=\s|$)|\s\(|\s[-\u2013\u2014]\s", site_description.strip(), maxsplit=1
    )[0]
    lead = lead.strip().rstrip(",")
    if len(lead.split()) < 3 or lead.casefold().startswith(site_name.casefold()):
        return ""
    title = f"{site_name} - {lead}"
    return title if len(title) <= TITLE_CHARS else ""


def _key(text: str) -> str:
    return " ".join(text.casefold().split())


# --------------------------------------------------------------------------- configuration


@dataclass
class Settings:
    """``extra.seo`` and the handful of MkDocs keys it is read beside, resolved once."""

    site_name: str
    site_description: str
    base: str
    locale: str = ""
    language: str = ""
    image: dict[str, Any] | None = None
    publisher: dict[str, Any] | None = None
    author: dict[str, Any] | None = None
    twitter_site: str = ""
    warnings: list[str] = field(default_factory=list)


def _absolute(value: Any, base: str) -> str:
    """An absolute URL, or ``""``. A relative one is resolved against the site."""
    text = str(value or "").strip()
    if not text:
        return ""
    if urlsplit(text).scheme:
        return text
    return urljoin(base, text) if base else ""


def _locale_parts(value: str) -> tuple[str, str]:
    match = re.fullmatch(r"([A-Za-z]{2,3})(?:[-_]([A-Za-z]{2}|\d{3}))?", value.strip())
    if not match:
        return "", ""
    return match.group(1).lower(), (match.group(2) or "").upper()


def og_locale(value: str) -> str:
    """``en-GB`` -> ``en_GB``. A bare ``en`` gives nothing: OGP's own default is ``en_US``,
    and guessing a territory for someone else's site is worse than saying nothing."""
    language, region = _locale_parts(value)
    return f"{language}_{region}" if language and region else ""


def bcp47(value: str) -> str:
    """``en_GB`` -> ``en-GB``, the form schema.org's ``inLanguage`` takes."""
    language, region = _locale_parts(value)
    if not language:
        return ""
    return f"{language}-{region}" if region else language


def _entity(raw: Any, default_type: str, base: str, key: str, warnings: list[str]) -> Any:
    """A publisher or author as a schema.org node, or ``None`` when there is no name."""
    if raw in (None, "", {}):
        return None
    if isinstance(raw, str):
        raw = {"name": raw}
    if not isinstance(raw, Mapping) or not str(raw.get("name") or "").strip():
        warnings.append(f"extra.seo.{key} needs at least a `name`; ignored")
        return None
    kind = str(raw.get("type") or default_type).strip()
    node: dict[str, Any] = {"@type": kind}
    url = _absolute(raw.get("url"), base)
    identifier = str(raw.get("id") or "").strip()
    if not identifier and url:
        # The convention the publisher's own site most likely uses, and the one that makes a
        # crawler merge this node with that one rather than keep two.
        identifier = f"{url}#{'organization' if kind == 'Organization' else kind.lower()}"
    if identifier:
        node["@id"] = identifier
    node["name"] = str(raw["name"]).strip()
    if url:
        node["url"] = url
    logo = _absolute(raw.get("logo"), base)
    if logo:
        # `logo` is an Organization property; a Person has an `image`.
        node["image" if kind == "Person" else "logo"] = {"@type": "ImageObject", "url": logo}
    same_as = raw.get("same_as", raw.get("sameAs"))
    if isinstance(same_as, str):
        same_as = [same_as]
    if isinstance(same_as, list):
        links = [str(link).strip() for link in same_as if str(link).strip()]
        if links:
            node["sameAs"] = links
    return node


def settings_from(config: Any, base: str) -> Settings:
    """Read ``extra.seo`` from the resolved MkDocs config. Every key is optional.

    ``locale`` (``en_GB``), ``image`` (a URL, or ``{url, width, height, alt}``),
    ``publisher`` and ``author`` (``{type, name, url, logo, id, same_as}``), ``twitter``
    (``@handle``). The author defaults to the publisher, then to ``site_author``.
    """
    site_name = str(config.get("site_name") or "").strip()
    settings = Settings(
        site_name=site_name,
        site_description=_squash(str(config.get("site_description") or "")),
        base=base,
    )
    # Mapping, never dict: MkDocs hands `extra` back as its own LegacyConfig, which is a
    # Mapping and not a dict, so an isinstance(dict) check reads every site as unconfigured.
    extra = config.get("extra") or {}
    seo = extra.get("seo") if isinstance(extra, Mapping) else None
    if seo is None:
        seo = {}
    if not isinstance(seo, Mapping):
        settings.warnings.append("extra.seo is not a mapping; using the defaults")
        seo = {}

    theme_language = ""
    theme = config.get("theme")
    try:
        theme_language = str(theme.get("language") or "") if theme is not None else ""
    except AttributeError:  # a theme object without a mapping interface
        theme_language = ""
    locale = str(seo.get("locale") or "").strip()
    settings.locale = og_locale(locale or theme_language)
    settings.language = bcp47(locale or theme_language)

    image = seo.get("image")
    if isinstance(image, str):
        image = {"url": image}
    if isinstance(image, Mapping):
        url = _absolute(image.get("url"), base)
        if url:
            settings.image = {
                "url": url,
                "width": str(image.get("width") or "").strip(),
                "height": str(image.get("height") or "").strip(),
                # The card almost always shows the product's name; so does this.
                "alt": str(image.get("alt") or site_name).strip(),
            }
        elif image.get("url"):
            settings.warnings.append(
                "extra.seo.image.url is relative and there is no site_url to resolve it "
                "against; og:image is left out"
            )

    settings.publisher = _entity(
        seo.get("publisher"), "Organization", base, "publisher", settings.warnings
    )
    settings.author = _entity(seo.get("author"), "Person", base, "author", settings.warnings)
    if settings.author is None:
        site_author = str(config.get("site_author") or "").strip()
        if settings.publisher is not None:
            settings.author = settings.publisher
        elif site_author:
            settings.author = {"@type": "Person", "name": site_author}

    handle = str(seo.get("twitter") or "").strip()
    if handle and not handle.startswith("@"):
        handle = f"@{handle}"
    settings.twitter_site = handle
    return settings


# --------------------------------------------------------------------------- what gets added


def _attribute(value: str) -> str:
    """Plain text escaped exactly once for a double-quoted attribute. `'` is left as it is:
    it cannot end the attribute, and `&#x27;` in every description helps nobody reading it."""
    return html.escape(value, quote=False).replace('"', "&quot;")


def _meta(attribute: str, key: str, value: str) -> str:
    return f'<meta {attribute}="{key}" content="{_attribute(value)}">'


def open_graph_tags(
    settings: Settings, *, home: bool, title: str, description: str, url: str
) -> list[str]:
    tags = [
        _meta("property", "og:type", "website" if home else "article"),
        _meta("property", "og:site_name", settings.site_name),
    ]
    if settings.locale:
        tags.append(_meta("property", "og:locale", settings.locale))
    tags += [
        _meta("property", "og:title", title),
        _meta("property", "og:description", description),
    ]
    if url:
        tags.append(_meta("property", "og:url", url))
    image = settings.image
    if image:
        tags.append(_meta("property", "og:image", image["url"]))
        for key in ("width", "height"):
            if image[key]:
                tags.append(_meta("property", f"og:image:{key}", image[key]))
        if image["alt"]:
            tags.append(_meta("property", "og:image:alt", image["alt"]))
    return tags


def twitter_tags(settings: Settings, *, title: str, description: str) -> list[str]:
    # A large card needs an image to be large with; without one, `summary` is the honest card.
    tags = [_meta("name", "twitter:card", "summary_large_image" if settings.image else "summary")]
    if settings.twitter_site:
        tags.append(_meta("name", "twitter:site", settings.twitter_site))
    tags += [
        _meta("name", "twitter:title", title),
        _meta("name", "twitter:description", description),
    ]
    if settings.image:
        tags.append(_meta("name", "twitter:image", settings.image["url"]))
        if settings.image["alt"]:
            tags.append(_meta("name", "twitter:image:alt", settings.image["alt"]))
    return tags


def _reference(node: dict[str, Any]) -> dict[str, Any]:
    """Point at a node by ``@id`` when it has one; otherwise it has to be written inline."""
    return {"@id": node["@id"]} if "@id" in node else node


def jsonld_graph(
    settings: Settings,
    *,
    home: bool,
    url: str,
    headline: str,
    description: str,
    trail: list[tuple[str, str]],
    section: str,
) -> dict[str, Any]:
    """The page's graph. ``trail`` is the breadcrumb, home first and this page last."""
    base = settings.base
    website: dict[str, Any] = {
        "@type": "WebSite",
        "@id": f"{base}#website",
        "url": base,
        "name": settings.site_name,
    }
    if settings.site_description:
        website["description"] = settings.site_description
    if settings.language:
        website["inLanguage"] = settings.language
    graph: list[dict[str, Any]] = [website]
    publisher, author = settings.publisher, settings.author
    if publisher is not None:
        website["publisher"] = _reference(publisher)
        if "@id" in publisher:
            graph.append(publisher)
    if author is not None and author is not publisher and "@id" in author:
        graph.append(author)
    if not home:
        article: dict[str, Any] = {
            "@type": "TechArticle",
            "@id": f"{url}#article",
            "headline": clip(headline, HEADLINE_CHARS),
            "description": description,
            "url": url,
            "mainEntityOfPage": url,
            "isPartOf": {"@id": website["@id"]},
        }
        if settings.language:
            article["inLanguage"] = settings.language
        if settings.image:
            article["image"] = settings.image["url"]
        if section:
            article["articleSection"] = section
        if author is not None:
            article["author"] = _reference(author)
        if publisher is not None:
            article["publisher"] = _reference(publisher)
        graph.append(article)
        graph.append(
            {
                "@type": "BreadcrumbList",
                "@id": f"{url}#breadcrumb",
                "itemListElement": [
                    {"@type": "ListItem", "position": position, "name": name, "item": item}
                    for position, (name, item) in enumerate(trail, start=1)
                ],
            }
        )
    return {"@context": "https://schema.org", "@graph": graph}


def jsonld_script(graph: dict[str, Any]) -> str:
    # `<` escaped so that no title or description can close the script element early.
    body = json.dumps(graph, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    return f'<script type="application/ld+json">{body}</script>'


@dataclass
class Edit:
    """Everything one page is about to gain. Empty means the page is left byte-identical."""

    description: str | None = None
    title: str | None = None
    tags: list[str] = field(default_factory=list)

    def __bool__(self) -> bool:
        return self.description is not None or self.title is not None or bool(self.tags)


def apply_edit(document: str, scan: Scan, edit: Edit) -> str:
    """Write ``edit`` into ``document``'s head. Nothing outside the head is touched."""
    end = document.lower().find("</head>")
    if end < 0 or not edit:
        return document
    head, rest = document[:end], document[end:]
    added = list(edit.tags)
    if edit.description is not None:
        tag = _meta("name", "description", edit.description)
        if scan.description is not None and scan.description.raw in head:
            head = head.replace(scan.description.raw, tag, 1)
        else:
            added.insert(0, tag)
    if edit.title is not None:
        new_title = f"<title>{html.escape(edit.title, quote=False)}</title>"
        head = re.sub(r"<title>.*?</title>", lambda _: new_title, head, count=1, flags=re.S | re.I)
    if added:
        # Material leaves a run of blank, indented lines before `</head>`. They are replaced
        # by one new tag per line at the head's own indent, and `</head>` goes back on a line
        # of its own at the two spaces Material gives it. Nothing is appended when nothing was
        # added: a description replaced in place or a new title needs no new line.
        # "  " restores Material's two-space indent before </head> that rstrip removed.
        head = head.rstrip() + "\n" + "".join(f"    {tag}\n" for tag in added) + "  "
    return head + rest


# --------------------------------------------------------------------------- markdown twins

_FENCE_OPEN = re.compile(r"^[ \t]*(`{3,}|~{3,})")
_CODE_SPAN = re.compile(r"(`+)(?!`).+?(?<!`)\1(?!`)", re.S)
_INLINE_LINK = re.compile(
    r"(?P<label>!?\[(?:\\.|[^\[\]\\]|\[(?:\\.|[^\[\]\\])*\])*\])"
    r"\((?P<space>[ \t]*)"
    r"(?P<dest><[^<>\n]*>|[^\s()<>]+(?:\([^\s()<>]*\)[^\s()<>]*)*)"
    r"(?P<rest>(?:[ \t]+(?:\"[^\"\n]*\"|'[^'\n]*'|\([^()\n]*\)))?[ \t]*\))"
)
# `[id]: target`, but not `[^1]: text`: a footnote's first word is prose, not a destination.
_REFERENCE = re.compile(
    r"^(?P<lead> {0,3}\[(?!\^)(?:\\.|[^\[\]\\])+\]:[ \t]*)(?P<dest><[^<>\n]*>|\S+)", re.M
)


def _split_fences(markdown: str) -> list[tuple[bool, str]]:
    """``(is_code, text)`` runs. A link inside a fence is an example, not a link."""
    runs: list[tuple[bool, str]] = []
    buffer: list[str] = []
    fence = ""
    for line in markdown.splitlines(keepends=True):
        opening = _FENCE_OPEN.match(line)
        if not fence and opening:
            if buffer:
                runs.append((False, "".join(buffer)))
            buffer, fence = [line], opening.group(1)
        elif fence and re.fullmatch(
            rf"[ \t]*{re.escape(fence[0])}{{{len(fence)},}}[ \t]*\n?", line
        ):
            buffer.append(line)
            runs.append((True, "".join(buffer)))
            buffer, fence = [], ""
        else:
            buffer.append(line)
    if buffer:
        runs.append((bool(fence), "".join(buffer)))
    return runs


def rewrite_links(markdown: str, resolve: Callable[[str], str]) -> str:
    """Pass every inline and reference link destination outside code through ``resolve``."""

    def one(match: re.Match[str]) -> str:
        # A link's label can hold an image, `[![badge](b.svg)](page.md)`, whose own
        # destination needs the same treatment.
        label = match.group("label")
        opening = "![" if label.startswith("!") else "["
        inner = _INLINE_LINK.sub(one, label[len(opening) : -1])
        destination = resolve(match.group("dest"))
        return f"{opening}{inner}]({match.group('space')}{destination}{match.group('rest')}"

    out: list[str] = []
    for is_code, text in _split_fences(markdown):
        if is_code:
            out.append(text)
            continue
        spans: list[str] = []

        # `spans` is bound as a default on purpose, not redundant: this function is
        # defined inside the loop, and without the binding ruff's B023 fails CI because
        # a late-binding closure would see whichever list the loop created last.
        def keep(match: re.Match[str], spans: list[str] = spans) -> str:
            spans.append(match.group(0))
            return f"\x00{len(spans) - 1}\x00"

        text = _CODE_SPAN.sub(keep, text)
        text = _INLINE_LINK.sub(one, text)
        text = _REFERENCE.sub(lambda m: m.group("lead") + resolve(m.group("dest")), text)
        out.append(re.sub(r"\x00(\d+)\x00", lambda m, spans=spans: spans[int(m.group(1))], text))
    return "".join(out)


def link_resolver(
    src_uri: str,
    page_url: str,
    lookup: Callable[[str], str | None],
    locate: Callable[[str], str],
) -> Callable[[str], str]:
    """Resolve a destination written in ``src_uri`` the way MkDocs does for the HTML.

    ``lookup`` maps a docs-relative path to the site URL of the file MkDocs built from it
    (or ``None``); ``locate`` turns a site URL into the form the twin should carry, absolute
    when the site has a base URL. Anything MkDocs itself would leave alone (a scheme, a
    root-relative path, a file that is not in the build) is left alone here too.
    """

    def resolve(destination: str) -> str:
        angled = destination.startswith("<") and destination.endswith(">")
        target = destination[1:-1] if angled else destination
        parts = urlsplit(target)
        if parts.scheme or parts.netloc or target.startswith("/"):
            return destination
        if not parts.path:
            if not parts.fragment:
                return destination
            resolved = locate(page_url) + "#" + parts.fragment
        else:
            path = posixpath.normpath(
                posixpath.join(posixpath.dirname(src_uri), unquote(parts.path))
            )
            if path == ".." or path.startswith("../"):
                return destination
            url = lookup(path)
            if url is None:
                return destination
            resolved = locate(url)
            if parts.query:
                resolved += "?" + parts.query
            if parts.fragment:
                resolved += "#" + parts.fragment
        return f"<{resolved}>" if angled else resolved

    return resolve


def _h1_end(lines: list[str]) -> int | None:
    """The index of the line an H1 ends on, outside code, or ``None`` when there is none.

    Python-Markdown takes `#Title` as a heading as readily as `# Title`, and a setext `===`
    underline or a raw <h1> make an H1 too. Missing one means printing a second title.
    """
    fence = ""
    for index, line in enumerate(lines):
        opening = _FENCE_OPEN.match(line)
        if fence:
            if re.fullmatch(rf"[ \t]*{re.escape(fence[0])}{{{len(fence)},}}[ \t]*", line):
                fence = ""
            continue
        if opening:
            fence = opening.group(1)
            continue
        if re.match(r"#(?!#)[ \t]*\S", line) or re.match(r"<h1\b", line, re.I):
            return index
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if line.strip() and re.fullmatch(r"=+[ \t]*", following):
            return index + 1
    return None


def twin_markdown(
    markdown: str, title: str, resolve: Callable[[str], str], source_url: str = ""
) -> str:
    """The page's markdown for an agent.

    Links that work from where the twin lives; a title when the page takes its H1 from the
    nav rather than writing one; and under the H1 the page the markdown belongs to, in the
    line docs.calebsargeant.com's own twins carry, so an agent that was handed the file alone
    still knows which address to cite.
    """
    lines = rewrite_links(markdown, resolve).strip("\n").split("\n")
    end = _h1_end(lines)
    if end is None:
        lines = [f"# {title}", "", *lines]
        end = 0
    if source_url:
        rest = lines[end + 1 :]
        while rest and not rest[0].strip():
            rest.pop(0)
        lines = [*lines[: end + 1], "", f"> Markdown source of {source_url}.", "", *rest]
    return "\n".join(lines).rstrip("\n") + "\n"


# --------------------------------------------------------------------------- the site


@dataclass
class PageInfo:
    """What MkDocs knows about one page, gathered before any file is touched."""

    src_uri: str
    url: str
    dest: Path
    twin: Path
    twin_url: str
    title: str
    home: bool
    markdown: str
    front_matter_description: bool
    trail: list[str]
    crumbs: list[tuple[str, str]]
    #: In the nav. A page the build rendered and the nav leaves out has no place in it, and a
    #: map of the site built from the nav (gen_docs_agents.py) must not list it at the top.
    in_nav: bool = True


def load_site(
    config_file: Path, site_dir: Path, fallback_base: str
) -> tuple[Any, list[PageInfo], Any]:
    """The resolved config and every built page, in nav order, with its nav context.

    Imported here rather than at the top so that the pure functions above stay testable
    without MkDocs, and so that a missing toolchain fails with a sentence, not a traceback.
    """
    from mkdocs.config import load_config
    from mkdocs.structure.files import get_files
    from mkdocs.structure.nav import get_navigation
    from mkdocs.utils import get_relative_url, meta

    # The build has already printed every warning these calls would repeat.
    mkdocs_log = logging.getLogger("mkdocs")
    level = mkdocs_log.level
    mkdocs_log.setLevel(logging.ERROR)
    try:
        config = load_config(config_file=str(config_file), site_dir=str(site_dir))
        files = get_files(config)
        nav = get_navigation(files, config)
    finally:
        mkdocs_log.setLevel(level)

    base = (config.get("site_url") or "").strip() or fallback_base
    if base and not base.endswith("/"):
        base += "/"

    in_nav = list(nav.pages)
    seen = {id(page) for page in in_nav}
    rest = sorted(
        (
            f.page
            for f in files.documentation_pages()
            if f.page is not None and id(f.page) not in seen
        ),
        key=lambda page: page.file.src_uri,
    )
    pages = in_nav + rest
    by_url = {page.url: page for page in pages}

    for page in pages:
        # Not `page.read_source()`: that fires `on_page_read_source`, and a plugin whose
        # `on_config` never ran must not be handed a page.
        page.markdown, page.meta = meta.get_data(page.file.content_string)

    def absolute(url: str) -> str:
        return urljoin(base, url) if base else ""

    def index_of(section: Any) -> Any:
        for child in section.children or []:
            if getattr(child, "is_page", False) and child.is_index:
                return child
        return None

    homes = [page for page in pages if page.is_homepage] or [p for p in pages if p.url == ""]
    home = homes[0] if homes else None

    infos: list[PageInfo] = []
    for page in pages:
        dest = Path(page.file.abs_dest_path)
        if not dest.is_file():
            continue  # excluded or a draft: the build wrote no page, so neither does this
        title = str(page.title or "").strip() or page.file.name
        ancestors = [a for a in reversed(page.ancestors) if getattr(a, "title", None)]
        trail = [str(a.title) for a in ancestors]
        crumbs: list[tuple[str, str]] = []
        if base:
            crumbs.append((str(config.get("site_name") or ""), base))
            steps: list[tuple[str, Any]] = []
            for section in ancestors:
                index = index_of(section)
                if index is not None and index is not page:
                    steps.append((str(section.title), index))
            if not ancestors:
                # No nav structure above the page: the directories in its URL, where the
                # build rendered a page for them, are the next best thing.
                parts = [p for p in page.url.split("/")[:-1] if p]
                for depth in range(1, len(parts) + 1):
                    prefix = "/".join(parts[:depth]) + "/"
                    parent = by_url.get(prefix) or by_url.get(prefix + "index.html")
                    if parent is not None and parent is not page and parent is not home:
                        steps.append((str(parent.title or prefix.rstrip("/")), parent))
            crumbs += [(name, absolute(target.url)) for name, target in steps]
            if page is not home:
                crumbs.append((title, absolute(page.url)))
        twin_rel = markdown_twin(page.file.dest_uri)
        twin_url = absolute(markdown_twin(page.url)) if base else posixpath.basename(twin_rel)
        info = PageInfo(
            src_uri=page.file.src_uri,
            url=page.url,
            dest=dest,
            twin=Path(config["site_dir"]) / twin_rel,
            twin_url=twin_url,
            title=title,
            home=page is home,
            markdown=page.markdown or "",
            front_matter_description=bool(str(page.meta.get("description") or "").strip()),
            trail=trail,
            crumbs=crumbs,
            in_nav=id(page) in seen,
        )
        infos.append(info)

    def lookup(path: str) -> str | None:
        target = files.get_file_from_path(path)
        if target is None or target.inclusion.is_excluded():
            return None
        return target.url

    def resolver_for(info: PageInfo) -> Callable[[str], str]:
        def locate(url: str) -> str:
            if base:
                return urljoin(base, url)
            return get_relative_url(url, markdown_twin(info.url))

        return link_resolver(info.src_uri, info.url, lookup, locate)

    return config, infos, resolver_for


# --------------------------------------------------------------------------- main


@dataclass
class Tally:
    pages: int = 0
    descriptions: int = 0
    fallbacks: list[str] = field(default_factory=list)
    open_graph: int = 0
    twitter: int = 0
    jsonld: int = 0
    canonicals: int = 0
    twins: int = 0
    titles: int = 0


def _warn(message: str) -> None:
    print(f"::warning::gen-docs-seo: {message}", file=sys.stderr)


def enrich(
    infos: list[PageInfo],
    settings: Settings,
    resolver_for: Callable[[PageInfo], Callable[[str], str]],
) -> Tally:
    tally = Tally()
    documents: dict[Path, str] = {}
    scans: dict[Path, Scan] = {}
    for info in infos:
        documents[info.dest] = info.dest.read_text(encoding="utf-8")
        scans[info.dest] = scan_html(documents[info.dest])

    default = _key(settings.site_description) if settings.site_description else None

    def current(info: PageInfo) -> str:
        tag = scans[info.dest].description
        return _squash(html.unescape(tag.attrs.get("content", ""))) if tag else ""

    def needs_description(info: PageInfo) -> bool:
        if info.front_matter_description:
            return False  # the author chose it, even if it repeats the site's
        text = current(info)
        if not text:
            return True
        if info.home:
            return False  # the home page keeps site_description
        return default is not None and _key(text) == default

    # Every description already on the site is taken, the home page's included, before a
    # single one is derived. A page cannot then be given a sentence another page carries.
    taken = {_key(current(info)) for info in infos if not needs_description(info)}
    taken.discard("")

    for info in infos:
        scan = scans[info.dest]
        edit = Edit()
        tally.pages += 1

        description = current(info)
        if needs_description(info):
            description = ""
            for candidate in description_candidates(scan.prose()):
                if _key(candidate) not in taken:
                    description = candidate
                    break
            if not description:
                description = fallback_description(settings.site_name, info.trail, info.title)
                if _key(description) in taken:
                    description = clip(f"{description[:-1]} ({info.url or '/'}).")
                tally.fallbacks.append(info.src_uri)
            taken.add(_key(description))
            edit.description = description
            tally.descriptions += 1

        title = info.title
        if info.home:
            shown = _squash(html.unescape(scan.title or ""))
            title = shown or settings.site_name
            if shown == settings.site_name:
                better = home_title(settings.site_name, settings.site_description)
                if better:
                    edit.title = title = better
                    tally.titles += 1
        headline = scan.h1 if (scan.h1 and not info.home) else title

        canonical = scan.canonical
        if not canonical and settings.base:
            canonical = urljoin(settings.base, info.url)
            edit.tags.append(f'<link rel="canonical" href="{_attribute(canonical)}">')
            tally.canonicals += 1

        if "og:title" not in scan.og:
            edit.tags += open_graph_tags(
                settings, home=info.home, title=headline, description=description, url=canonical
            )
            tally.open_graph += 1
        if "twitter:card" not in scan.twitter:
            edit.tags += twitter_tags(settings, title=headline, description=description)
            tally.twitter += 1
        if not scan.jsonld and canonical and settings.base:
            graph = jsonld_graph(
                settings,
                home=info.home,
                url=canonical,
                headline=headline,
                description=description,
                trail=info.crumbs,
                section=info.trail[-1] if info.trail else "",
            )
            edit.tags.append(jsonld_script(graph))
            tally.jsonld += 1

        # A twin or a twin link that is already there belongs to whoever put it there (on
        # docs.calebsargeant.com, its own MkDocs hook), and so does the other half of the
        # pair: neither is overwritten or doubled. That includes this step's own output on a
        # second run, which is what makes it a no-op.
        if not scan.markdown_link and not info.twin.exists():
            twin = twin_markdown(info.markdown, info.title, resolver_for(info), canonical)
            info.twin.parent.mkdir(parents=True, exist_ok=True)
            info.twin.write_text(twin, encoding="utf-8")
            tally.twins += 1
            href = _attribute(info.twin_url)
            edit.tags.append(f'<link rel="alternate" type="text/markdown" href="{href}">')

        if edit:
            info.dest.write_text(apply_edit(documents[info.dest], scan, edit), encoding="utf-8")
    return tally


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="gen_docs_seo.py",
        description="Per-page descriptions, Open Graph, JSON-LD and markdown twins, in place.",
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
        help="the address the site is actually served at. Used only when the config resolves "
        "no site_url, and compared against it when it does.",
    )
    args = parser.parse_args(argv)

    root: Path = args.root.resolve()
    site_dir = (root / args.site_dir).resolve()
    names = [args.config_file] if args.config_file else ["mkdocs.yml", "mkdocs.yaml"]
    config_file = next((root / n for n in names if (root / n).is_file()), root / names[0])

    if not site_dir.is_dir():
        print(f"::error::gen-docs-seo: no built site at {site_dir}", file=sys.stderr)
        return 1
    if not config_file.is_file():
        print(f"::error::gen-docs-seo: no {config_file.name} in {root}", file=sys.stderr)
        return 1

    fallback = args.site_url.strip()
    if fallback and not fallback.endswith("/"):
        fallback += "/"
    try:
        from mkdocs.exceptions import MkDocsException
    except ImportError:
        print(
            "::error::gen-docs-seo: MkDocs is not importable here. This step runs inside the "
            "docs toolchain that built the site.",
            file=sys.stderr,
        )
        return 1
    try:
        config, infos, resolver_for = load_site(config_file, site_dir, fallback)
    except (MkDocsException, OSError, ValueError) as exc:
        print(f"::error::gen-docs-seo: cannot load {config_file.name}: {exc}", file=sys.stderr)
        return 1

    configured = (config.get("site_url") or "").strip()
    if configured and not configured.endswith("/"):
        configured += "/"
    base = configured or fallback
    if not configured and fallback:
        # Seen on the fleet: a repo that does not INHERIT the base and sets no site_url of
        # its own. MkDocs then writes no canonical link on any page and a sitemap.xml with
        # no URLs in it, and nothing fails.
        _warn(
            f"{config_file.name} resolves no site_url, so MkDocs wrote no canonical links and "
            f"an empty sitemap.xml. Canonical links and og:url here use {fallback} instead; "
            "set site_url (or INHERIT the shared base) to fix the sitemap as well."
        )
    elif not base:
        _warn(
            "no site_url and no --site-url: canonical links, og:url and JSON-LD need absolute "
            "URLs, so they are left out. Descriptions and markdown twins are still written."
        )
    elif fallback and configured != fallback:
        _warn(
            f"site_url is {configured} but this site is served at {fallback}. Every canonical "
            "link, the sitemap and og:url name the first; set site_url to the second."
        )

    if not infos:
        print(
            f"::error::gen-docs-seo: {site_dir} has no page for any markdown file in the docs "
            "directory. Is --site-dir the directory `mkdocs build` wrote?",
            file=sys.stderr,
        )
        return 1

    settings = settings_from(config, base)
    for message in settings.warnings:
        _warn(message)
    tally = enrich(infos, settings, resolver_for)

    print(
        f"gen-docs-seo: {tally.pages} pages; {tally.descriptions} descriptions derived, "
        f"{tally.open_graph} Open Graph, {tally.twitter} Twitter, {tally.jsonld} JSON-LD, "
        f"{tally.canonicals} canonical, {tally.titles} title, {tally.twins} markdown twins written"
    )
    if tally.fallbacks:
        print(
            "gen-docs-seo: no paragraph of prose to describe, so these got a description "
            f"built from their title: {', '.join(tally.fallbacks)}"
        )
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
