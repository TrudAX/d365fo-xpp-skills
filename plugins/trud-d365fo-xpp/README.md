# D365FO X++ Development (`trud-d365fo-xpp`)

Skills that help Claude develop in X++ for Microsoft Dynamics 365 Finance and Operations (D365FO) on a standard development VM.

## Install

In Claude Code 2.1.275 or later:

```
/plugin install trud-d365fo-xpp --marketplace TrudAX/d365fo-xpp-skills
```

In older versions, add the marketplace first:

```
/plugin marketplace add TrudAX/d365fo-xpp-skills
/plugin install trud-d365fo-xpp@trudax-d365fo
```

## Skills

### `d365-xpp-compile`

Before Claude creates or changes X++ elements (classes, tables, forms, extensions, EDTs, enums, menu items, data entities, security objects, labels), the skill makes it set up the task: the task's own Visual Studio project and, when the code is in git, its own branch, both named by your project's rules (CLAUDE.md, or the pattern of the existing projects and branches). Claude doesn't switch branches over uncommitted changes, and never commits or pushes unless you ask. After the changes, the skill makes Claude:

1. Add the changed elements to the task's Visual Studio project (`.rnrproj`), the way Visual Studio does. It also normalizes the element XML to the Visual Studio file format (UTF-8 without BOM, CRLF, no newline at end of file), so git diffs stay clean.
2. Compile the project with the X++ compiler, `xppc.exe`. Visual Studio's *Build project* can't run from the command line, and X++ compiles a whole package anyway, so the skill compiles the package the project's model belongs to. The output goes to a scratch folder.
3. Analyse the result: every error, marked `[project]` or `[other]`, warnings for the project's elements only, and the exact XML file line and source text for each code error. Claude fixes the errors and compiles again, then runs a full compile before handing the work back.

Before compiling, it checks every project element file for XML that Visual Studio and the compiler silently ignore: a property out of order, an unknown property name, or a wrong XML namespace. Such an element compiles without error but loses those properties (a menu item without its root namespace loses all of them). The check reads the element classes in the D365FO metadata assembly to know the exact order and namespace of every property.

Optional checks: labels referenced by the project's elements exist (`-CheckLabels`), and stale compiler-cache entries left after a rename or delete are cleaned up (`-RemoveStaleCache`).

### `d365-xpp-xref`

