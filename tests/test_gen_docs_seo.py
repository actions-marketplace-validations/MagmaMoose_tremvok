"""The page-SEO step: descriptions, Open Graph, JSON-LD and markdown twins, written in place.

Every failure here is silent where it happens and visible only to somebody else, later: a
description that repeats another page's, a tag written twice on a site that already had it,
an attribute escaped twice, a twin whose links 404, a second run that edits a page again. So
the end-to-end tests build a real MkDocs Material site and read the HTML it produced, rather
than asserting against a hand-written approximation of what Material emits.
"""

from __future__ import annotations

import html
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from scripts.gen_docs_seo import (
    Paragraph,
    bcp47,
    clip,
    description_candidates,
    home_title,
    link_resolver,
    main,
    og_locale,
    rewrite_links,
    scan_html,
    twin_markdown,
)

ROOT = Path(__file__).resolve().parents[1]
SITE_URL = "https://docs.example.test/widget/"


# --------------------------------------------------------------------------- a real site

BASE = f"""\
site_url: {SITE_URL}
theme:
  name: material
markdown_extensions:
  - admonition
  - pymdownx.details
  - pymdownx.superfences
  - tables
  - toc:
      permalink: true
extra:
  seo:
    locale: en_GB
    publisher:
      name: Example Org
      url: https://www.example.test/
      logo: https://www.example.test/logo.png
      same_as:
        - https://github.com/example
"""

# The repo's own file sets only the card image. The publisher has to arrive from the base,
# through INHERIT, which is the path the fleet relies on.
CHILD = """\
INHERIT: mkdocs.base.yml
site_name: Widget
site_description: "Widget does one thing well: this site says how."
extra:
  seo:
    image:
      url: https://www.example.test/og/widget.png
      width: 1200
      height: 630
nav:
  - Home: index.md
  - Setup: setup.md
  - Guides:
      - guides/index.md
      - Deploying: guides/deploy.md
      - Reference: guides/reference.md
"""

PAGES = {
    "index.md": (
        "# Widget\n\nWidget does one thing well, and these pages say how to make it do that.\n"
    ),
    "setup.md": (
        "# Setting Widget up\n\n"
        "!!! warning\n    Read the warning first. This is never the description of anything.\n\n"
        "| Column | Other |\n| --- | --- |\n"
        "| A table cell that is long enough to read as a sentence of prose | x |\n\n"
        '```bash\necho "a code block is not a description either"\n```\n\n'
        "[Deploying](guides/deploy.md)\n\n"
        "Install the widget with one command and point it at the repository it should watch. "
        "Use `<host>` & friends.\n\n"
        "See [rolling back](guides/deploy.md#rolling-back), the [guides](guides/index.md) and "
        "![the logo](img/logo.png).\n\n"
        "[ref]: guides/deploy.md\n"
    ),
    "guides/index.md": (
        "# Guides\n\nTask-shaped walkthroughs for the things people actually do with the widget "
        "every day.\n"
    ),
    # Opens with the same paragraph as setup.md, word for word.
    "guides/deploy.md": (
        "# Deploying\n\n"
        "Install the widget with one command and point it at the repository it should watch. "
        "Use `<host>` & friends.\n\n"
        "A deploy is one push to the default branch once the job is in place, and nothing else.\n"
        "\n## Rolling back\n\nRevert the commit and push again.\n"
    ),
    # Nothing but code: no paragraph of prose to describe it with.
    "guides/reference.md": "# Reference\n\n```text\nwidget --help\n```\n",
}


def write_repo(root: Path, *, child: str = CHILD, base: str = BASE) -> Path:
    (root / "docs" / "img").mkdir(parents=True, exist_ok=True)
    (root / "mkdocs.base.yml").write_text(base, encoding="utf-8")
    (root / "mkdocs.yml").write_text(child, encoding="utf-8")
    for name, body in PAGES.items():
        path = root / "docs" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    (root / "docs" / "img" / "logo.png").write_bytes(b"\x89PNG")
    return root


