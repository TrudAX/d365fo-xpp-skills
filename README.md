# D365FO X++ skills for Claude

A Claude plugin marketplace for Microsoft Dynamics 365 Finance and Operations (D365FO) development. It currently has one plugin, **`trud-d365fo-xpp`**. More X++ development skills will be added to it over time.

| Plugin | Skills | What it does |
|---|---|---|
| [`trud-d365fo-xpp`](plugins/trud-d365fo-xpp) | `d365-xpp-compile` | Before Claude changes X++ elements, it sets up the task's Visual Studio project and git branch; afterwards it adds the elements to the project, compiles it with `xppc` (including a check for XML the compiler silently ignores), and analyses and fixes the compile errors. |
| | `d365-xpp-xref` | Answers "where is this used?" (callers, field usages, subclasses, overrides, existing `[ExtensionOf]` classes) by querying the local cross-reference database `DYNAMICSXREFDB`, instead of searching source files. |
| | `d365-xpp-trace-parser` | Reads a trace imported into a Trace Parser database: which SQL statement wrote a value and with which bind values, the X++ call stack of any statement, and which methods ran in what order, so Claude can link the trace to the X++ code. |
| | `d365-xpp-conventions` | When Claude creates tables, fields, forms, RunBase classes, extensions, menu items or privileges, it applies the defaults of the TRUDUtils add-in (audit fields, keys, field groups, EDTs and relations, form patterns, naming) and checks forms against their pattern with the platform's pattern engine. |

## Install in Claude Code

In Claude Code 2.1.275 or later:

```
/plugin install trud-d365fo-xpp --marketplace TrudAX/d365fo-xpp-skills
```

In older versions, add the marketplace first:

```
/plugin marketplace add TrudAX/d365fo-xpp-skills
/plugin install trud-d365fo-xpp@trudax-d365fo
```

The compile skill then runs automatically after X++ changes, the conventions skill when Claude creates elements, the cross-reference skill when you ask where an element is used, and the trace skill when you ask Claude to read an imported trace. You can also invoke them directly as `/trud-d365fo-xpp:d365-xpp-compile`, `/trud-d365fo-xpp:d365-xpp-conventions`, `/trud-d365fo-xpp:d365-xpp-xref` and `/trud-d365fo-xpp:d365-xpp-trace-parser`.

To get new versions, run `/plugin marketplace update trudax-d365fo`, then update the plugin from `/plugin`. From a terminal, run `claude plugin marketplace update trudax-d365fo`, then `claude plugin update trud-d365fo-xpp@trudax-d365fo`.

## Requirements

A Windows D365FO development VM (with `AosService\PackagesLocalDirectory\bin\xppc.exe`) and Windows PowerShell 5.1. The cross-reference skill also needs read access to the `DYNAMICSXREFDB` database on the VM's SQL Server, and the trace skill read access to the Trace Parser database the trace was imported into. The plugin's [README](plugins/trud-d365fo-xpp/README.md) describes exactly what the scripts run, write, and change.

## Repository layout

```
.claude-plugin/marketplace.json           marketplace catalog
plugins/trud-d365fo-xpp/                  the plugin
  .claude-plugin/plugin.json              plugin manifest
  skills/d365-xpp-compile/SKILL.md        skill instructions
  skills/d365-xpp-compile/scripts/        PowerShell scripts the skill runs
  skills/d365-xpp-compile/references/     compile error reference
  skills/d365-xpp-xref/                   cross-reference skill and its query script
  skills/d365-xpp-trace-parser/           trace skill, its query scripts, and a schema reference
  skills/d365-xpp-conventions/            element conventions, form/RunBase references, form pattern script
notes/                                    general notes, not part of the plugin
```

## Adding skills

See [CONTRIBUTING.md](CONTRIBUTING.md). It covers the skill folder and `SKILL.md` template, rules for scripts (including what trips the Claude directory's security scan), keeping client details out of this public repo, which READMEs to update, the version bump, validation, and how a push becomes a new directory version. [CLAUDE.md](CLAUDE.md) points Claude Code sessions in this repo at the same rules.

## License

MIT. See [LICENSE](LICENSE).
