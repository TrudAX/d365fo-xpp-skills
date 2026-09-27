# Notes

General notes and background material on D365FO development with Claude: ideas, research, drafts, and links. They aren't necessarily about the plugin.

This folder isn't part of the `trud-d365fo-xpp` plugin:

- **Not installed.** People who install the plugin get only `plugins/trud-d365fo-xpp/`.
- **Not reviewed.** A commit that changes only files here doesn't create a new Claude directory version and doesn't go through review.
- **Never referenced from the plugin.** Skills, scripts, and the plugin README must not link to or read files in `notes/`. If a note becomes something a skill needs, move that content into the skill's `references/` folder.

Rules, because the repository is public:

- **No sensitive content:** no client or company names, client code, ticket numbers, internal URLs, credentials, or personal data.
- **File names valid on Windows and macOS:** no `:`, no trailing dot or space, and no names that differ only by capitalization. An invalid name anywhere in the repo stops the directory from validating the plugin.
- **Plain files:** use Markdown or plain text where possible and keep large binaries out. The whole repository must stay under the directory's size limits (50 MiB archived, fewer than 10,000 files). Don't use Git LFS.
