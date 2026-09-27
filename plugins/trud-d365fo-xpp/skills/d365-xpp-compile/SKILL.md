---
name: d365-xpp-compile
description: Compile a Dynamics 365 Finance & Operations (D365 F&O, AX7) X++ Visual Studio project (.rnrproj) from the command line with xppc and analyse the compile errors. Use this every time you create or modify X++ / AOT elements (AxClass, AxTable, AxForm, table/form/class extensions, EDTs, enums, menu items, data entities, security, labels) - add the changed elements to the task's .rnrproj project, compile, and fix errors until the build is clean, without waiting to be asked. Also use when the user says "build/compile the project", "check that it compiles", "run xppc", or pastes X++ compiler errors.
---

# D365 X++ project compile

After every X++ change: **add the changed elements to the project → compile the project → analyse and fix → repeat until clean → full compile before handing back.**

## How "compile the project" works here

- Visual Studio's *Build project* can't run from the command line: the D365 MSBuild task needs the VS shell.
- X++ also has no per-project compile unit. VS compiles the whole **package** that the project's model belongs to, incrementally.
- `scripts/Invoke-XppProjectBuild.ps1` does the same thing with `xppc.exe`:
  - it reads the project's `<Model>`, finds its package, and compiles that package;
  - it reports all errors, but only the warnings of the project's elements.
- Output goes to a scratch folder (`%TEMP%\xppc-scratch\<module>`). The deployed binaries in `PackagesLocalDirectory\<Package>\bin`, which the running AOS uses, are never touched.
- The scratch folder keeps its own incremental state, so it never makes the next Visual Studio build skip a change.
- The only shared state is the package's gitignored `XppMetadata` compiler cache, which VS also writes.

This is a compile **check**. It does not deploy, compile labels into resources, deploy reports, or sync the database. To run or test the change, the user still builds in Visual Studio.

## Scripts

All scripts are in `<skill-dir>/scripts/`. They are Windows PowerShell 5.1 scripts. Run them with the PowerShell tool, like this:

```powershell
& "<skill-dir>\scripts\Invoke-XppProjectBuild.ps1" -Project "C:\Repos\Contoso\Projects\ABC123_Feature\ABC123_Feature\ABC123_Feature.rnrproj"
```

