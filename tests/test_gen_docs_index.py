"""The docs corpus generator.

The assertions that matter are the ones whose failure is silent at generation time and
loud days later, inside someone else's agent: a URL that 404s, a snippet naming a file
that does not exist, a corpus that indexed a mermaid block.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from scripts.gen_docs_index import (
    canonical_url,
    extract_headings,
    extract_snippet,
    extract_title,
    main,
    markdown_twin,
    plain_text,
    strip_front_matter,
    url_path_for,
)

SITE_URL = "https://docs.magmamoose.com/tremvok/"


# --------------------------------------------------------------------------- fixtures


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    (tmp_path / "docs").mkdir()
    (tmp_path / "mkdocs.yml").write_text(
        "site_name: Tremvok\n"
        "site_description: One action for the deploy side.\n"
        f"site_url: {SITE_URL}\n"
        "markdown_extensions:\n"
        "  - pymdownx.superfences:\n"
        "      custom_fences:\n"
        "        - name: mermaid\n"
        "          format: !!python/name:pymdownx.superfences.fence_code_format\n",
        encoding="utf-8",
    )
    (tmp_path / "docs" / "index.md").write_text(
        "# Tremvok\n\nOne action for the whole deploy side.\n", encoding="utf-8"
    )
    (tmp_path / "docs" / "setup.md").write_text(
        "# Setting Tremvok up\n\n"
        "Pick a `target`, add the job. Edit `scripts/gen_action_reference.py`, not the page.\n"
        "\n## Permissions\n\nGrant what the target needs.\n"
        "\n### github-pages\n\n`pages: write`.\n",
        encoding="utf-8",
    )
    return tmp_path


def build_site(repo: Path, *, directory_urls: bool = True) -> Path:
    """A stand-in for what `mkdocs build` emits, in both URL shapes."""
    site = repo / "site"
    (site).mkdir(exist_ok=True)
    (site / "index.html").write_text("<html></html>", encoding="utf-8")
    if directory_urls:
        (site / "setup").mkdir(exist_ok=True)
        (site / "setup" / "index.html").write_text("<html></html>", encoding="utf-8")
    else:
        (site / "setup.html").write_text("<html></html>", encoding="utf-8")
    return site


# --------------------------------------------------------------------------- units


def test_intraword_underscores_survive() -> None:
    """`gen_action_reference.py` must not become `genactionreference.py`.

    Markdown itself ignores an intraword underscore. Treating one as emphasis produces a
    snippet naming a file that does not exist, in a corpus whose entire job is helping an
    agent find the file.
    """
    assert plain_text("`scripts/gen_action_reference.py`") == "scripts/gen_action_reference.py"
    assert plain_text("a _real_ emphasis") == "a real emphasis"
    assert plain_text("**bold** and *italic*") == "bold and italic"


def test_links_and_images_flatten_to_their_text() -> None:
    assert plain_text("see [Setup](setup.md) first") == "see Setup first"
    assert plain_text("![diagram](a.png)text") == "text"


def test_attr_list_anchors_are_dropped() -> None:
    assert plain_text("Heading { #anchor }") == "Heading"


def test_headings_exclude_fenced_code() -> None:
    body = "## Real\n\n```mermaid\nflowchart LR\n## Not a heading\n```\n\n### Also real\n"
    assert extract_headings(body) == ["Real", "Also real"]


def test_headings_are_h2_and_h3_only() -> None:
    body = "# Title\n\n## Two\n\n#### Four\n"
    assert extract_headings(body) == ["Two"]


def test_snippet_skips_the_title_and_takes_the_first_prose() -> None:
    assert extract_snippet("# Title\n\nThe first paragraph.\n\nThe second.\n") == (
        "The first paragraph."
    )


def test_snippet_ignores_a_leading_code_block() -> None:
    body = "# Title\n\n```bash\nrun me\n```\n\nThe prose.\n"
    assert extract_snippet(body) == "The prose."


def test_snippet_is_truncated_on_a_word_boundary() -> None:
    body = "# T\n\n" + ("word " * 200)
    snippet = extract_snippet(body)
    assert len(snippet) <= 321
    assert snippet.endswith("…")


def test_front_matter_title_wins(tmp_path: Path) -> None:
    meta, body = strip_front_matter("---\ntitle: From Meta\n---\n# From H1\n\nText.\n")
    assert meta["title"] == "From Meta"
    assert extract_title(meta, body, tmp_path / "x.md") == "From Meta"


def test_title_falls_back_to_the_filename(tmp_path: Path) -> None:
    assert extract_title({}, "No heading here.\n", tmp_path / "some-page.md") == "Some page"


# --------------------------------------------------------------------------- urls


def test_url_shape_is_detected_from_the_built_site(repo: Path) -> None:
    """A repo may set `use_directory_urls: false`, and a corpus of 404s is worse than none."""
    site = build_site(repo, directory_urls=True)
    assert url_path_for(Path("setup.md"), site) == "setup/"

    (site / "setup" / "index.html").unlink()
    (site / "setup").rmdir()
    (site / "setup.html").write_text("<html></html>", encoding="utf-8")
    assert url_path_for(Path("setup.md"), site) == "setup.html"


def test_index_md_is_the_directory_root(repo: Path) -> None:
    site = build_site(repo)
    (site / "adr").mkdir()
    (site / "adr" / "index.html").write_text("<html></html>", encoding="utf-8")
    assert url_path_for(Path("index.md"), site) == ""
    assert url_path_for(Path("adr/index.md"), site) == "adr/"


def test_readme_is_the_directory_index(repo: Path) -> None:
    """MkDocs renders `README.md` to `<dir>/index.html`, so `<dir>/README/` never exists.

    Resolved like any other page, a README the build did render would be left out.
    """
    site = build_site(repo)
    (site / "guide").mkdir()
    (site / "guide" / "index.html").write_text("<html></html>", encoding="utf-8")
    assert url_path_for(Path("guide/README.md"), site) == "guide/"
    assert url_path_for(Path("README.md"), site) == ""


def test_a_source_the_build_emitted_no_page_for_has_no_url(repo: Path) -> None:
    """`exclude_docs` and `draft_docs` keep a file in `docs/` and its page out of the site.

    Given the URL it would have had, the corpus cites a page that 404s.
    """
    site = build_site(repo)
    assert url_path_for(Path("other/general/_docs/README.md"), site) is None
    assert url_path_for(Path("drafts/wip.md"), site) is None
    assert url_path_for(Path("drafts/index.md"), site) is None


def test_url_falls_back_to_directory_urls_without_a_built_site(tmp_path: Path) -> None:
    assert url_path_for(Path("setup.md"), tmp_path / "nope") == "setup/"


def test_canonical_url_joins_without_doubling_slashes() -> None:
    assert canonical_url(SITE_URL, "setup/") == "https://docs.magmamoose.com/tremvok/setup/"
    assert canonical_url(SITE_URL, "") == "https://docs.magmamoose.com/tremvok/"


# --------------------------------------------------------------------------- end to end


def test_main_emits_index_llms_and_llms_full(repo: Path, tmp_path: Path) -> None:
    build_site(repo)
    out = tmp_path / "out"
    rc = main(
        [
            "--root",
            str(repo),
            "--repo",
            "tremvok",
            "--site-dir",
            "site",
            "--index-out",
            str(out),
            "--commit",
            "abc123",
        ]
    )
    assert rc == 0

    document = json.loads((out / "index" / "tremvok.json").read_text(encoding="utf-8"))
    assert document["repo"] == "tremvok"
    assert document["commit"] == "abc123"
    assert document["site_url"] == SITE_URL

    by_path = {entry["path"]: entry for entry in document["docs"]}
    # Repository-relative, because that is what the reader's read_doc takes.
    assert set(by_path) == {"docs/index.md", "docs/setup.md"}

    setup = by_path["docs/setup.md"]
    assert setup["repo"] == "tremvok"
    assert setup["title"] == "Setting Tremvok up"
    assert setup["headings"] == ["Permissions", "github-pages"]
    assert setup["url"] == "https://docs.magmamoose.com/tremvok/setup/"
    assert "gen_action_reference.py" in setup["snippet"]
    # The markdown as authored, H1 and headings included: the reader returns it from
    # read_doc and scores headings above prose.
    assert setup["text"].startswith("# Setting Tremvok up")
    assert "## Permissions" in setup["text"]
    assert setup["bytes"] == len(setup["text"].encode("utf-8"))

    llms = (repo / "site" / "llms.txt").read_text(encoding="utf-8")
    assert llms.startswith("# Tremvok")
    assert "> One action for the deploy side." in llms
    assert "[Setting Tremvok up](https://docs.magmamoose.com/tremvok/setup/)" in llms

    full = (repo / "site" / "llms-full.txt").read_text(encoding="utf-8")
    assert "Source: docs/setup.md" in full
    assert "Grant what the target needs." in full
    # The page's own H1 is dropped in favour of the emitted one, so it appears once.
    assert full.count("# Setting Tremvok up") == 1


def test_a_page_the_build_excluded_is_not_in_the_corpus(repo: Path, tmp_path: Path, capsys) -> None:
    """`exclude_docs: **/_docs/` keeps a lab-file README in `docs/` and out of the site.

    Walking the markdown still finds it. Indexed, it is cited at a URL that 404s by every
    MCP surface reading the corpus, and listed in llms.txt beside pages that exist.
    """
    lab = repo / "docs" / "other" / "general" / "_docs"
    lab.mkdir(parents=True)
    (lab / "README.md").write_text("# Lab files\n\nA template for a lab.\n", encoding="utf-8")
    build_site(repo)
    out = tmp_path / "out"
    rc = main(
        [
            "--root",
            str(repo),
            "--repo",
            "tremvok",
            "--site-dir",
            "site",
            "--index-out",
            str(out),
        ]
    )
    assert rc == 0

    document = json.loads((out / "index" / "tremvok.json").read_text(encoding="utf-8"))
    assert {entry["path"] for entry in document["docs"]} == {"docs/index.md", "docs/setup.md"}
    for name in ("llms.txt", "llms-full.txt"):
        text = (repo / "site" / name).read_text(encoding="utf-8")
        assert "Lab files" not in text
        assert "_docs/" not in text
    # Named in the log: a page missing from the corpus is otherwise noticed by nobody.
    assert "docs/other/general/_docs/README.md" in capsys.readouterr().out


def test_a_site_with_no_page_for_any_source_is_a_hard_error(
    repo: Path, tmp_path: Path, capsys
) -> None:
    """Pointed at the wrong site, every source is left out. Say that, not "no markdown"."""
    (repo / "site").mkdir()
    rc = main(
        [
            "--root",
            str(repo),
            "--repo",
            "tremvok",
            "--site-dir",
            "site",
            "--index-out",
            str(tmp_path / "o"),
        ]
    )
    assert rc == 1
    err = capsys.readouterr().err
    assert "has no page for any markdown file" in err
    assert "no markdown" not in err


def test_index_is_byte_stable_across_runs(repo: Path, tmp_path: Path) -> None:
    """An unchanged docs tree must produce an unchanged file, minus the timestamp."""
    build_site(repo)
    outputs = []
    for name in ("a", "b"):
        out = tmp_path / name
        main(
            [
                "--root",
                str(repo),
                "--repo",
                "tremvok",
                "--site-dir",
                "site",
                "--index-out",
                str(out),
            ]
        )
        document = json.loads((out / "index" / "tremvok.json").read_text(encoding="utf-8"))
        document.pop("generated")
        outputs.append(json.dumps(document, sort_keys=True))
    assert outputs[0] == outputs[1]


def test_a_missing_site_url_is_a_hard_error(repo: Path, tmp_path: Path, capsys) -> None:
    """A corpus of relative URLs fails at read time, in an agent, days later."""
    (repo / "mkdocs.yml").write_text("site_name: Tremvok\n", encoding="utf-8")
    rc = main(["--root", str(repo), "--repo", "tremvok", "--index-out", str(tmp_path / "o")])
    assert rc == 1
    assert "site_url" in capsys.readouterr().err


def test_site_url_override_wins_over_mkdocs(repo: Path, tmp_path: Path) -> None:
    out = tmp_path / "out"
    main(
        [
            "--root",
            str(repo),
            "--repo",
            "tremvok",
            "--site-url",
            "https://example.test/tremvok",
            "--index-out",
            str(out),
        ]
    )
    document = json.loads((out / "index" / "tremvok.json").read_text(encoding="utf-8"))
    # The trailing slash is added, so the router prefix and MkDocs' links agree.
    assert document["site_url"] == "https://example.test/tremvok/"
    assert document["docs"][0]["url"].startswith("https://example.test/tremvok/")


def test_no_markdown_is_a_hard_error(tmp_path: Path, capsys) -> None:
    (tmp_path / "docs").mkdir()
    (tmp_path / "mkdocs.yml").write_text(f"site_url: {SITE_URL}\n", encoding="utf-8")
    rc = main(["--root", str(tmp_path), "--repo", "tremvok", "--index-out", str(tmp_path / "o")])
    assert rc == 1
    assert "no markdown" in capsys.readouterr().err


# --------------------------------------------------------------------------- the reader's contract


def _index(repo: Path, tmp_path: Path, *extra: str) -> dict:
    build_site(repo)
    out = tmp_path / "contract"
    rc = main(
        [
            "--root",
            str(repo),
            "--repo",
            "tremvok",
            "--site-dir",
            "site",
            "--index-out",
            str(out),
            *extra,
        ]
    )
    assert rc == 0
    return json.loads((out / "index" / "tremvok.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    ("visibility", "private"),
    [
        ("public", False),
        ("PUBLIC", False),
        ("private", True),
        ("internal", True),
        ("", True),
        ("publik", True),
    ],
)
def test_only_an_explicit_public_marks_the_index_public(
    repo: Path, tmp_path: Path, visibility: str, private: bool
) -> None:
    """`private` decides whether a public docs surface may show this repository at all.

    So it fails closed: `internal`, an event with no repository object, and a typo are all
    private. The other direction publishes an internal runbook on a typo.
    """
    document = _index(repo, tmp_path, "--visibility", visibility)
    assert document["private"] is private


def test_the_index_meets_the_readers_contract(repo: Path, tmp_path: Path) -> None:
    """The fields the MagmaMoose/mcp reader requires, with the types it requires.

    Mirrors that repository's schema/index.schema.json rather than vendoring it, and exists
    because drift here fails nowhere: the reader treats a missing `docs` as no documents and
    a missing `private` as private, so every surface would quietly serve nothing.
    """
    document = _index(repo, tmp_path, "--visibility", "public")
    assert document["schema"] == 1
    assert isinstance(document["repo"], str) and document["repo"] == "tremvok"
    assert document["private"] is False
    assert isinstance(document["docs"], list) and document["docs"]
    for doc in document["docs"]:
        assert isinstance(doc["path"], str) and doc["path"] and not doc["path"].startswith("/")
        assert isinstance(doc["text"], str) and doc["text"]
        assert isinstance(doc["title"], str)
        assert isinstance(doc["bytes"], int) and doc["bytes"] >= 0
        assert doc["url"].startswith("https://")
        assert "github.com" not in doc["url"]


# --------------------------------------------------------------------------- markdown twins


@pytest.mark.parametrize(
    ("url_path", "twin"),
    [
        ("", "index.md"),
        ("setup/", "setup/index.md"),
        ("adr/0005/", "adr/0005/index.md"),
        ("setup.html", "setup.md"),
        ("index.html", "index.md"),
        # A build's dest_uri names the same file as the URL it is served at.
        ("setup/index.html", "setup/index.md"),
    ],
)
def test_the_twin_sits_where_llmstxt_org_puts_it(url_path: str, twin: str) -> None:
    """The page's URL with `.md` for the extension, and `index.md` for a URL with no file name.

    The docs router answers `Accept: text/markdown` by fetching `<path>index.md`, so this is
    also the path it expects, not only the spec's.
    """
    assert markdown_twin(url_path) == twin


def test_llms_txt_links_the_markdown_twin_where_the_site_has_one(
    repo: Path, tmp_path: Path
) -> None:
    """llmstxt.org asks for links to "LLM-friendly content, such as the markdown versions".

    Detected from the built site like every other URL here: a page with a twin is listed by
    it, a page without one keeps its HTML address, and a site built without the page-SEO step
    has exactly the llms.txt it had before.
    """
    site = build_site(repo)
    (site / "setup" / "index.md").write_text("# Setting Tremvok up\n", encoding="utf-8")
    assert main(["--root", str(repo), "--repo", "tremvok", "--index-out", str(tmp_path / "o")]) == 0

    llms = (site / "llms.txt").read_text(encoding="utf-8")
    assert f"[Setting Tremvok up]({SITE_URL}setup/index.md)" in llms
    assert f"[Tremvok]({SITE_URL})" in llms
    assert "Each link is the page's markdown" in llms

    # The corpus keeps citing the page, never its markdown copy.
    document = json.loads((tmp_path / "o" / "index" / "tremvok.json").read_text(encoding="utf-8"))
    assert {doc["url"] for doc in document["docs"]} == {SITE_URL, f"{SITE_URL}setup/"}


def test_llms_txt_is_unchanged_on_a_site_with_no_twins(repo: Path, tmp_path: Path) -> None:
    site = build_site(repo)
    assert main(["--root", str(repo), "--repo", "tremvok", "--index-out", str(tmp_path / "o")]) == 0
    llms = (site / "llms.txt").read_text(encoding="utf-8")
    assert "index.md" not in llms
    assert "Each link is the page's markdown" not in llms


def test_a_flat_url_site_links_the_twin_beside_the_page(repo: Path, tmp_path: Path) -> None:
    """`use_directory_urls: false` renders setup.md to setup.html, and its twin is setup.md."""
    site = build_site(repo, directory_urls=False)
    (site / "setup.md").write_text("# Setting Tremvok up\n", encoding="utf-8")
    assert main(["--root", str(repo), "--repo", "tremvok", "--index-out", str(tmp_path / "o")]) == 0
    assert f"({SITE_URL}setup.md)" in (site / "llms.txt").read_text(encoding="utf-8")