def mkdocs_build(root: Path) -> Path:
    # mkdocs-material is in the dev group, so this skips nothing under `uv run`. Only the
    # tests that build a site need it; the parsing, clipping and link tests run without.
    pytest.importorskip("material", reason="mkdocs-material is in the dev dependency group")
    subprocess.run(
        [sys.executable, "-m", "mkdocs", "build", "--strict", "--quiet", "--site-dir", "site"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return root / "site"


@pytest.fixture(scope="module")
def built(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """One build per module; every test gets its own copy to edit."""
    return write_repo(tmp_path_factory.mktemp("widget"))


@pytest.fixture(scope="module")
def built_site(built: Path) -> Path:
    mkdocs_build(built)
    return built


@pytest.fixture
def repo(built_site: Path, tmp_path: Path) -> Path:
    target = tmp_path / "repo"
    shutil.copytree(built_site, target)
    return target


def run(repo: Path, *extra: str) -> int:
    return main(["--root", str(repo), "--site-dir", "site", *extra])


def head(repo: Path, page: str) -> str:
    document = (repo / "site" / page).read_text(encoding="utf-8")
    return document[: document.index("</head>")]


def description(repo: Path, page: str) -> str:
    match = re.search(r'<meta name="description" content="([^"]*)"', head(repo, page))
    assert match, f"{page} has no description"
    return html.unescape(match.group(1))


def graph(repo: Path, page: str) -> list[dict]:
    blocks = re.findall(r'<script type="application/ld\+json">(.*?)</script>', head(repo, page))
    assert len(blocks) == 1, f"{page} carries {len(blocks)} JSON-LD blocks"
    return json.loads(blocks[0])["@graph"]


def tree(root: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()
    }


# --------------------------------------------------------------------------- end to end


def test_every_page_gets_its_own_description_and_the_home_page_keeps_the_sites(
    repo: Path,
) -> None:
    """Material prints `site_description` on every page. That is the duplicate this exists for."""
    assert run(repo) == 0
    pages = ["index.html", "setup/index.html", "guides/index.html", "guides/deploy/index.html"]
    found = {page: description(repo, page) for page in pages}

    assert found["index.html"] == "Widget does one thing well: this site says how."
    assert len(set(found.values())) == len(pages), found
    assert all(len(text) <= 155 for text in found.values())


def test_the_description_is_prose_not_a_warning_a_table_code_or_a_link(repo: Path) -> None:
    assert run(repo) == 0
    assert description(repo, "setup/index.html") == (
        "Install the widget with one command and point it at the repository it should watch. "
        "Use <host> & friends."
    )


def test_a_page_that_opens_like_another_gets_its_next_paragraph(repo: Path) -> None:
    """deploy.md opens with setup.md's paragraph. The page earlier in the nav keeps it."""
    assert run(repo) == 0
    assert description(repo, "guides/deploy/index.html") == (
        "A deploy is one push to the default branch once the job is in place, and nothing else."
    )


def test_an_attribute_is_escaped_exactly_once(repo: Path) -> None:
    """The HTML decodes `&lt;host&gt;`; writing it back must not produce `&amp;lt;host&amp;gt;`."""
    assert run(repo) == 0
    tags = head(repo, "setup/index.html")
    assert 'Use &lt;host&gt; &amp; friends."' in tags
    assert "&amp;lt;" not in tags
    assert "&amp;amp;" not in tags


def test_open_graph_and_twitter_tags_come_from_the_page_and_extra_seo(repo: Path) -> None:
    assert run(repo) == 0
    tags = head(repo, "guides/deploy/index.html")
    for expected in (
        '<meta property="og:type" content="article">',
        '<meta property="og:site_name" content="Widget">',
        '<meta property="og:locale" content="en_GB">',
        '<meta property="og:title" content="Deploying">',
        f'<meta property="og:url" content="{SITE_URL}guides/deploy/">',
        '<meta property="og:image" content="https://www.example.test/og/widget.png">',
        '<meta property="og:image:width" content="1200">',
        '<meta property="og:image:height" content="630">',
        '<meta property="og:image:alt" content="Widget">',
        '<meta name="twitter:card" content="summary_large_image">',
    ):
        assert expected in tags
    assert '<meta property="og:type" content="website">' in head(repo, "index.html")


def test_extra_seo_from_the_inherited_base_reaches_the_graph(repo: Path) -> None:
    """MkDocs hands `extra` back as a LegacyConfig, a Mapping that is not a dict. Read with an
    isinstance(dict) check, every site looks unconfigured and the publisher silently vanishes.
    """
    assert run(repo) == 0
    nodes = {node["@type"]: node for node in graph(repo, "guides/deploy/index.html")}

    publisher = nodes["Organization"]
    assert publisher["@id"] == "https://www.example.test/#organization"
    assert publisher["logo"]["url"] == "https://www.example.test/logo.png"
    assert publisher["sameAs"] == ["https://github.com/example"]

    article = nodes["TechArticle"]
    assert article["headline"] == "Deploying"
    assert article["url"] == f"{SITE_URL}guides/deploy/"
    assert article["isPartOf"] == {"@id": f"{SITE_URL}#website"}
    assert article["publisher"] == {"@id": publisher["@id"]}
    assert article["inLanguage"] == "en-GB"
    assert article["image"] == "https://www.example.test/og/widget.png"


def test_the_breadcrumb_follows_the_nav_through_the_section_index(repo: Path) -> None:
    assert run(repo) == 0
    crumbs = next(
        node
        for node in graph(repo, "guides/deploy/index.html")
        if node["@type"] == "BreadcrumbList"
    )
    assert [(item["name"], item["item"]) for item in crumbs["itemListElement"]] == [
        ("Widget", SITE_URL),
        ("Guides", f"{SITE_URL}guides/"),
        ("Deploying", f"{SITE_URL}guides/deploy/"),
    ]


def test_the_home_page_has_a_website_node_and_no_article(repo: Path) -> None:
    assert run(repo) == 0
    types = [node["@type"] for node in graph(repo, "index.html")]
    assert types == ["WebSite", "Organization"]


def test_a_second_run_changes_nothing(repo: Path) -> None:
    """An in-place editor that is not idempotent adds a tag per rerun of a failed job."""
    assert run(repo) == 0
    first = tree(repo / "site")
    assert run(repo) == 0
    assert tree(repo / "site") == first


def test_tags_a_page_already_has_are_left_alone(repo: Path) -> None:
    """docs.calebsargeant.com writes its own Open Graph tags, JSON-LD and descriptions.

    Skipping only the tag names this step writes would still double the rest, so each part
    is keyed on the tag that marks it: og:title, twitter:card, any ld+json block.
    """
    page = repo / "site" / "setup" / "index.html"
    document = page.read_text(encoding="utf-8")
    own = (
        '<meta property="og:title" content="Theirs">\n'
        '<meta name="twitter:card" content="summary">\n'
        '<script type="application/ld+json">{"@context":"https://schema.org"}</script>\n'
    )
    document = document.replace("</head>", own + "</head>", 1)
    document = re.sub(
        r'<meta name="description" content="[^"]*">',
        '<meta name="description" content="Chosen by a hook.">',
        document,
        count=1,
    )
    page.write_text(document, encoding="utf-8")

    assert run(repo) == 0
    tags = head(repo, "setup/index.html")
    assert tags.count("og:title") == 1
    assert "og:description" not in tags
    assert tags.count("twitter:card") == 1
    assert "twitter:title" not in tags
    assert tags.count("application/ld+json") == 1
    assert description(repo, "setup/index.html") == "Chosen by a hook."


def test_a_front_matter_description_is_the_authors_choice(tmp_path: Path) -> None:
    repo = write_repo(tmp_path)
    (repo / "docs" / "guides" / "index.md").write_text(
        "---\ndescription: Written by hand.\n---\n\n# Guides\n\nSome prose that would win.\n",
        encoding="utf-8",
    )
    mkdocs_build(repo)
    assert run(repo) == 0
    assert description(repo, "guides/index.html") == "Written by hand."


def test_the_twin_is_the_source_with_links_that_work_from_where_it_lives(repo: Path) -> None:
    """The twin sits one directory below its source, so every relative link would 404."""
    assert run(repo) == 0
    twin = (repo / "site" / "setup" / "index.md").read_text(encoding="utf-8")

    assert twin.startswith(f"# Setting Widget up\n\n> Markdown source of {SITE_URL}setup/.\n\n")
    assert f"[Deploying]({SITE_URL}guides/deploy/)" in twin
    assert f"[rolling back]({SITE_URL}guides/deploy/#rolling-back)" in twin
    assert f"[guides]({SITE_URL}guides/)" in twin
    assert f"![the logo]({SITE_URL}img/logo.png)" in twin
    assert f"[ref]: {SITE_URL}guides/deploy/" in twin
    # Code is quoted as written.
    assert 'echo "a code block is not a description either"' in twin
    assert "Use `<host>` & friends." in twin

    link = f'<link rel="alternate" type="text/markdown" href="{SITE_URL}setup/index.md">'
    assert head(repo, "setup/index.html").count('type="text/markdown"') == 1
    assert link in head(repo, "setup/index.html")
    assert (repo / "site" / "index.md").is_file()


def test_an_existing_twin_and_its_link_are_left_alone(repo: Path) -> None:
    """docs.calebsargeant.com's hook writes its own twins. Neither half is overwritten or
    doubled, and a twin that exists without a link is not given one either."""
    guides = repo / "site" / "guides"
    (guides / "index.md").write_text("# Theirs\n", encoding="utf-8")
    deploy = guides / "deploy" / "index.html"
    link = '<link rel="alternate" type="text/markdown" href="theirs.md">'
    deploy.write_text(
        deploy.read_text(encoding="utf-8").replace("</head>", link + "\n</head>", 1),
        encoding="utf-8",
    )

    assert run(repo) == 0
    assert (guides / "index.md").read_text(encoding="utf-8") == "# Theirs\n"
    assert 'type="text/markdown"' not in head(repo, "guides/index.html")
    assert not (guides / "deploy" / "index.md").exists()
    assert head(repo, "guides/deploy/index.html").count('type="text/markdown"') == 1


def test_no_site_url_takes_the_router_address_and_says_so(tmp_path: Path, capsys) -> None:
    """diatreme's shape: no INHERIT, no site_url. MkDocs then writes no canonical link on any
    page and a sitemap with no URLs in it, and nothing fails."""
    repo = write_repo(tmp_path, base=BASE.replace(f"site_url: {SITE_URL}\n", ""))
    mkdocs_build(repo)
    assert 'rel="canonical"' not in head(repo, "setup/index.html")

    assert run(repo, "--site-url", "https://docs.example.test/widget") == 0
    assert f'<link rel="canonical" href="{SITE_URL}setup/">' in head(repo, "setup/index.html")
    assert f'<meta property="og:url" content="{SITE_URL}setup/">' in head(repo, "setup/index.html")
    err = capsys.readouterr().err
    assert "::warning::" in err
    assert "resolves no site_url" in err


def test_no_base_url_at_all_skips_only_what_needs_one(tmp_path: Path, capsys) -> None:
    repo = write_repo(tmp_path, base=BASE.replace(f"site_url: {SITE_URL}\n", ""))
    mkdocs_build(repo)
    assert run(repo) == 0
    tags = head(repo, "setup/index.html")
    assert "og:url" not in tags
    assert "application/ld+json" not in tags
    assert 'rel="canonical"' not in tags
    assert description(repo, "setup/index.html").startswith("Install the widget")
    # Relative, from where the twin lives, when there is nothing to make it absolute with.
    twin = (repo / "site" / "setup" / "index.md").read_text(encoding="utf-8")
    assert "[Deploying](../guides/deploy/)" in twin
    assert '<link rel="alternate" type="text/markdown" href="index.md">' in tags
    assert "no site_url and no --site-url" in capsys.readouterr().err


def test_a_stale_site_url_is_named_rather_than_rewritten(repo: Path, capsys) -> None:
    """noctyr's shape: site_url still names magmamoose.github.io. Rewriting the canonical
    would contradict the sitemap MkDocs built from the same value; the warning says which
    line to change."""
    assert run(repo, "--site-url", "https://docs.elsewhere.test/widget/") == 0
    assert f'<meta property="og:url" content="{SITE_URL}setup/">' in head(repo, "setup/index.html")
    assert "is served at https://docs.elsewhere.test/widget/" in capsys.readouterr().err


def test_a_missing_site_directory_is_a_hard_error(tmp_path: Path, capsys) -> None:
    write_repo(tmp_path)
    assert run(tmp_path) == 1
    assert "no built site" in capsys.readouterr().err


def test_a_page_with_no_prose_is_described_by_where_it_sits(repo: Path, capsys) -> None:
    """Better than the site's sentence, and unique, because the nav path to a page is."""
    assert run(repo) == 0
    assert description(repo, "guides/reference/index.html") == (
        "Widget documentation: Guides / Reference."
    )
    # Named in the log, so a page that needs an opening sentence is not found by accident.
    out = capsys.readouterr().out
    assert "no paragraph of prose" in out
    assert "guides/reference.md" in out


def test_no_config_is_a_hard_error(tmp_path: Path, capsys) -> None:
    (tmp_path / "site").mkdir()
    assert run(tmp_path) == 1
    assert "no mkdocs.yml" in capsys.readouterr().err


def test_a_site_with_no_page_for_any_source_is_a_hard_error(tmp_path: Path, capsys) -> None:
    """Pointed at the wrong directory, nothing matches. Say so rather than succeed at nothing."""
    pytest.importorskip("material", reason="mkdocs-material is in the dev dependency group")
    write_repo(tmp_path)
    (tmp_path / "site").mkdir()
    assert run(tmp_path) == 1
    assert "has no page for any markdown file" in capsys.readouterr().err


# --------------------------------------------------------------------------- descriptions

ARTICLE = """
<html lang="en"><head><title>T</title></head><body>
<nav class="md-nav"><p>A navigation paragraph with plenty of words in it, never prose.</p></nav>
<article class="md-content__inner md-typeset">
<h1 id="t">Title<a class="headerlink" href="#t">&para;</a></h1>
{body}
</article>
<footer><p>A footer paragraph with plenty of words in it, never a description.</p></footer>
</body></html>
"""


def candidates(body: str) -> list[str]:
    return description_candidates(scan_html(ARTICLE.format(body=body)).prose())


def test_only_the_article_is_read() -> None:
    assert candidates("<p>The page's own opening sentence, which is the one to use.</p>") == [
        "The page's own opening sentence, which is the one to use."
    ]


def test_a_line_break_is_a_space() -> None:
    assert candidates("<p>A line that breaks here<br>and carries on for a while after it.</p>") == [
        "A line that breaks here and carries on for a while after it."
    ]


def test_another_theme_is_read_by_its_main_region() -> None:
    """The `mkdocs` theme has no <article>; its content is `role="main"`."""
    document = (
        "<html><body><nav><p>Navigation paragraph with plenty of words, never prose.</p></nav>"
        '<div role="main"><p>The content of the page, in a theme without an article.</p></div>'
        "</body></html>"
    )
    assert description_candidates(scan_html(document).prose()) == [
        "The content of the page, in a theme without an article."
    ]
    bare = (
        "<html><body><p>No landmarks at all, so every paragraph is a candidate.</p></body></html>"
    )
    assert description_candidates(scan_html(bare).prose()) == [
        "No landmarks at all, so every paragraph is a candidate."
    ]


def test_the_headerlink_pilcrow_is_not_part_of_the_title() -> None:
    assert scan_html(ARTICLE.format(body="")).h1 == "Title"


def test_admonitions_details_tables_lists_and_link_lines_are_skipped() -> None:
    body = (
        '<div class="admonition warning"><p>A warning paragraph with plenty of words.</p></div>'
        "<details><summary>More</summary><p>A collapsed paragraph with many words.</p></details>"
        "<table><tr><td><p>A table cell paragraph with plenty of words in it.</p></td></tr></table>"
        "<ul><li><p>A list item paragraph with plenty of words in it here.</p></li></ul>"
        '<p><a href="a/">One link</a> and <a href="b/">another link</a>.</p>'
        "<p>Finally the real opening paragraph of this page, in plain prose.</p>"
    )
    assert candidates(body)[0] == "Finally the real opening paragraph of this page, in plain prose."


def test_a_short_paragraph_takes_the_next_when_nothing_stands_between() -> None:
    assert candidates(
        "<p>Two surfaces, one repository.</p><p>They talk over HTTP, nothing else.</p>"
    )[0] == ("Two surfaces, one repository. They talk over HTTP, nothing else.")
    assert candidates(
        "<p>Two surfaces, one repository.</p><pre><code>x</code></pre>"
        "<p>They talk over HTTP, nothing else.</p>"
    )[0] == ("Two surfaces, one repository.")


def test_a_sentence_split_by_a_code_block_is_not_stitched_back_together() -> None:
    """ "runs" + "and reads every report" describes a command that is not in the description."""
    body = (
        "<p>Brimyr detects a Maven repo from <code>pom.xml</code>, runs</p>"
        '<div class="highlight"><pre><code>mvn verify</code></pre></div>'
        "<p>and reads every <code>jacoco.xml</code> it produced.</p>"
        "<p>The plugin goals are invoked by coordinate, so nothing has to be configured.</p>"
    )
    assert candidates(body)[0] == (
        "The plugin goals are invoked by coordinate, so nothing has to be configured."
    )


def test_a_lower_case_opening_is_a_sentence_when_nothing_was_left_unfinished() -> None:
    assert candidates("<p>v1 is the docs-only action, and it keeps working as it did.</p>") == [
        "v1 is the docs-only action, and it keeps working as it did."
    ]


def test_a_paragraph_opening_on_code_is_a_sentence_about_that_code() -> None:
    body = (
        "<p>Run it like this:</p><pre><code>x</code></pre>"
        "<p><code>dotnet test</code> writes one report per test project, each on its own.</p>"
    )
    assert "dotnet test writes one report per test project, each on its own." in candidates(body)


def test_a_run_in_heading_is_not_joined_to_the_intro() -> None:
    body = (
        "<p>Terms that appear in the inputs and the logs.</p>"
        "<p><strong>Action surface.</strong> The composite action that runs on your runner.</p>"
    )
    assert candidates(body)[0] == "Terms that appear in the inputs and the logs."


def test_an_introducing_colon_becomes_a_full_stop() -> None:
    assert candidates(
        "<p>Run all four checks before opening a pull request, in this order:</p>"
    ) == ["Run all four checks before opening a pull request, in this order."]


def test_a_page_with_no_prose_has_no_candidate() -> None:
    assert candidates("<pre><code>only code</code></pre>") == []


def test_clip_stays_within_the_limit_on_a_word_boundary() -> None:
    text = "word " * 60
    clipped = clip(text)
    assert len(clipped) <= 155
    assert clipped.endswith("\u2026")
    assert not clipped.endswith(" \u2026")
    assert clipped[:-1].split()[-1] == "word"


def test_clip_prefers_a_whole_sentence_then_a_clause() -> None:
    sentence = "A first sentence that is long enough to keep on its own, clearly. " * 3
    assert clip(sentence).endswith("clearly.")
    clause = (
        "Pick a target, add the job, grant the permissions that target needs. The action "
        "reference has every input and the exact permission block per target; this page is "
        "the task-shaped version of it."
    )
    assert clip(clause) == (
        "Pick a target, add the job, grant the permissions that target needs. The action "
        "reference has every input and the exact permission block per target."
    )


def test_a_paragraph_under_the_limit_is_untouched() -> None:
    assert clip("Short and whole.") == "Short and whole."


def test_paragraph_defaults_are_a_plain_sentence() -> None:
    paragraph = Paragraph("A plain sentence that is long enough to describe a page.", 2, False)
    assert description_candidates([paragraph]) == [paragraph.text]


# --------------------------------------------------------------------------- titles, locales


@pytest.mark.parametrize(
    ("site_name", "site_description", "expected"),
    [
        (
            "Tremvok",
            "One GitHub Action for the whole deploy side: GitHub Pages, Cloudflare Workers.",
            "Tremvok - One GitHub Action for the whole deploy side",
        ),
        (
            "Brimyr",
            "Quality assurance for a pull request \u2014 auto-detect the ecosystem.",
            "Brimyr - Quality assurance for a pull request",
        ),
        # Repeats the name: "Widget - Widget does one thing well" is worse than "Widget".
        ("Widget", "Widget does one thing well: this site says how.", ""),
        # Too long to survive in a result title.
        ("Widget", "A lead clause that goes on and on well past what a result can show.", ""),
        # Too short to mean anything.
        ("Widget", "Docs. More words follow here.", ""),
        # A version number is not a sentence end.
        (
            "Widget",
            "Release notes for v2.0 and everything after it.",
            "Widget - Release notes for v2.0 and everything after it",
        ),
    ],
)
def test_home_title(site_name: str, site_description: str, expected: str) -> None:
    assert home_title(site_name, site_description) == expected


def test_the_home_title_is_replaced_only_when_it_is_the_bare_site_name(tmp_path: Path) -> None:
    child = CHILD.replace(
        'site_description: "Widget does one thing well: this site says how."',
        'site_description: "Release notes and guides for the widget: all of them."',
    )
    repo = write_repo(tmp_path, child=child)
    mkdocs_build(repo)
    assert run(repo) == 0
    assert "<title>Widget - Release notes and guides for the widget</title>" in head(
        repo, "index.html"
    )
    assert "<title>Setup - Widget</title>" in head(repo, "setup/index.html")


@pytest.mark.parametrize(
    ("value", "locale", "language"),
    [("en_GB", "en_GB", "en-GB"), ("en-gb", "en_GB", "en-GB"), ("en", "", "en"), ("", "", "")],
)
def test_locales(value: str, locale: str, language: str) -> None:
    """A bare `en` gives no og:locale: OGP's default is en_US, and guessing a territory for
    someone else's site is worse than saying nothing."""
    assert og_locale(value) == locale
    assert bcp47(value) == language


# --------------------------------------------------------------------------- twins


def resolver(src_uri: str = "setup.md", page_url: str = "setup/"):
    urls = {"setup.md": "setup/", "guides/deploy.md": "guides/deploy/", "img/a.png": "img/a.png"}
    return link_resolver(src_uri, page_url, urls.get, lambda url: f"{SITE_URL}{url}")


@pytest.mark.parametrize(
    ("markdown", "expected"),
    [
        ("[d](guides/deploy.md)", f"[d]({SITE_URL}guides/deploy/)"),
        ("[d](guides/deploy.md#x)", f"[d]({SITE_URL}guides/deploy/#x)"),
        ("[d](<guides/deploy.md>)", f"[d](<{SITE_URL}guides/deploy/>)"),
        ('[d](guides/deploy.md "T")', f'[d]({SITE_URL}guides/deploy/ "T")'),
        ("![a](img/a.png)", f"![a]({SITE_URL}img/a.png)"),
        (
            "[![a](img/a.png)](guides/deploy.md)",
            f"[![a]({SITE_URL}img/a.png)]({SITE_URL}guides/deploy/)",
        ),
        ("[same page](#here)", f"[same page]({SITE_URL}setup/#here)"),
        ("[x]: guides/deploy.md", f"[x]: {SITE_URL}guides/deploy/"),
        # Left exactly as written:
        ("[^1]: guides/deploy.md is a footnote", "[^1]: guides/deploy.md is a footnote"),
        ("[e](https://example.test/a.md)", "[e](https://example.test/a.md)"),
        ("[m](mailto:a@example.test)", "[m](mailto:a@example.test)"),
        ("[r](/root/page.md)", "[r](/root/page.md)"),
        ("[up](../outside.md)", "[up](../outside.md)"),
        ("[gone](missing.md)", "[gone](missing.md)"),
        ("`[c](guides/deploy.md)`", "`[c](guides/deploy.md)`"),
        ("```\n[c](guides/deploy.md)\n```\n", "```\n[c](guides/deploy.md)\n```\n"),
    ],
)
def test_links_are_resolved_the_way_mkdocs_resolves_them(markdown: str, expected: str) -> None:
    assert rewrite_links(markdown, resolver()) == expected


def test_a_twin_gets_a_title_when_the_page_takes_it_from_the_nav() -> None:
    twin = twin_markdown("Just prose.\n", "From the nav", resolver(), f"{SITE_URL}setup/")
    assert twin == f"# From the nav\n\n> Markdown source of {SITE_URL}setup/.\n\nJust prose.\n"


@pytest.mark.parametrize(
    "markdown",
    [
        "# Own\n\nProse.\n",
        "#Own\n\nProse.\n",
        "Own\n===\n\nProse.\n",
        "<!-- a comment first -->\n\n# Own\n\nProse.\n",
    ],
)
def test_a_twin_never_gets_a_second_title(markdown: str) -> None:
    twin = twin_markdown(markdown, "From the nav", resolver(), f"{SITE_URL}setup/")
    assert "From the nav" not in twin
    assert f"> Markdown source of {SITE_URL}setup/." in twin


def test_a_heading_inside_a_fence_is_not_the_title() -> None:
    twin = twin_markdown("```\n# not a title\n```\n", "Real", resolver(), "")
    assert twin.startswith("# Real\n\n```")


# --------------------------------------------------------------------------- the action


def test_the_step_runs_after_the_build_and_before_anything_reads_the_site() -> None:
    """After the corpus, llms.txt would not see the twins. After the Pages artifact is staged,
    github-pages would publish the pages without any of it. Both are silent."""
    steps = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))["runs"]["steps"]
    names = [step.get("name", "") for step in steps]
    seo = next(i for i, step in enumerate(steps) if "gen_docs_seo.py" in str(step.get("env", "")))
    assert names.index("Build the site") < seo
    assert seo < names.index("Stage the Pages artifact")
    assert seo < names.index("Emit the docs corpus")
    assert seo < names.index("Deploy \u2014 Cloudflare docs")
    condition = steps[seo]["if"]
    assert "inputs.pages-seo == 'true'" in condition
    assert "github-pages" in condition
    assert "cloudflare-docs" in condition


def test_the_step_is_on_by_default() -> None:
    inputs = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))["inputs"]
    assert inputs["pages-seo"]["default"] == "true"