From Bash, or if the execution policy blocks scripts, use:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>/scripts/Invoke-XppProjectBuild.ps1" -Project "C:/Repos/Contoso/Projects/ABC123_Feature"
```

| Script | What it does |
|---|---|
| `Add-XppProjectItem.ps1 -Project <rnrproj> -Element AxClass\A, AxTableExtension\SalesTable.ABC` | Checks the element files exist in the project's model and are well-formed XML. Normalizes them to the VS file format (UTF-8 without BOM, CRLF, no newline at end of file). Adds missing `<Content>` items, sorted and filed under the VS element-type folder, as VS does. Idempotent. `-Element` also accepts paths to element `.xml` files or one comma-separated string. `-NoNormalize` skips the rewrite. |
| `Add-XppProjectItem.ps1 -Project <new path>.rnrproj -Create -Model <ModelName> -Element ...` | Creates the project, plus a `.sln` one folder up, using VS's layout: `<root>\<Name>\<Name>.sln` and `<root>\<Name>\<Name>\<Name>.rnrproj`. |
| `Invoke-XppProjectBuild.ps1 -Project <rnrproj or folder>` | Runs pre-checks, compiles incrementally, and prints the report. Exit code: 0 = clean, 1 = errors, 2 = setup failure. |
| `... -Full` | Full compile of the package (about 30 s for a large customization package). |
| `... -RemoveStaleCache` | Deletes compiler-cache files whose source was renamed or deleted. |
| `... -AllWarnings` | Also lists warnings outside the project. |
| `... -CheckLabels` | Also checks that referenced labels exist and that label IDs are unique. Off by default. |

The packages folder (`<drive>:\AosService\PackagesLocalDirectory`) is found automatically. Override it with `-PackagesDir` or `$env:D365_PACKAGES_DIR`.

Give compile calls a long tool timeout (600000 ms). If a full compile of a very large package might take longer than that, run it in the background and wait for it to finish.

## The loop

1. **Find the project.**
   - Use the one the user or CLAUDE.md names.
   - Otherwise, look for the ticket number under the repo's `Projects\` folder (for example, a Glob for `**/*ABC123*.rnrproj`).
   - If none exists, create one with `-Create`. Follow the naming of sibling projects (such as `ABC123_SalesRelease`) and use the model the elements live in: the `<package>\<model>\Ax...` folder of the element files.
   - If the name is a real judgement call, ask the user.
2. **Add every element you created or modified.** Include new menu items, enum extensions, labels (`AxLabelFile`), and security objects, not just classes. Don't add elements you only read.
   - Run `Add-XppProjectItem.ps1` after editing element files even when the element is already in the project. The Write tool saves LF line endings; the script restores the VS format so the git diff stays clean.
3. **Compile** with `Invoke-XppProjectBuild.ps1` (incremental is fine while iterating).
4. **Analyse** the report (see below) and fix the cause in the element XML. Re-run steps 2–3.
   - If the same error survives three fix attempts, stop and explain it to the user instead of guessing further.
5. **Run a full compile (`-Full`)** before telling the user you're done, and after renaming or deleting elements or changing method signatures or other shared APIs.
   - Incremental builds only recompile changed elements. A caller broken by your signature change shows up **only** in a full build, as an `[other]` error.
   - After renames or deletes, add `-RemoveStaleCache`. Otherwise the old type stays in the compiler cache and can hide those errors.

## Reading the report

```
Checks  :
  [format]  AxClass\ABCFoo: LF line endings ...   -> run Add-XppProjectItem.ps1 on it
  [missing] / [xml] ...                           -> blocking; the compile is skipped until fixed
  [cache]   stale compiler cache ...              -> rerun with -RemoveStaleCache
ERRORS (2; 1 in project elements)
  1. [project] Class ABCFoo, run, line 12 col 9  (NotDeclared)
     'undefinedVar' is not declared.
     at C:\...\AxClass\ABCFoo.xml:23              <- line in the XML file to edit
     > undefinedVar = 5;                           <- the source line
  2. [other]   Class ABCBar, bar, line 6 col 16  (ParameterMissing)
RESULT: FAILED - ...
```

- **`[project]` errors** are in your elements. Fix them.
- **`[other]` errors** are in elements outside the project. In a full build right after your change, they are almost always callers or subclasses you broke. Fix the caller, or reconsider the change.
  - If the error is unrelated to your change (the element isn't in your diff and doesn't use anything you changed), it existed before. Tell the user about it; don't rewrite unrelated code.
- **Warnings** are listed for project elements only. Fix the ones your change introduced (obsolete API, extensible-enum cast, lossy conversion), and leave existing ones unless asked. Incremental builds report warnings only for recompiled elements; use `-Full` to see all of them.
- **`line/col`** are the numbers Visual Studio's code editor shows for the element. Use them when talking to the user.
  - For classes and tables, `at file:line` gives the exact XML line.
  - For forms, only the element and method are shown: search the form XML for the method.
- For what each error moniker means and its usual fix, read `references/xpp-compile-errors.md`.

## Reporting back

Say what was compiled and how. For example: "Full xppc compile of package ContosoCustomizations (scratch output): 0 errors; project elements have 1 warning, pre-existing." List any warnings your change introduced and any `[other]` errors you left alone, with the reason.

Don't call this a Visual Studio build. Remind the user that deploying or testing needs a VS build, and a database sync only if tables, fields, indexes, views, or entities changed.

## Gotchas

- Don't run two compiles of the same package at once, or while Visual Studio is building it. They share the `XppMetadata` cache.
- "No diagnostics log was written" means xppc itself failed. Its console output is printed and saved in `xppc.out.txt` in the output folder. Usual causes are a concurrent build or low disk space.
- A sudden burst of errors in unrelated referenced elements (unresolved .NET types) means the package's own `bin` folder is incomplete. The script passes `-refPath` for `<Package>\bin` and `PackagesLocalDirectory\bin`. If those binaries are missing, the user needs one Visual Studio build of the package.
- `xppc` accepts `-classes=` but ignores it: it always compiles the whole package.
- Without `-CheckLabels`, xppc does **not** check label references. An unknown `@ABC:Foo` compiles and shows up raw in the UI. When you add labels, check them yourself in `<model>\AxLabelFile\LabelResources\en-US\<File>.en-US.label.txt` (`Id=Text` lines, `;` comment lines), or run with `-CheckLabels`. Its output is noisy on legacy code that references label files missing from the box.
- The Unified Developer Experience (UDE), where custom metadata lives outside PackagesLocalDirectory, is not supported or tested. On that setup, use Visual Studio instead.
