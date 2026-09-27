# Adding and changing skills

This repo is a Claude plugin marketplace (`trudax-d365fo`) with one plugin, `trud-d365fo-xpp`, that's listed in the Claude directory. Every push to `main` becomes a new directory version, and people who installed the plugin receive it. Follow the checklist below for every new skill or change.

## Where things go

```
.claude-plugin/marketplace.json                 marketplace catalog (one entry per plugin)
plugins/trud-d365fo-xpp/                        the plugin folder: the only part people install
  .claude-plugin/plugin.json                    manifest: name (never change it), version, description, links
  .claude-plugin/icon.svg                       directory icon
  README.md                                     directory listing text: skills, what the plugin runs, privacy
  LICENSE
  skills/<skill-name>/SKILL.md                  one folder per skill
  skills/<skill-name>/scripts/                  scripts the skill tells Claude to run (optional)
  skills/<skill-name>/references/               extra docs Claude reads on demand (optional)
README.md, CONTRIBUTING.md, CLAUDE.md, LICENSE  repo docs (not installed)
notes/                                          general notes (not installed, not reviewed, still public)
```

Everything a skill uses must be inside `plugins/trud-d365fo-xpp/`. Only that folder is installed.

`notes/` holds general notes that aren't part of the plugin. Commits that change only `notes/` or other files outside the plugin folder don't create a directory version or a review. Never reference `notes/` from the plugin, and follow the rules in [notes/README.md](notes/README.md): the repo is public.

## Checklist for a new skill

1. **Create `plugins/trud-d365fo-xpp/skills/<skill-name>/SKILL.md`.**
   - Use kebab-case for the name and follow the existing pattern, `d365-xpp-<topic>`.
   - Start from the template below. Anthropic's `skill-creator` skill can help draft and test it.
2. **Write the description as the situations that should trigger the skill,** not as a summary of the file. Claude decides when to load a skill from its description alone.
3. **Keep the `SKILL.md` body under about 500 lines.** Move long material into `references/*.md` and say in `SKILL.md` when to read each file.
4. **Add scripts only for deterministic, repeated work,** and follow [Script rules](#script-rules). In `SKILL.md`, refer to them as `<skill-dir>\scripts\<Script>.ps1`. Claude receives the skill's real base directory when the skill loads.
5. **Keep client details out.** This repo is public: no client or company names, model or package names, ticket numbers, server names, drive paths, or URLs from real projects. Use neutral examples such as `ContosoCustomizations`, `ABC123_Feature`, the `ABC` prefix, and `C:\Repos\Contoso\...`.
6. **Update the docs:**
   - `plugins/trud-d365fo-xpp/README.md`: add the skill under **Skills**. Extend **What the plugin runs and changes** and **Privacy** if the skill runs, writes, deletes, or reads anything new. The directory's security scan compares the plugin's behaviour with this README, and anything undisclosed can fail the version.
   - Root `README.md`: add the skill to the table.
   - `plugin.json` `description` and the marketplace entry `description`: update them if the plugin's scope changed.
7. **Raise `version` in `plugin.json`.** Installed copies stay on the version they have until this number changes. Use semantic versioning: a new skill raises the minor number (`0.1.0` → `0.2.0`), and a fix raises the patch number (`0.2.0` → `0.2.1`).
8. **Validate and test** (see [Validate and test](#validate-and-test)).
9. **Commit and push to `main`,** then follow [Release](#release).

### `SKILL.md` template

```markdown
---
name: d365-xpp-<topic>
description: <What it does, in one sentence.> Use this when <the situations: what the user asks or what Claude just did, the D365FO element types or file names involved, phrases the user might type>.
---

# <Title>

<Why the skill exists and how it works, in a few lines. Explain reasons, not only rules: Claude follows instructions better when it understands them.>

## Steps

1. ...

## Scripts

`<skill-dir>\scripts\<Script>.ps1 -Param <value>`: what it does, what it prints, and its exit codes.

## Gotchas

- ...
```

## Script rules

The scripts run on the user's D365FO development VM in **Windows PowerShell 5.1**.

- **Language:** PowerShell 5.1 syntax only: no `?:`, `??`, `?.`, or `&&`/`||` pipeline chains.
- **Encoding:** keep `.ps1` files ASCII-only. PowerShell 5.1 reads files without a BOM as ANSI, so non-ASCII characters break. `.gitattributes` checks `.ps1` files out with CRLF.
- **Output:** print a short, structured report that Claude can act on, and return meaningful exit codes (for example 0 = OK, 1 = problems found, 2 = setup failure). Don't make Claude read raw logs.
- **Local only:** no network calls, telemetry, downloads, package installs (`npm`, `pip`, `Install-Module`), admin rights, or service restarts. Write scratch output under `%TEMP%`, never into `PackagesLocalDirectory\<Package>\bin`.
- **Shared code:** keep each skill self-contained. If several skills need the same helper, the whole plugin folder is installed, so a script can dot-source another skill's file with a path relative to `$PSScriptRoot`. Say so in both skills.
- **What the directory scan flags:** it's a static heuristic, and it flagged harmless code in this repo as "Uses a credential from the user's machine". Avoid combining these in one script file:
  - an environment-variable read in `${env:NAME}` form (use `[Environment]::GetFolderPath(...)` or `$env:NAME` for plain folder settings);
  - a literal `http://` or `https://` URL, including XML namespace URIs (take them from a shared constant, as `XppCommon.ps1` does with the MSBuild namespace);
  - MSBuild `$(Property)` text (build it from placeholders, as `Add-XppProjectItem.ps1` does).
- **Files:** only readable text source and plain images. No compiled, packed, or minified code, no binaries (`.exe`, `.dll`, `.zip`, `.ico`, `.pdf`), and no symlinks. Keep each file under 256 KiB and the plugin under 512 files. Use file names that are valid on both Windows and macOS.

## Validate and test

Run these from the repo root. If the `claude` command isn't on your PATH, use the `claude.exe` bundled with the Claude desktop app.

```bash
claude plugin validate ./plugins/trud-d365fo-xpp
```

```bash
claude plugin validate .
```

Both must print `Validation passed`.

Try the plugin from your working copy before pushing:

```bash
claude --plugin-dir ./plugins/trud-d365fo-xpp
```

In that session, check that the new skill is listed and triggers on a realistic request. Run its scripts on a D365FO VM against a real project; for error paths, use a throwaway element and remove it afterwards.

## Release

1. **Push to `main`.** A GitHub webhook notifies the Claude directory within minutes, and the directory scans the new commit.
2. **Check the result** in the developer portal at claude.ai/directory/manage, on the plugin's **Versions** tab.
   - **Passes:** the version is published, either automatically with auto-publish or when you select **Publish**. A version can also be held for an Anthropic reviewer.
   - **Doesn't pass:** fix the problem, push again, and select **Check for new commits**.
3. **Update your own installed copy:**

```bash
claude plugin marketplace update trudax-d365fo
```

```bash
claude plugin update trud-d365fo-xpp@trudax-d365fo
```

## Adding a second plugin

Most new D365FO skills belong in `trud-d365fo-xpp`. Create a separate plugin only for a clearly different audience or install choice.

1. Create `plugins/<plugin-name>/` with the same layout, including its own `README.md` (at least 40 words, with the run, change, and privacy disclosures) and `LICENSE`.
2. Add an entry to `.claude-plugin/marketplace.json` whose `name` equals the plugin's `plugin.json` name.
3. Submit it in the developer portal as its own **Plugin bundle**. Each plugin folder is a separate directory listing.
4. Choose the plugin name carefully: it's permanent once people install it. Change only `displayName` after release.
