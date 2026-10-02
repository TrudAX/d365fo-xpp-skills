---
name: d365-xpp-xref
description: Find where a Dynamics 365 Finance & Operations (D365 F&O, AX7) X++ element is used by querying the cross-reference database (DYNAMICSXREFDB) instead of searching source files. Use this when the user asks "where is X used", "who calls method Y", "which classes use SalesLine.SalesPrice", "find references", "find all usages", "what extends/implements class Z", "which methods have attribute A", or wants an impact analysis before changing a table field, method, EDT, enum, or class - especially across large models such as ApplicationSuite, where grepping XML is slow and token-heavy.
---

# D365 X++ cross references

Visual Studio's *Find references* reads the cross-reference database that the X++ compiler fills during a build (`DYNAMICSXREFDB` on the local SQL Server of a development VM). Querying it directly answers "who uses this?" in seconds and in a few lines of output, where searching the XML of a ~19k-table application would take minutes and thousands of tokens. Prefer it to Grep over `PackagesLocalDirectory` for any usage question.

`<skill-dir>\scripts\Find-XppReference.ps1` runs the query and prints a compact tab-separated report. It's read-only and uses Windows authentication.

## Steps

1. **Build the target path** of the element (see [Path format](#path-format)), for example `/Tables/SalesLine/Fields/SalesPrice`.
2. **If you aren't sure of the exact path, look it up** with `-FindPath`. Names in the database don't always match the AOT casing, and a typo returns nothing.
3. **Run the reference query**, filtered as narrowly as the question allows (`-SourceModule`, `-SourceType`, `-Kind`). Start with the default `-GroupBy Object`, which returns one row per referencing element and costs the fewest tokens.
4. **Drill down only if needed:** `-GroupBy Member` for the methods, `-GroupBy None` for every reference with its line and column. Then open just the source files you need.
5. **Report** the list, and say that it reflects the last build that updated cross references (see Gotchas).

## Scripts

Windows PowerShell 5.1. From the PowerShell tool:

```powershell
& "<skill-dir>\scripts\Find-XppReference.ps1" -Target /Tables/SalesLine/Fields/SalesPrice -SourceModule ApplicationSuite -SourceType Classes
```

From Bash, or if the execution policy blocks scripts:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>/scripts/Find-XppReference.ps1" -Target /Tables/SalesLine/Fields/SalesPrice -SourceType Classes
```

| Parameter | Meaning |
|---|---|
| `-Target <path>` | Element to find references **to**. Matched exactly, unless it contains `*` or `%` (wildcards). |
| `-FindPath <pattern>` | Instead of references, list matching element paths and their module, e.g. `'/Tables/SalesLine/Fields/Sales*'`. |
| `-SourceModule <name>` | Only references from code in this module (model), e.g. `ApplicationSuite`, `ContosoCustomizations`. Wildcards allowed. |
| `-SourceType <segment>` | Only references from this element type: the first path segment, e.g. `Classes`, `Tables`, `Forms`, `DataEntityViews`. |
| `-Kind <kind>` | Only one reference kind (table below). Default `Any`. |
| `-GroupBy Object\|Member\|None` | `Object` (default): type, object, module, count. `Member`: adds the method and its first line. `None`: one row per reference with full source path, line, column, kind. |
| `-Top <n>` | Row limit, default 500. The header says when the limit was hit. |
| `-Server`, `-Database` | Default `.` and `DYNAMICSXREFDB`. |

Output: a summary line with the row count, then a tab-separated header and rows. Exit codes: `0` rows found, `1` nothing found, `2` connection or query failure.

## Path format

Paths are `/<Type>/<Object>[/<MemberType>/<Member>]`. Common forms:

| Element | Path |
|---|---|
| Table / class / form | `/Tables/SalesLine`, `/Classes/SalesLineType`, `/Forms/SalesTable` |
| Table field | `/Tables/SalesLine/Fields/SalesPrice` |
| Table or class method | `/Tables/SalesLine/Methods/insert`, `/Classes/SalesLineType/Methods/validateWrite` |
| Class member variable | `/Classes/SalesLineType/Fields/salesLine` |
| EDT / enum | `/Edts/SalesPrice`, `/Enums/SalesStatus` |

For anything else, find the form with `-FindPath '/<Type>/<Object>*'`.

## Reference kinds

| Kind | Meaning |
|---|---|
| `MethodCall` (1) | Method call, or use of a class member variable |
| `TypeReference` (2) | Use of a type or a table field: declarations, field reads and writes, `select` statements |
| `InterfaceImplementation` (3) | Class implements the target interface |
| `ClassExtended` (4) | Class extends the target class |
| `Property` (6) | Metadata property reference, e.g. `/Property/IsDelegate` |
| `Attribute` (7) | Attribute applied, including `ExtensionOf` |
| `Tag` (9) | Test tags |
| `MethodOverride` (10) | Method overrides the target method |

Example: the direct subclasses of a class are `-Target /Classes/RunBase -Kind ClassExtended`; the overrides of one of its methods are `-Target /Classes/RunBase/Methods/dialog -Kind MethodOverride`.

## Gotchas

- **The data is only as fresh as the last build that updated cross references.** Standard models come pre-filled on a development VM. For custom code, the user must build in Visual Studio with cross references enabled (or run a full build with the cross-reference option), or recent changes are missing. Say so when the result looks incomplete.
- **Field references don't distinguish reads from writes:** both are `TypeReference`. To tell them apart, use `-GroupBy None` and open the reported lines.
- **Stored names don't always match the AOT casing** (for example `/Classes/Runbase`). Matching is case-insensitive, so this only matters when you compare the output with file names.
- **The database contains orphan references** whose source element was deleted. The script joins on existing names, so they never show up.
- **References from metadata** (form data sources, table relations, field groups, data entity mappings) appear with paths such as `/Forms/<Form>/...` or `/Tables/<Entity>/...`. Use `-SourceType Classes` when only X++ class code matters.
- **Large targets** (a whole table such as `/Tables/CustTable`, or a wildcard) can return tens of thousands of references. Keep `-GroupBy Object` and add filters instead of raising `-Top`.
