"""The agent-readiness step: an Agent Skills index, WebMCP on every page, an auth.md.

Each of these fails where nobody is looking. A digest that is not the digest of the bytes
served makes every client reject the skill; a skill that promises an llms.txt the build never
wrote sends an agent to a 404 first; a script tag written twice registers every tool twice; an
auth.md under a path contradicts the one its host serves. So the end-to-end tests build a real
MkDocs Material site, run the steps in the order action.yml runs them, and read what they wrote.
"""

from __future__ import annotations

import hashlib
import json
import posixpath
import re
import shutil
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest
import yaml
from scripts import gen_docs_agents
from scripts.gen_docs_agents import (
    WEBMCP_ASSET,
    is_skill_name,
    protected_resource_metadata,
    skill_description,
    skill_url,
    slug,
)
from scripts.gen_docs_index import main as index_main
from scripts.gen_docs_seo import main as seo_main

ROOT = Path(__file__).resolve().parents[1]
SITE_URL = "https://docs.example.test/widget/"
MCP = "https://mcp.example.test/"

BASE = f"""\
site_url: {SITE_URL}
theme:
  name: material
markdown_extensions:
  - admonition
  - toc:
      permalink: true
extra:
  agents:
    mcp: {MCP}
"""

CHILD = """\
INHERIT: mkdocs.base.yml
site_name: Widget
site_description: "Widget does one thing well: this site says how."
nav:
  - Home: index.md
  - Setup: setup.md
  - Guides:
      - guides/index.md
      - Deploying: guides/deploy.md
      - Reference: guides/reference.md
"""

PAGES = {
    "index.md": "# Widget\n\nWidget does one thing well, and these pages say how.\n",
    "setup.md": "# Setting Widget up\n\nInstall the widget with one command.\n",
    "guides/index.md": "# Guides\n\nTask-shaped walkthroughs for everyday work.\n",
    "guides/deploy.md": "# Deploying\n\nA deploy is one push to the default branch.\n",
    "guides/reference.md": "# Reference\n\nEvery flag the widget takes.\n",
}

BUILT = ["index.html", "setup/index.html", "guides/index.html", "guides/deploy/index.html"]


def write_repo(root: Path, *, child: str = CHILD, base: str = BASE) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "mkdocs.base.yml").write_text(base, encoding="utf-8")
    (root / "mkdocs.yml").write_text(child, encoding="utf-8")
    for name, body in PAGES.items():
        path = root / "docs" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return root


def mkdocs_build(root: Path) -> None:
    pytest.importorskip("material", reason="mkdocs-material is in the dev dependency group")
    subprocess.run(
        [sys.executable, "-m", "mkdocs", "build", "--strict", "--quiet", "--site-dir", "site"],
        cwd=root,
        check=True,
        capture_output=True,
    )


@pytest.fixture(scope="module")
def built(tmp_path_factory: pytest.TempPathFactory) -> Path:
    root = write_repo(tmp_path_factory.mktemp("widget") / "repo")
    mkdocs_build(root)
    return root


@pytest.fixture
def repo(built: Path, tmp_path: Path) -> Path:
    target = tmp_path / "repo"
    shutil.copytree(built, target)
    return target


def seo(repo: Path) -> None:
    assert seo_main(["--root", str(repo), "--site-dir", "site"]) == 0


def corpus(repo: Path, tmp_path: Path, site_url: str = "") -> None:
    """The corpus step, handed the router address as action.yml hands it: it reads mkdocs.yml
    as plain YAML, so a `site_url` inherited from the base is not one it can see."""
    if not site_url:
        base = yaml.safe_load((repo / "mkdocs.base.yml").read_text(encoding="utf-8"))
        site_url = base.get("site_url") or "https://docs.example.test/widget/"
    args = ["--root", str(repo), "--site-dir", "site", "--repo", "widget", "--site-url", site_url]
    assert index_main([*args, "--index-out", str(tmp_path / "index")]) == 0


def agents(repo: Path, *extra: str) -> int:
    return gen_docs_agents.main(["--root", str(repo), "--site-dir", "site", *extra])


def cloudflare_docs(repo: Path, tmp_path: Path, *extra: str) -> None:
    """The three steps in the order action.yml runs them for `cloudflare-docs`."""
    seo(repo)
    served = extra[extra.index("--site-url") + 1] if "--site-url" in extra else ""
    corpus(repo, tmp_path, served)
    assert agents(repo, *extra) == 0


