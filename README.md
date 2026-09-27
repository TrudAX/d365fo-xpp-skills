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

To get new versions, run `/plugin marketplace update trudax-d365fo`.

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

To add a skill, create `plugins/trud-d365fo-xpp/skills/<skill-name>/SKILL.md` and raise `version` in `plugin.json`. Check the plugin with `claude plugin validate ./plugins/trud-d365fo-xpp` and the marketplace with `claude plugin validate .`.

## License

MIT. See [LICENSE](LICENSE).
