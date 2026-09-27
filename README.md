# D365FO X++ skills for Claude

A Claude plugin marketplace for Microsoft Dynamics 365 Finance and Operations (D365FO) development. It currently has one plugin, **`trud-d365fo-xpp`**. More X++ development skills will be added to it over time.

| Plugin | Skills | What it does |
|---|---|---|
| [`trud-d365fo-xpp`](plugins/trud-d365fo-xpp) | `d365-xpp-compile` | After Claude changes X++ elements, it adds them to the Visual Studio project, compiles the project with `xppc`, and analyses and fixes the compile errors. |

## Install in Claude Code

```
/plugin marketplace add TrudAX/d365fo-xpp-skills
/plugin install trud-d365fo-xpp@trudax-d365fo
```

The skill then runs automatically after X++ changes. You can also invoke it directly as `/trud-d365fo-xpp:d365-xpp-compile`.

To get new versions, run `/plugin marketplace update trudax-d365fo`, then update the plugin from `/plugin`. From a terminal, run `claude plugin marketplace update trudax-d365fo`, then `claude plugin update trud-d365fo-xpp@trudax-d365fo`.

## Requirements

A Windows D365FO development VM (with `AosService\PackagesLocalDirectory\bin\xppc.exe`) and Windows PowerShell 5.1. The plugin's [README](plugins/trud-d365fo-xpp/README.md) describes exactly what the scripts run, write, and change.

## Repository layout

```
.claude-plugin/marketplace.json           marketplace catalog
plugins/trud-d365fo-xpp/                  the plugin
  .claude-plugin/plugin.json              plugin manifest
  skills/d365-xpp-compile/SKILL.md        skill instructions
  skills/d365-xpp-compile/scripts/        PowerShell scripts the skill runs
  skills/d365-xpp-compile/references/     compile error reference
```

## Adding skills

See [CONTRIBUTING.md](CONTRIBUTING.md). It covers the skill folder and `SKILL.md` template, rules for scripts (including what trips the Claude directory's security scan), keeping client details out of this public repo, which READMEs to update, the version bump, validation, and how a push becomes a new directory version. [CLAUDE.md](CLAUDE.md) points Claude Code sessions in this repo at the same rules.

## License

MIT. See [LICENSE](LICENSE).
