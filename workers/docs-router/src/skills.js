/**
 * Agent Skills at the host root: `/.well-known/agent-skills/index.json`, and the host's own skill.
 *
 * The Agent Skills Discovery RFC (v0.2.0, github.com/cloudflare/agent-skills-discovery-rfc) has a
 * client read ONE index, at the root of a host. Every site here builds its own, under its own
 * path: tremvok's docs step writes `/<repo>/.well-known/agent-skills/index.json` and a SKILL.md
 * describing the site. Nothing would ever find those. So the router serves the root index: the
 * host's own skill first, then every listed site's skills, read from that site's index over the
 * service binding and re-addressed from the root (`/<repo>/.well-known/agent-skills/...`).
 *
 * THE DIGESTS ARE THE SITES' OWN. The build computed each from the exact bytes it wrote, and the
 * router hands a site's files through with their bodies untouched (headers.js changes headers
 * and nothing else), so a site's digest is the digest of what this host serves. Recomputing it
 * here would cost a second binding call per site on every cache miss to learn the same thing.
 * What the router does check is the shape, so a malformed entry is dropped rather than repeated
 * to every client: a valid name, a known type, a description, a `sha256:` digest, and a URL that
 * stays inside that site's own path.
 *
 * THE HOST SKILL IS BUILT FROM THE ROUTE TABLE AND NOTHING ELSE. Its digest is computed per
 * request from the text served, and every isolate has to compute the same one: a client that
 * read the index from one isolate and the file from another rejects a mismatch. The titles and
 * summaries in each site's llms.txt are cached per isolate and can disagree between isolates for
 * minutes after a site renames itself; the bindings cannot, within a deployment. So the host
 * skill names each site by its repository and leaves the summaries to /llms.txt.
 *
 * A PRIVATE SITE IS NEVER READ, for the reason sites.js gives: a service binding call does not
 * pass through Access. The caller hands in `listedRepos(env)`, the one place that decides.
 */

import { MCP_ENDPOINT, SERVER_CARD_URL } from "./discovery.js";
import {
  DESCRIBED_TTL_MS,
  LOOKUP_TIMEOUT_MS,
  MAX_LOOKUPS_PER_REQUEST,
  ORIGIN,
  RETRY_TTL_MS,
  bindingNameFor,
  readUpTo,
  siteUrl,
} from "./sites.js";

/** An opaque identifier the RFC's clients match exactly. */
export const SKILLS_SCHEMA = "https://schemas.agentskills.io/discovery/0.2.0/schema.json";
export const SKILLS_PREFIX = "/.well-known/agent-skills/";
export const SKILLS_INDEX_PATH = `${SKILLS_PREFIX}index.json`;

export const HOST_SKILL_NAME = "magma-moose-docs";
export const HOST_SKILL_PATH = `${SKILLS_PREFIX}${HOST_SKILL_NAME}/SKILL.md`;

const HOST = ORIGIN.replace("https://", "");

/** Agent Skills names: 1-64 of a-z, 0-9 and single hyphens, never at either end. */
const NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const NAME_MAX = 64;
const DESCRIPTION_MAX = 1024;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const TYPES = new Set(["skill-md", "archive"]);

/** A real index is a few hundred bytes. One that is not is not read to the end. */
const INDEX_MAX_CHARS = 64 * 1024;

/** Lowercase hex SHA-256 of a string's UTF-8 bytes, the form the RFC's digests take. */
export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ── The host's own skill ──────────────────────────────────────────────────────

/** At most 1024 characters, the spec's limit: the list of tools goes first if it must. */
export function hostSkillDescription(repos) {
  const lead = `Find, read and cite the documentation for the open-source developer tools Magma Moose builds, one site per tool on ${HOST}.`;
  const tail = "Use when a task involves one of these tools, or asks which of them already does something.";
  const tools = repos.length > 0 ? ` The tools: ${repos.join(", ")}.` : "";
  const full = `${lead}${tools} ${tail}`;
  return full.length <= DESCRIPTION_MAX ? full : `${lead} ${tail}`;
}

/**
 * The host's SKILL.md. Deterministic for a given deployment: the route table and
 * `landingTools`, which is false while LANDING_REDIRECT sends a browser at the root elsewhere,
 * where this page's WebMCP tools are not. See the module comment.
 */
export function renderHostSkill(repos, { landingTools = true } = {}) {
  const sites = repos.length
    ? repos.map((repo) => `- [${repo}](${siteUrl(repo)})`)
    : ["No documentation sites are published yet."];
  return [
    "---",
    `name: ${HOST_SKILL_NAME}`,
    // JSON's string syntax is YAML's double-quoted scalar, escapes included.
    `description: ${JSON.stringify(hostSkillDescription(repos))}`,
    "---",
    "",
    "# Magma Moose documentation",
    "",
    `${HOST} publishes the documentation for the open-source developer tools Magma Moose builds, one site per tool at \`${ORIGIN}/<tool>/\`:`,
    "",
    ...sites,
    "",
    "## Read it",
    "",
    `1. [llms.txt](${ORIGIN}/llms.txt) names every site with a one-line summary.`,
    `2. Each site publishes its own \`llms.txt\`, every page on one line with a summary, and \`llms-full.txt\`, every page's markdown in one file: \`${ORIGIN}/<tool>/llms.txt\`.`,
    "3. A page's markdown is its URL followed by `index.md`, wherever its site publishes one, and the page URL asked for with `Accept: text/markdown` answers with that markdown.",
    `4. Each site publishes a skill of its own, and [the index](${ORIGIN}${SKILLS_INDEX_PATH}) lists them beside this one.`,
    `5. The public sites are also searchable over MCP at ${MCP_ENDPOINT}, and [its server card](${SERVER_CARD_URL}) says how to connect.`,
    ...(landingTools
      ? ["6. In a browser with WebMCP, the landing page registers `list_docs_sites`, `search_docs`, `read_page` and `open_site`."]
      : []),
    "",
    "## Cite it",
    "",
    `Cite the page, \`${ORIGIN}/<tool>/<page>/\`, not its markdown copy. Each markdown copy names its page on the line under its title.`,
    "",
  ].join("\n");
}

