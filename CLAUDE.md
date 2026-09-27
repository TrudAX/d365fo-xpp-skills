@CONTRIBUTING.md

# Notes for Claude

- This repo is public and published in the Claude directory. Treat every commit to `main` as a release: people who installed the plugin receive it after the directory scan.
- Follow the checklist in CONTRIBUTING.md for every skill change, including the README disclosures and the `version` bump in `plugins/trud-d365fo-xpp/.claude-plugin/plugin.json`.
- Never copy client names, project paths, ticket numbers, or other client code or data into this repo, even when the skill was developed on a client project. Rewrite examples with neutral names first.
- Before committing, check that the repo-local `git config user.email` is the owner's GitHub no-reply address, not a work email.
- Run both `claude plugin validate` commands before every push.