def index(repo: Path) -> dict:
    return json.loads((repo / "site/.well-known/agent-skills/index.json").read_text("utf-8"))


def skill_file(repo: Path, name: str = "widget") -> Path:
    return repo / "site/.well-known/agent-skills" / name / "SKILL.md"


def front_matter(text: str) -> tuple[dict, str]:
    match = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    assert match, text
    return yaml.safe_load(match.group(1)), match.group(2)


def tree(root: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()
    }


def tags(repo: Path, page: str) -> list[str]:
    document = (repo / "site" / page).read_text(encoding="utf-8")
    return re.findall(r"<script\b[^>]*webmcp\.js[^>]*></script>", document)


def set_site_url(repo: Path, url: str | None) -> None:
    base = BASE if url is None else BASE.replace(SITE_URL, url)
    if url is None:
        base = base.replace(f"site_url: {SITE_URL}\n", "")
    (repo / "mkdocs.base.yml").write_text(base, encoding="utf-8")


# --------------------------------------------------------------------------- the skill


def test_the_index_lists_one_skill_and_its_digest_is_the_bytes_written(
    repo: Path, tmp_path: Path
) -> None:
    """A client verifies the digest before it loads the skill. Wrong, and nothing loads it."""
    cloudflare_docs(repo, tmp_path)
    document = index(repo)
    assert list(document) == ["$schema", "skills"]
    assert document["$schema"] == "https://schemas.agentskills.io/discovery/0.2.0/schema.json"
    [entry] = document["skills"]
    assert entry["name"] == "widget"
    assert entry["type"] == "skill-md"
    assert entry["url"] == "/widget/.well-known/agent-skills/widget/SKILL.md"
    body = skill_file(repo).read_bytes()
    assert entry["digest"] == f"sha256:{hashlib.sha256(body).hexdigest()}"


def test_the_skill_is_agent_skills_front_matter_and_agrees_with_the_index(
    repo: Path, tmp_path: Path
) -> None:
    cloudflare_docs(repo, tmp_path)
    meta, _ = front_matter(skill_file(repo).read_text(encoding="utf-8"))
    [entry] = index(repo)["skills"]
    assert meta["name"] == entry["name"] == skill_file(repo).parent.name
    assert meta["description"] == entry["description"]
    assert 0 < len(meta["description"]) <= 1024
    assert "Widget does one thing well: this site says how." in meta["description"]
    assert "Use when a task involves Widget" in meta["description"]


def test_the_skill_maps_the_site_and_says_how_to_read_and_cite_it(
    repo: Path, tmp_path: Path
) -> None:
    cloudflare_docs(repo, tmp_path)
    _, body = front_matter(skill_file(repo).read_text(encoding="utf-8"))
    for expected in (
        f"It is published at <{SITE_URL}>",
        f"- [Setup]({SITE_URL}setup/)",
        f"- [Guides]({SITE_URL}guides/): Deploying, Reference",
        f"[llms.txt]({SITE_URL}llms.txt)",
        f"[llms-full.txt]({SITE_URL}llms-full.txt)",
        f"{SITE_URL}setup/ has its markdown at {SITE_URL}setup/index.md",
        "`Accept: text/markdown`",
        f"searchable over MCP at <{MCP}>",
        "`search_docs`, `read_page`, `list_pages` and `open_page`",
        "Cite the page URL, not the URL of its markdown copy.",
    ):
        assert expected in body, expected


def test_a_github_pages_build_writes_no_llms_txt_and_the_skill_promises_none(repo: Path) -> None:
    """github-pages runs no corpus step. A skill naming llms.txt would send an agent to a 404."""
    seo(repo)
    assert agents(repo) == 0
    text = skill_file(repo).read_text(encoding="utf-8")
    assert "llms.txt" not in text
    assert "llms-full.txt" not in text
    assert "index.md" in text  # the twins are there, so they are described


def test_without_markdown_twins_the_skill_promises_none(repo: Path) -> None:
    """`pages-seo: false` writes no twins, and a skill must not describe files not there."""
    assert agents(repo) == 0
    text = skill_file(repo).read_text(encoding="utf-8")
    assert "index.md" not in text
    assert "Accept: text/markdown" not in text
    assert "Cite the page URL." in text