// ── Each site's skills ────────────────────────────────────────────────────────

/**
 * The valid entries of one site's index, addressed from the host root, or [] when there are
 * none. `text` is the body of `/<repo>/.well-known/agent-skills/index.json`.
 */
export function siteSkills(text, repo) {
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    return [];
  }
  if (!data || data.$schema !== SKILLS_SCHEMA || !Array.isArray(data.skills)) return [];
  // URLs resolve against the index's own URL (RFC 3986), which is where the site serves it.
  const base = `${siteUrl(repo)}.well-known/agent-skills/index.json`;
  const inside = `/${repo}/`;
  const found = [];
  for (const skill of data.skills) {
    if (!skill || typeof skill !== "object") continue;
    const { name, type, description, url, digest } = skill;
    if (typeof name !== "string" || name.length > NAME_MAX || !NAME.test(name)) continue;
    if (!TYPES.has(type)) continue;
    if (typeof description !== "string" || !description.trim() || description.length > DESCRIPTION_MAX) continue;
    if (typeof digest !== "string" || !DIGEST.test(digest)) continue;
    if (typeof url !== "string" || !url) continue;
    let resolved;
    try {
      resolved = new URL(url, base);
    } catch {
      continue;
    }
    // Only a file the site itself serves. The root index vouches for what it lists, and a site
    // pointing it at another site's path, or another host, is not the site's to do.
    if (resolved.origin !== ORIGIN || !resolved.pathname.startsWith(inside) || resolved.search) continue;
    found.push({ name, type, description, url: resolved.pathname, digest });
  }
  return found;
}

async function readSkills(service, repo, origin, timeoutMs) {
  try {
    const init = { headers: { accept: "application/json" } };
    if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
      init.signal = AbortSignal.timeout(timeoutMs);
    }
    const response = await service.fetch(new Request(new URL(SKILLS_INDEX_PATH, origin), init));
    if (!response.ok) {
      await response.body?.cancel();
      // A 404 is an answer: the site was built before it published skills. Anything else is a
      // failure worth retrying soon.
      return { skills: [], definitive: response.status === 404 };
    }
    const { text, complete } = await readUpTo(response, INDEX_MAX_CHARS);
    return { skills: complete ? siteSkills(text, repo) : [], definitive: true };
  } catch {
    return { skills: [], definitive: false };
  }
}

// Cached per isolate on exactly the terms sites.js explains for llms.txt: resolved values only,
// five minutes for an answer, thirty seconds after a failure, the last good answer kept through
// one, and at most MAX_LOOKUPS_PER_REQUEST binding calls in a request.
const memo = new Map();

/** Forget every cached index. For tests. */
export function forgetSkills() {
  memo.clear();
}

/** Each repo's skills, in order. Never rejects. */
export async function skillsOf(env, repos, origin, { timeoutMs = LOOKUP_TIMEOUT_MS } = {}) {
  const now = Date.now();
  let budget = MAX_LOOKUPS_PER_REQUEST;
  return Promise.all(
    repos.map(async (repo) => {
      const hit = memo.get(repo);
      if (hit && hit.expires > now) return hit.skills;
      if (budget === 0) return hit ? hit.skills : [];
      budget -= 1;
      const fresh = await readSkills(env[bindingNameFor(repo)], repo, origin, timeoutMs);
      const skills = fresh.definitive || !hit ? fresh.skills : hit.skills;
      memo.set(repo, { skills, expires: Date.now() + (fresh.definitive ? DESCRIBED_TTL_MS : RETRY_TTL_MS) });
      return skills;
    }),
  );
}

/**
 * The root index: the host's skill, then every site's, a name listed once. The first site to
 * claim a name keeps it (repositories are in order), because a client installs skills by name
 * and two under one name would overwrite each other.
 */
export async function renderSkillsIndex(env, repos, origin, { landingTools = true } = {}) {
  const entries = [
    {
      name: HOST_SKILL_NAME,
      type: "skill-md",
      description: hostSkillDescription(repos),
      url: HOST_SKILL_PATH,
      digest: `sha256:${await sha256Hex(renderHostSkill(repos, { landingTools }))}`,
    },
  ];
  const taken = new Set([HOST_SKILL_NAME]);
  for (const skills of await skillsOf(env, repos, origin)) {
    for (const skill of skills) {
      if (taken.has(skill.name)) continue;
      taken.add(skill.name);
      entries.push(skill);
    }
  }
  return `${JSON.stringify({ $schema: SKILLS_SCHEMA, skills: entries }, null, 2)}\n`;
}