When you ask where an X++ element is used ("which classes use `SalesLine.SalesPrice`", "who calls this method", "what extends this class"), the skill makes Claude query the cross-reference database that the X++ compiler fills during a build (`DYNAMICSXREFDB`, the same data as Visual Studio's *Find references*), instead of searching thousands of source files. The script returns a short list grouped by referencing element, by method, or with every line number, filtered by module, element type, and reference kind (method call, type or field reference, extends, implements, override, attribute).

The results reflect the last build that updated cross references. Standard models come pre-filled; custom code must be built with cross references enabled.

It also lists the existing `[ExtensionOf]` classes of a class, table or form (`-ExtensionsOf`), so that a new Chain of Command method goes into the model's existing extension class instead of a second one.

### `d365-xpp-trace-parser`

When you have captured a trace (with *Include SQL parameter values*) and imported it into a Trace Parser database, the skill makes Claude answer questions like "which code set this field on this record?" from the database instead of the Trace Parser UI:

1. Find the trace and its busiest threads (a batch job or wave run is usually one thread).
2. Find the SQL statements on a table with the actual values each call bound to its columns, or search all bound values for one value (an order number, a work id, a RecId) to see every table and column it was written to, in time order.
3. Print the X++ call stack of any statement or method call, and list which methods of a class ran and in what order.
4. Read those methods in the X++ source and confirm the result in the data.

It handles the traps of the trace schema: durations stored in 100-ns ticks, session ids that repeat per trace, and parent links that break in batch traces with lock keep-alive threads.

### `d365-xpp-conventions`

When Claude creates X++ elements, the skill makes it apply the defaults that the TRUDUtils Visual Studio add-in generated, without being asked:

- **Tables:** a key EDT with its table reference, the key field set up as non-editable, mandatory, and the alternate, primary, clustered and replacement key. The audit fields (`CreatedBy`, `ModifiedBy` and their date-times), row version change tracking, `CacheLookup` Found, the standard field groups plus `Overview`, and a `find` method.
- **Fields:** an EDT for every field (a type default when none fits). Labels on the EDT rather than on the field, foreign-key relations taken from the EDT, and field groups.
- **Forms:** simple list and list-and-details (tabular grid) layouts for setup tables, plus the display menu item and View/Maintain privileges.
- **RunBase classes:** a template with dialog parameters, a query, a caller record or file upload. It runs in batch only when that's asked for or needed.
- **Names:** extensions (`SalesTable.<Model>`), extension classes (`SalesTable_<Model>_Extension`), menu items and privileges. Existing extensions in the model are reused.
- **Literal text** in labels and messages, unless you ask for label files.
- **No trivial comments** in the generated X++ code: a comment explains a reason or a rule, not what the next line does.

Claude asks before it creates a table, field or relation whose design your request leaves open. The skill assumes a development VM where you have full rights. If something fails with a security error (access denied, a permission or policy error), Claude stops and asks instead of working around it.

The project's own conventions (CLAUDE.md, or the existing elements in the model) take precedence. `Invoke-XppFormPattern.ps1` runs the platform's form pattern engine, the code behind the form designer's *Apply pattern*: it prints the controls a pattern requires, and reports or fixes the places where a form doesn't match its pattern. The X++ compiler doesn't check patterns.

## Requirements

- A Windows D365FO development environment with `<drive>:\AosService\PackagesLocalDirectory\bin\xppc.exe`. The folder is found automatically; override it with `-PackagesDir` or `$env:D365_PACKAGES_DIR`.
- Windows PowerShell 5.1 (included in Windows).
- For `d365-xpp-xref`: the `DYNAMICSXREFDB` database on the VM's SQL Server, readable by your Windows account (the default on a development VM). Override the server or database name with `-Server` and `-Database`.
- For `d365-xpp-trace-parser`: a trace imported into a Trace Parser database on a SQL Server your Windows account can read (usually the local one). The scripts find the database themselves when the server has exactly one; otherwise pass `-Database` (and `-Server`).
- Claude Code, or Cowork on the same machine, because the skill runs local PowerShell scripts. In claude.ai chat the skill loads, but it can't reach the D365FO machine.
- Not supported or tested: the Unified Developer Experience (UDE), where custom metadata lives outside `PackagesLocalDirectory`.

## What the plugin runs and changes

Everything runs locally. The scripts make no internet connections. The only connections are `d365-xpp-xref` and `d365-xpp-trace-parser` opening the local SQL Server (or the server you pass with `-Server`).

- **Runs** `xppc.exe` from `PackagesLocalDirectory\bin`.
- **Loads** the D365FO metadata assemblies from `PackagesLocalDirectory\bin` into the PowerShell session: `d365-xpp-compile` to check the element XML against the metadata classes, `d365-xpp-conventions` to read the form pattern catalog and form metadata.
- **Writes** compiler output and logs to `%TEMP%\xppc-scratch\<module>`. The deployed binaries in `PackagesLocalDirectory\<Package>\bin` are never touched.
- **Updates** the package's `XppMetadata` compiler cache. Visual Studio updates the same cache, and it isn't source-controlled.
- **Edits** the `.rnrproj` project file named in the command, plus the element XML files Claude passes to `Add-XppProjectItem.ps1` (line-ending and BOM normalization only). With `-Create`, it creates a new `.rnrproj` and `.sln`.
- **Edits** the form XML file passed to `Invoke-XppFormPattern.ps1 -Apply` (`d365-xpp-conventions`): it sets the properties the form's patterns require and saves the form through the D365FO metadata API, which also refreshes that form's entry in the `XppMetadata` cache. Without `-Apply`, the script only reads.
- **Reads** the `DYNAMICSXREFDB` cross-reference database with `SELECT` queries only, using Windows authentication (`d365-xpp-xref`). It never writes to the database.
- **Reads** a Trace Parser database with `SELECT` queries only, using Windows authentication (`d365-xpp-trace-parser`). Without `-Database`, it first lists the databases on the server (`sys.databases` in `master`) to find the one with the Trace Parser tables. It never writes to any database.
- **Deletes** compiler-cache files whose source element no longer exists, and only when `-RemoveStaleCache` is passed.

Outside the scripts, `d365-xpp-compile` tells Claude to run `git` in the repository that holds the model: `git status` and `git branch` to check the state, `git fetch` from your configured remote, and `git switch -c` to create and switch to the task's branch when the working tree is clean. It never tells Claude to commit, push or open a pull request; Claude does that only when you ask.

The skill doesn't deploy, sync the database, or restart services. To run or test a change, you still build it in Visual Studio.

## Privacy

This plugin collects no data. Its scripts run only on your machine. They make no internet connections (only the local SQL Server connection described above), send no telemetry, and send nothing to the plugin author or to any other service. The only network access the skills ask for is `git fetch` from the git remote you already configured, to branch from its current default branch.

- **What the scripts read:** your D365FO source files, Visual Studio project files, compiler logs, the form pattern definitions shipped with the platform, the cross-reference database (element paths, module names, and line numbers), and, for `d365-xpp-trace-parser`, the trace database you imported (method names, SQL statements and the values they bound).
- **What stays on your machine:** the compile output and logs in `%TEMP%\xppc-scratch`, which you can delete at any time. The trace scripts write no files.
- **What Claude sees:** the script output Claude reads in your conversation (file paths, element names, compiler messages, cross-reference results, and trace rows). Claude handles it under your own Claude plan's terms, like anything else in the conversation.
- **Personal data:** the plugin collects none. A trace can contain business data from your D365FO environment, including user names and the values of records that were processed (customer, order or item data) in its SQL parameter values. The trace scripts print only the rows you ask for, but whatever they print is in your conversation. Capture and analyse traces on environments where that's acceptable.

Questions: open an issue at https://github.com/TrudAX/d365fo-xpp-skills/issues.

## License

MIT. See [LICENSE](LICENSE).