def test_the_address_the_site_is_served_at_wins_for_the_skill_url(
    repo: Path, tmp_path: Path
) -> None:
    """The URL in the index is a file a client fetches, so it follows where the file is."""
    cloudflare_docs(repo, tmp_path, "--site-url", "https://router.example.test/moved")
    [entry] = index(repo)["skills"]
    assert entry["url"] == "/moved/.well-known/agent-skills/widget/SKILL.md"
    assert "<https://router.example.test/moved/>" in skill_file(repo).read_text("utf-8")


def test_with_no_address_at_all_every_url_is_relative(repo: Path, capsys) -> None:
    set_site_url(repo, None)
    assert agents(repo) == 0
    [entry] = index(repo)["skills"]
    # Relative to the index, which the RFC resolves against the index's own URL.
    assert entry["url"] == "widget/SKILL.md"
    text = skill_file(repo).read_text(encoding="utf-8")
    assert "- [Setup](../../../setup/)" in text
    # Nothing names a host the site was never given; the MCP server is its own address.
    assert "docs.example.test" not in text
    capsys.readouterr()


def test_a_skill_name_comes_from_site_name_or_extra_agents(repo: Path) -> None:
    base = BASE + "  agents:\n    skill:\n      name: widget-docs\n      description: Mine.\n"
    base = base.replace(f"extra:\n  agents:\n    mcp: {MCP}\n", "extra:\n")
    (repo / "mkdocs.base.yml").write_text(base, encoding="utf-8")
    assert agents(repo) == 0
    [entry] = index(repo)["skills"]
    assert (entry["name"], entry["description"]) == ("widget-docs", "Mine.")
    assert skill_file(repo, "widget-docs").is_file()


# --------------------------------------------------------------------------- WebMCP


def test_every_page_loads_the_script_once_from_a_relative_same_origin_url(
    repo: Path, tmp_path: Path
) -> None:
    """Relative like Material's own asset links, so it resolves wherever the site is mounted,
    and a file on the site itself, so a `script-src 'self'` CSP admits it."""
    cloudflare_docs(repo, tmp_path)
    asset = repo / "site" / WEBMCP_ASSET
    source = (ROOT / "scripts" / "docs_webmcp.js").read_bytes()
    assert asset.read_bytes() == source
    version = hashlib.sha256(source).hexdigest()[:12]
    for page in BUILT:
        [tag] = tags(repo, page)
        src = re.search(r'src="([^"]+)"', tag).group(1)
        path, _, query = src.partition("?")
        assert "://" not in path and not path.startswith("/"), tag
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(page), path))
        assert resolved == WEBMCP_ASSET, (page, src)
        assert query == f"v={version}"
        assert " defer" in tag
        assert 'data-site="Widget"' in tag
        head = (repo / "site" / page).read_text("utf-8").split("</head>")[0]
        assert tag in head, f"{page}: the script is not in the head"
    assert "webmcp" not in (repo / "site" / "404.html").read_text(encoding="utf-8")


def test_the_script_finds_the_site_root_two_directories_above_itself() -> None:
    """The generator puts the file at WEBMCP_ASSET and the script climbs two directories from
    its own URL to find the site. Move one without the other and every tool reads the wrong
    tree, silently."""
    assert WEBMCP_ASSET.count("/") == 2
    assert 'new URL("../../", script.src)' in (ROOT / "scripts/docs_webmcp.js").read_text("utf-8")


def test_a_site_name_is_escaped_into_the_tag(tmp_path: Path) -> None:
    site = tmp_path / "site"
    (site / "a").mkdir(parents=True)
    tag = gen_docs_agents.webmcp_tag(site / "a" / "index.html", site, "v1", 'Widget "&" <co>')
    assert 'data-site="Widget &quot;&amp;&quot; &lt;co&gt;"' in tag
    assert tag.startswith('<script src="../assets/javascripts/webmcp.js?v=v1" defer ')


def test_a_page_with_its_own_webmcp_script_gets_no_second(repo: Path) -> None:
    page = repo / "site" / "setup" / "index.html"
    document = page.read_text(encoding="utf-8")
    page.write_text(document.replace("</head>", '<script src="/js/webmcp.js"></script></head>'))
    assert agents(repo) == 0
    assert tags(repo, "setup/index.html") == ['<script src="/js/webmcp.js"></script>']
    assert len(tags(repo, "guides/index.html")) == 1


