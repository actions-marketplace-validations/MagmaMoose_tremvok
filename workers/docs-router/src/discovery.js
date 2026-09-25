/**
 * What an agent can learn about the fleet's documentation before it connects to anything.
 *
 * The docs are searchable over MCP at mcp.magmamoose.com, but a client only finds that
 * endpoint if something points at it. These documents are the pointers, at the addresses a
 * registry crawling domains, an IDE pointed at docs.magmamoose.com, or a scanner such as
 * isitagentready.com (the one behind Cloudflare's Agent Readiness page) looks for them:
 *
 *   GET /.well-known/ai-catalog.json   an AI Catalog listing the MCP server's card
 *   GET /.well-known/api-catalog       the same pointer as an RFC 9727 linkset
 *   GET /.well-known/mcp/server-card.json
 *                                      a 302 to the card itself: the per-domain path from the
 *                                      Server Card extension's first draft, which scanners
 *                                      still probe
 *
 * THE CARD IS NOT SERVED HERE. It lives at mcp.magmamoose.com/server-card, beside the server
 * it describes (MagmaMoose/mcp), because the card's one consistency rule is that it agrees
 * with what the server answers once connected, and only that Worker knows that. This host
 * points at it and restates nothing it could contradict: no version, no tool list.
 *
 * NOTHING HERE IS DERIVED FROM THE ROUTE TABLE, so nothing here can name a private site. The
 * MCP server behind the card serves only public repositories' documents, and the queries
 * below are about public tools.
 *
 * Specs: github.com/Agent-Card/ai-catalog (specification/ai-catalog.md);
 * agenticresourcediscovery.org for `representativeQueries`; the MCP Server Card extension
 * (SEP-2127); RFC 9727 (api-catalog) and RFC 9264 (linkset).
 */

import { ORIGIN } from "./sites.js";

export const MCP_ENDPOINT = "https://mcp.magmamoose.com/";
export const SERVER_CARD_URL = `${MCP_ENDPOINT}server-card`;

export const AI_CATALOG_PATH = "/.well-known/ai-catalog.json";
export const API_CATALOG_PATH = "/.well-known/api-catalog";
export const LEGACY_SERVER_CARD_PATH = "/.well-known/mcp/server-card.json";

export const SERVER_CARD_TYPE = "application/mcp-server-card+json";
export const AI_CATALOG_TYPE = "application/ai-catalog+json";
export const API_CATALOG_TYPE =
  'application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"';

/**
 * At most 100 characters, the Server Card schema's limit for its own description, so a
 * consumer comparing the two sees the same kind of sentence.
 */
const DESCRIPTION =
  "Search and read the public docs for Magma Moose's open-source developer tools. Read-only.";

/**
 * The Link header on the landing page, so an agent that reads headers before bodies finds
 * all of it. `describedby` names llms.txt as the description of the site for a machine.
 *
 * `base` makes the targets absolute. The redirect at `/` needs that (root.js): it points at
 * another host, and a client that carries the header across the hop must not resolve these
 * against the page it lands on.
 */
export function discoveryLinks(base = "") {
  return [
    `<${base}${API_CATALOG_PATH}>; rel="api-catalog"`,
    `<${base}${AI_CATALOG_PATH}>; rel="ai-catalog"; type="${AI_CATALOG_TYPE}"`,
    `<${base}/llms.txt>; rel="describedby"; type="text/plain"`,
  ].join(", ");
}

export const DISCOVERY_LINKS = discoveryLinks();

/**
 * The AI Catalog. `displayName` and `description` restate the card's, which the catalog spec
 * says to omit and ARD's validator asks for.
 *
 * THE SAME ENTRY MagmaMoose/mcp PUBLISHES at mcp.magmamoose.com/.well-known/ai-catalog.json,
 * field for field, host included: two hosts describing one server must not describe it two
 * ways, or a registry that crawls both holds two records that disagree. Change it there and
 * here together; the test pins this copy.
 */
export function aiCatalog() {
  return {
    specVersion: "1.0",
    host: {
      displayName: "Magma Moose",
      identifier: "magmamoose.com",
      documentationUrl: `${ORIGIN}/`,
      logoUrl: "https://www.magmamoose.com/assets/apple-touch-icon.png",
    },
    entries: [
      {
        identifier: "urn:air:magmamoose.com:mcp:docs",
        displayName: "Magma Moose documentation",
        type: SERVER_CARD_TYPE,
        url: SERVER_CARD_URL,
        description: DESCRIPTION,
        tags: ["documentation", "github-actions", "ci-cd", "deployment", "security"],
        representativeQueries: [
          "How do I gate a pull request on the coverage of the lines it changed with Brimyr?",
          "How does Chargate fail a pull request only on the security findings it introduces?",
          "How do I publish MkDocs documentation to Cloudflare Workers with Tremvok?",
          "How does Diatreme version a release and promote a container image?",
          "Which Magma Moose GitHub Action already does a CI step I need, and what does it not cover?",
        ],
      },
    ],
  };
}

/**
 * RFC 9727: the catalog lists the API as an `item` (which the RFC requires), then says where
 * its machine-readable description (the card) and its human documentation (this host) are.
 */
export function apiCatalog() {
  return {
    linkset: [
      {
        anchor: `${ORIGIN}${API_CATALOG_PATH}`,
        item: [
          {
            href: MCP_ENDPOINT,
            title: "Magma Moose documentation: a public, read-only MCP server",
          },
        ],
      },
      {
        anchor: MCP_ENDPOINT,
        "service-desc": [{ href: SERVER_CARD_URL, type: SERVER_CARD_TYPE }],
        "service-doc": [{ href: `${ORIGIN}/`, type: "text/html" }],
      },
    ],
  };
}
