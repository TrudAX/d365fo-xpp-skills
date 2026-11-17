# Notes

General notes and background material on D365FO development with Claude: ideas, research, drafts, and links. They aren't necessarily about the plugin.

- [d365mcp-proxy](d365mcp-proxy/README.md): local proxy that gives Claude Code access to the D365 ERP MCP server of a cloud environment with an app-only (client credentials) Entra app.
- [d365mcp-local-vhd](d365mcp-local-vhd/README.md): enable the built-in D365 ERP MCP server (`/mcp`) on a local VHD or cloud-hosted Tier1 (AOS in IIS) and call it from Claude through the signed-in browser session (or, on a CHE, an Azure CLI token), without an Entra app. Includes the flights that unhide the data and API tools on older platform builds, and Azure CLI setup tips for a CHE.
- [optimize-post-compile-refresh](optimize-post-compile-refresh/README.md): four settings on a development VM that shorten the wait between a build and seeing the change in the browser (OData metadata build at AOS start, Defender rules, two `web.config` keys, two services), with measurements.
- [xpp-html-extensible-controls](xpp-html-extensible-controls/README.md): put HTML, CSS and JavaScript into an X++ form with an extensible control and connect it to X++ in both directions: templates, rules, deployment, troubleshooting and testing.

This folder isn't part of the `trud-d365fo-xpp` plugin:

- **Not installed.** People who install the plugin get only `plugins/trud-d365fo-xpp/`.
- **Not reviewed.** A commit that changes only files here doesn't create a new Claude directory version and doesn't go through review.
- **Never referenced from the plugin.** Skills, scripts, and the plugin README must not link to or read files in `notes/`. If a note becomes something a skill needs, move that content into the skill's `references/` folder.

Rules, because the repository is public:

- **No sensitive content:** no client or company names, client code, ticket numbers, internal URLs, credentials, or personal data.
- **File names valid on Windows and macOS:** no `:`, no trailing dot or space, and no names that differ only by capitalization. An invalid name anywhere in the repo stops the directory from validating the plugin.
- **Plain files:** use Markdown or plain text where possible and keep large binaries out. The whole repository must stay under the directory's size limits (50 MiB archived, fewer than 10,000 files). Don't use Git LFS.