def test_a_different_webmcp_js_at_the_same_path_is_the_sites_own(repo: Path) -> None:
    theirs = repo / "site" / WEBMCP_ASSET
    theirs.parent.mkdir(parents=True, exist_ok=True)
    theirs.write_text("/* the site's own */\n", encoding="utf-8")
    assert agents(repo) == 0
    assert theirs.read_text(encoding="utf-8") == "/* the site's own */\n"
    assert all(tags(repo, page) == [] for page in BUILT)


def test_webmcp_false_writes_no_script(repo: Path) -> None:
    (repo / "mkdocs.base.yml").write_text(BASE + "    webmcp: false\n", encoding="utf-8")
    assert agents(repo) == 0
    assert not (repo / "site" / WEBMCP_ASSET).exists()
    assert all(tags(repo, page) == [] for page in BUILT)
    assert "WebMCP" not in skill_file(repo).read_text(encoding="utf-8")


# --------------------------------------------------------------------------- auth.md


def test_a_site_at_the_root_of_its_host_gets_an_honest_auth_md(repo: Path, tmp_path: Path) -> None:
    set_site_url(repo, "https://docs.example.test/")
    cloudflare_docs(repo, tmp_path)
    text = (repo / "site" / "auth.md").read_text(encoding="utf-8")
    heading = text.splitlines()[0]
    assert heading.startswith("# ") and "auth.md" in heading, "the scanner wants it in the H1"
    assert "no registration and no credentials" in text
    assert "`llms.txt`" in text and "/.well-known/agent-skills/index.json" in text
    # The MCP server's access is its own to state, and this file says where it states it.
    assert f"<{MCP}>" in text
    assert "<https://mcp.example.test/.well-known/oauth-protected-resource>" in text
    assert "not this file" in text


def test_a_site_under_a_path_does_not_speak_for_its_host(repo: Path, tmp_path: Path) -> None:
    cloudflare_docs(repo, tmp_path)
    assert not (repo / "site" / "auth.md").exists()


@pytest.mark.parametrize(
    ("site_url", "setting", "written"),
    [
        (SITE_URL, "true", True),
        ("https://docs.example.test/", "false", False),
        ("https://docs.example.test/", "auto", True),
    ],
)
def test_extra_agents_auth_md_overrides_where_the_site_is_served(
    repo: Path, site_url: str, setting: str, written: bool
) -> None:
    base = BASE.replace(SITE_URL, site_url) + f"    auth_md: {setting}\n"
    (repo / "mkdocs.base.yml").write_text(base, encoding="utf-8")
    assert agents(repo) == 0
    assert (repo / "site" / "auth.md").exists() is written


@pytest.mark.parametrize("value", ["true", "True", "1", "on"])
def test_a_site_behind_access_is_never_told_it_needs_no_credentials(repo: Path, value: str) -> None:
    """cloudflare-docs-require-access means nobody reads the site without signing in, so the
    public auth.md would be false there, whatever extra.agents asks for."""
    base = BASE.replace(SITE_URL, "https://docs.example.test/") + "    auth_md: true\n"
    (repo / "mkdocs.base.yml").write_text(base, encoding="utf-8")
    assert agents(repo, "--access-required", value) == 0
    assert not (repo / "site" / "auth.md").exists()
    assert agents(repo, "--access-required", "false") == 0
    assert (repo / "site" / "auth.md").exists()


def test_protected_resource_metadata_follows_rfc_9728() -> None:
    assert protected_resource_metadata("https://mcp.example.test/") == (
        "https://mcp.example.test/.well-known/oauth-protected-resource"
    )
    assert protected_resource_metadata("https://docs.example.test/mcp") == (
        "https://docs.example.test/.well-known/oauth-protected-resource/mcp"
    )
    assert protected_resource_metadata("https://docs.example.test/a/mcp/?x=1") == (
        "https://docs.example.test/.well-known/oauth-protected-resource/a/mcp"
    )


# --------------------------------------------------------------------------- idempotence


def test_a_second_run_changes_nothing(repo: Path, tmp_path: Path) -> None:
    set_site_url(repo, "https://docs.example.test/")
    cloudflare_docs(repo, tmp_path)
    first = tree(repo / "site")
    assert agents(repo) == 0
    assert tree(repo / "site") == first


def test_what_a_site_already_publishes_is_left_alone(repo: Path) -> None:
    """CalebSargeant/docs writes its own catalogs from a hook; any site may write these too."""
    set_site_url(repo, "https://docs.example.test/")
    own = repo / "site" / ".well-known" / "agent-skills"
    own.mkdir(parents=True)
    (own / "index.json").write_text('{"theirs": true}\n', encoding="utf-8")
    (repo / "site" / "auth.md").write_text("# Theirs auth.md\n", encoding="utf-8")
    assert agents(repo) == 0
    assert sorted(p.name for p in own.iterdir()) == ["index.json"]
    assert (own / "index.json").read_text(encoding="utf-8") == '{"theirs": true}\n'
    assert (repo / "site" / "auth.md").read_text(encoding="utf-8") == "# Theirs auth.md\n"


def test_skill_false_writes_no_index(repo: Path) -> None:
    (repo / "mkdocs.base.yml").write_text(BASE + "    skill: false\n", encoding="utf-8")
    assert agents(repo) == 0
    assert not (repo / "site" / ".well-known").exists()


# --------------------------------------------------------------------------- configuration


def test_bad_extra_agents_values_warn_and_fall_back(repo: Path, capsys) -> None:
    base = BASE.replace(f"mcp: {MCP}", "mcp: not-a-url") + (
        "    skill:\n      name: Not A Name\n    webmcp: yes-please\n    auth_md: sometimes\n"
    )
    (repo / "mkdocs.base.yml").write_text(base, encoding="utf-8")
    assert agents(repo) == 0
    err = capsys.readouterr().err
    for fragment in (
        "extra.agents.mcp",
        "extra.agents.skill.name",
        "extra.agents.webmcp",
        "auth_md",
    ):
        assert fragment in err, fragment
    assert index(repo)["skills"][0]["name"] == "widget"
    assert "searchable over MCP" not in skill_file(repo).read_text(encoding="utf-8")
    assert len(tags(repo, "index.html")) == 1


def test_extra_agents_that_is_not_a_mapping_is_ignored(repo: Path, capsys) -> None:
    (repo / "mkdocs.base.yml").write_text(
        BASE.replace(f"  agents:\n    mcp: {MCP}\n", "  agents: nope\n"), encoding="utf-8"
    )
    assert agents(repo) == 0
    assert "extra.agents is not a mapping" in capsys.readouterr().err
    assert index(repo)["skills"][0]["name"] == "widget"


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Widget", "widget"),
        ("Caleb Sargeant\u2019s Docs", "caleb-sargeants-docs"),
        ("Caleb Sargeant's Docs", "caleb-sargeants-docs"),
        ("  --Tr\u00e9mvok  2.0!!", "tremvok-2-0"),
        ("\u2603", ""),
    ],
)
def test_slug(text: str, expected: str) -> None:
    assert slug(text) == expected
    assert expected == "" or is_skill_name(expected)


def test_a_site_named_as_docs_is_not_called_documentation_twice() -> None:
    assert gen_docs_agents.titled("Tremvok") == "Tremvok documentation"
    assert gen_docs_agents.titled("Tremvok", article=True) == "the Tremvok documentation"
    for name in ("Caleb Sargeant\u2019s Docs", "Widget Documentation", "Ops Handbook"):
        assert gen_docs_agents.titled(name) == name
        assert gen_docs_agents.titled(name, article=True) == name


def page(src_uri: str, title: str, trail: list[str]) -> gen_docs_agents.PageInfo:
    url = src_uri.removesuffix("index.md").removesuffix(".md")
    url = url + "/" if url and not url.endswith("/") else url
    return gen_docs_agents.PageInfo(
        src_uri=src_uri,
        url=url,
        dest=Path("site") / url / "index.html",
        twin=Path("site") / url / "index.md",
        twin_url="",
        title=title,
        home=not src_uri or src_uri == "index.md",
        markdown="",
        front_matter_description=False,
        trail=trail,
        crumbs=[],
    )


def test_the_section_map_links_a_section_to_its_index_and_lists_what_is_in_it() -> None:
    site = gen_docs_agents.Site(
        name="Widget",
        description="",
        base="https://d.test/",
        llms_txt=False,
        llms_full_txt=False,
        twins=False,
        flat=False,
        example=None,
        mcp="",
        webmcp=False,
    )
    infos = [
        page("index.md", "Home", []),
        page("platform/index.md", "Platform engineering reference", ["Platform"]),
        page("platform/setup.md", "Setup", ["Platform"]),
        page("platform/runbooks/disk.md", "Disk full", ["Platform", "Runbooks"]),
        page("reference/action.md", "Action", ["Reference"]),
        page("reference/api.md", "API [beta]", ["Reference"]),
        # Built, and left out of the nav: no place at the top of it either.
        replace(page("drafts/notes.md", "Notes", []), in_nav=False),
    ]
    assert gen_docs_agents.section_map(infos, site) == [
        "- [Home](https://d.test/)",
        # Its index page is where the line links, not one of the pages in it.
        "- [Platform](https://d.test/platform/): Setup, Runbooks",
        # No index page: the first page is the link, and still one of the pages.
        "- [Reference](https://d.test/reference/action/): Action, API \\[beta\\]",
    ]


def test_skill_names_follow_the_agent_skills_rules() -> None:
    assert is_skill_name("a") and is_skill_name("pdf-processing") and is_skill_name("x" * 64)
    for bad in ("", "-a", "a-", "a--b", "A", "a_b", "x" * 65):
        assert not is_skill_name(bad), bad


def test_a_long_site_description_still_leaves_a_description_under_1024() -> None:
    text = skill_description("Widget", "word " * 400, "https://x.test/")
    assert len(text) <= 1024
    assert text.endswith("and how to cite it.")


def test_front_matter_survives_quotes_and_colons_in_a_description(tmp_path: Path) -> None:
    child = CHILD.replace(
        'site_description: "Widget does one thing well: this site says how."',
        "site_description: 'He said \"no\": #1 \u2019quoted\u2019 --- ok'",
    )
    root = write_repo(tmp_path / "repo", child=child)
    mkdocs_build(root)
    assert agents(root) == 0
    meta, _ = front_matter(skill_file(root).read_text(encoding="utf-8"))
    assert 'He said "no": #1 \u2019quoted\u2019 --- ok' in meta["description"]


def test_skill_url() -> None:
    assert skill_url("https://d.test/", "x") == "/.well-known/agent-skills/x/SKILL.md"
    assert skill_url("https://d.test/r/", "x") == "/r/.well-known/agent-skills/x/SKILL.md"
    assert skill_url("", "x") == "x/SKILL.md"


def test_a_missing_site_directory_is_a_hard_error(tmp_path: Path, capsys) -> None:
    write_repo(tmp_path / "repo")
    assert agents(tmp_path / "repo") == 1
    assert "no built site" in capsys.readouterr().err


def test_no_config_is_a_hard_error(tmp_path: Path, capsys) -> None:
    (tmp_path / "site").mkdir()
    assert gen_docs_agents.main(["--root", str(tmp_path), "--site-dir", "site"]) == 1
    assert "no mkdocs.yml" in capsys.readouterr().err


# --------------------------------------------------------------------------- the action


def steps() -> list[dict]:
    return yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))["runs"]["steps"]


def test_the_step_runs_after_the_metadata_and_corpus_and_before_anything_publishes() -> None:
    """Before the twins and llms.txt exist, the skill describes a site with neither; after the
    Pages artifact is staged or the Worker deployed, the site goes out without any of it. None
    of those fails when broken."""
    all_steps = steps()
    names = [step.get("name", "") for step in all_steps]
    step = next(i for i, s in enumerate(all_steps) if "gen_docs_agents.py" in str(s.get("env", "")))
    seo_step = next(
        i for i, s in enumerate(all_steps) if "gen_docs_seo.py" in str(s.get("env", ""))
    )
    assert seo_step < step
    assert names.index("Emit the docs corpus") < step
    assert step < names.index("Stage the Pages artifact")
    assert step < names.index("Deploy \u2014 Cloudflare docs")
    condition = all_steps[step]["if"]
    assert "inputs.pages-agent-ready == 'true'" in condition
    assert "github-pages" in condition and "cloudflare-docs" in condition


def test_the_step_is_on_by_default() -> None:
    inputs = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))["inputs"]
    assert inputs["pages-agent-ready"]["default"] == "true"


def test_the_pages_artifact_carries_the_dot_directory_the_index_lives_in() -> None:
    """upload-pages-artifact drops every path that starts with a dot by default, so without
    this the step writes .well-known/agent-skills and GitHub Pages never publishes it."""
    stage = next(s for s in steps() if s.get("name") == "Stage the Pages artifact")
    assert stage["with"]["include-hidden-files"] == "${{ inputs.pages-agent-ready }}"
