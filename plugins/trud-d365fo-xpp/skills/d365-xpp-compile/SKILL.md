---
name: d365-xpp-compile
description: Set up the task's Visual Studio project and git branch, then build a Dynamics 365 Finance & Operations (D365 F&O, AX7) X++ project (.rnrproj) from the command line the way Visual Studio does on a development VM (CHE or VHD) - compile its package with xppc into PackagesLocalDirectory, compile labels, sync changed tables and data entities, restart the AOS so the change can be tested - and analyse the compile errors. Use this at the start of every task that will create or modify X++ / AOT elements (AxClass, AxTable, AxForm, table/form/class extensions, EDTs, enums, menu items, data entities, security, labels), before the first edit - to create or find the task's project and branch - and after the changes - add the changed elements to the project, build, and fix errors until the build is clean, without waiting to be asked. Also use when the user says "build/compile the project", "deploy it so I can test", "check that it compiles", "run xppc", or pastes X++ compiler errors.
---

# D365 X++ project build

Before the first edit: **the task's project and git branch.** After every X++ change: **add the changed elements to the project → build → analyse and fix → repeat until clean → full build before handing back.**

## What the build does

On a CHE or VHD development VM, X++ is built into the running environment: the AOS runs the binaries in `PackagesLocalDirectory\<Package>\bin`. Visual Studio's *Build* can't run from the command line, and X++ compiles a whole package anyway, so `Invoke-XppProjectBuild.ps1` does what a Visual Studio build does, for the package of the project's model:

1. Stops the batch service and IIS (the AOS) if they run. This needs an elevated session.
2. Compiles the package with `xppc.exe` into `<Package>\bin`: incremental, or everything with `-Full`.
3. Compiles the package's label files with `LabelC.exe` when they changed since the last build.
4. Syncs the project's tables, views and data entities (and the elements its extensions extend) with `SyncEngine.exe`, a partial sync, when their files changed since the last sync.
5. Starts IIS and the batch service again. The first page load after the restart takes about a minute.

`-CheckOnly` only compiles, into a scratch folder (`%TEMP%\xppc-scratch\<module>`): nothing is stopped, deployed or synced, and the AOS keeps running the deployed binaries. Use it for quick iterations while fixing errors, or when someone else is testing on the VM.

## Scripts

All scripts are in `<skill-dir>/scripts/`. They are Windows PowerShell 5.1 scripts. Run them with the PowerShell tool:

```powershell
& "<skill-dir>\scripts\Invoke-XppProjectBuild.ps1" -Project "C:\Repos\Contoso\Projects\ABC123_Feature\ABC123_Feature\ABC123_Feature.rnrproj"
```

From Bash, use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>/scripts/Invoke-XppProjectBuild.ps1" -Project ...`.

| Script | What it does |
|---|---|
| `Add-XppProjectItem.ps1 -Project <rnrproj> -Element AxClass\A, AxTableExtension\SalesTable.ABC` | Checks the element files exist in the project's model and are well-formed XML. Normalizes them, and the project file, to the VS file format (UTF-8 without BOM, CRLF, no newline at end of file). Adds missing `<Content>` items, sorted and filed under the VS element-type folder. Idempotent. `-Element` also accepts paths to element `.xml` files or one comma-separated string. `-NoNormalize` skips the rewrite. |
| `... -Remove` | Removes the elements from the project instead (for deleted or renamed elements). Don't edit the `.rnrproj` by hand. |
| `... -Create -Model <ModelName>` | Creates the project, plus a `.sln` one folder up, using VS's layout: `<root>\<Name>\<Name>.sln` and `<root>\<Name>\<Name>\<Name>.rnrproj`. |
| `Invoke-XppProjectBuild.ps1 -Project <rnrproj or folder>` | Runs pre-checks, builds incrementally as described above, and prints the report. Exit code: 0 = clean, 1 = compile, label or sync errors, 2 = setup failure. |
| `... -Full` | Full compile of the package (about 30 s for a large customization package), and the labels. |
| `... -CheckOnly` | Compile only, into the scratch folder. `-OutputDir` changes that folder. |
| `... -Sync` | Sync the project's tables, views and entities even if their files didn't change (for example after a database restore). `-SqlServer` and `-SqlDatabase` default to `localhost` and `AxDB`. |
| `... -RemoveStaleCache` | Deletes compiler-cache files whose source was renamed or deleted. |
| `... -AllWarnings` | Also lists warnings outside the project. |
| `... -CheckLabels` | Also checks that referenced labels exist and that label IDs are unique. Off by default. |

The packages folder (`<drive>:\AosService\PackagesLocalDirectory`) is found automatically. Override it with `-PackagesDir` or `$env:D365_PACKAGES_DIR`. `XppCommon.ps1` is shared: `d365-xpp-conventions\scripts\Invoke-XppFormPattern.ps1` dot-sources it for `Find-PackagesDir`.

Give build calls a long tool timeout (600000 ms): a full compile takes about 30 s and a sync about 2 minutes. If it might take longer, run it in the background and wait for it to finish.

## Task setup: project and branch (before the first edit)

Every task that creates or changes X++ elements gets its own Visual Studio project and, when the code is in git, its own branch. Questions and investigations that change nothing need neither.

**Names** come from the project rules: CLAUDE.md first, otherwise the pattern of the existing projects (the repo's `Projects\` folder) and branches (`git branch -a`). Usually the ticket number plus a short description, e.g. project `ABC123_SalesRelease` and branch `feature/ABC123-sales-release`. If the rules need a ticket number and you don't have one, ask.

1. **Project.** Use the one the user or CLAUDE.md names, or the task's existing project (Glob for `**/*ABC123*.rnrproj`). Otherwise create it with `Add-XppProjectItem.ps1 -Create` next to the sibling projects, with the model the elements live in (the `<package>\<model>\Ax...` folder of the element files). One project per task.
2. **Git branch** - only if the model folder is in a git repository (`git -C <model folder> rev-parse --show-toplevel`).
   - Already on this task's branch: stay on it. Otherwise, if `git status` is clean, create the task branch from the default branch (the one the rules name, else `origin/HEAD`, else `main`/`master`; `git fetch` first when there is a remote) and switch to it.
   - **Uncommitted changes: don't switch.** They may belong to another task. Stop and ask the user.
   - Say which branch you created. The model folders are what Visual Studio and the AOS read, so switching changes their code, and Visual Studio may ask to reload.
   - Project rules win: some repositories commit straight to the main branch, others use TFVC; then skip this step. Never commit, push or open a pull request unless the user asks.

## The loop

1. **Use the task's project.** If the name is a real judgement call, ask the user.
2. **Add every element you created or modified,** including menu items, enum extensions, labels (`AxLabelFile`) and security objects. Don't add elements you only read; remove deleted or renamed ones with `-Remove`.
   - Run `Add-XppProjectItem.ps1` after editing element files even when the element is already in the project. The Write tool saves LF line endings; the script restores the VS format so the git diff stays clean.
3. **Build** with `Invoke-XppProjectBuild.ps1`. `-CheckOnly` is fine while fixing errors.
4. **Analyse** the report (see below) and fix the cause in the element XML. Re-run steps 2-3.
   - If the same error survives three fix attempts, stop and explain it to the user instead of guessing further.
5. **Run a full build (`-Full`, without `-CheckOnly`)** before telling the user you're done or testing the change, and after renaming or deleting elements or changing method signatures or other shared APIs.
   - Incremental builds only recompile changed elements. A caller broken by your signature change shows up **only** in a full build, as an `[other]` error.
   - After renames or deletes, add `-RemoveStaleCache`. Otherwise the old type stays in the compiler cache and can hide those errors.

## Reading the report

```
Checks  :
  [format]  AxClass\ABCFoo: LF line endings ...   -> run Add-XppProjectItem.ps1 on it
  [missing] / [xml] ...                           -> blocking; nothing is built until fixed
  [ignored] AxTable\ABCFoo: AxTable[ABCFoo]/CreatedBy: out of order, must come before Relations
                                                  -> the element compiles WITHOUT this property; fix the XML
  [cache]   stale compiler cache ...              -> rerun with -RemoveStaleCache
AOS     : stopped IIS and batch service
Compile : 31 s, xppc exit code 1; logs ...
Labels  : skipped, the compile failed
Sync    : skipped, the compile failed
AOS     : IIS started, batch service started; ...
ERRORS (2; 1 in project elements)
  1. [project] Class ABCFoo, run, line 12 col 9  (NotDeclared)
     'undefinedVar' is not declared.
     at C:\...\AxClass\ABCFoo.xml:23              <- line in the XML file to edit
     > undefinedVar = 5;                           <- the source line
  2. [other]   Class ABCBar, bar, line 6 col 16  (ParameterMissing)
RESULT: FAILED - ...
```

- **`[ignored]`** lists XML elements that Visual Studio and xppc silently skip: an unknown property name, a wrong XML namespace (a menu item root without `xmlns="Microsoft.Dynamics.AX.Metadata.V1"` is read as completely empty), or a property out of order. The compiler never reports these, so the result is FAILED until you move, rename or re-namespace the element as the message says. Copy the order from a standard element of the same type.
- **`FATAL ERRORS`** come from the text log (for example an invalid character in a class source) and stop the compile of that element.
- **`[project]` errors** are in your elements. Fix them.
- **`[other]` errors** are in elements outside the project. In a full build right after your change, they are almost always callers or subclasses you broke. Fix the caller, or reconsider the change. If the element isn't in your diff and doesn't use anything you changed, the error existed before: tell the user, don't rewrite unrelated code.
- **`DEPLOY PROBLEMS`** are label compile or sync errors (logs in `%TEMP%\xppc-logs\<module>`). A sync error usually means a table change the database can't take as is (for example a shorter field or a new unique index on duplicate data).
- **Warnings** are listed for project elements only. Fix the ones your change introduced (obsolete API, extensible-enum cast, lossy conversion), and leave existing ones unless asked. Incremental builds report warnings only for recompiled elements; use `-Full` to see all of them.
- **`line/col`** are the numbers Visual Studio's code editor shows. For classes and tables, `at file:line` gives the exact XML line. For forms, search the form XML for the method.
- For what each error moniker means and its usual fix, read `references/xpp-compile-errors.md`.

## Reporting back

Say what was built and how, for example: "Full build of package ContosoCustomizations, labels compiled, ABCVehicleBrand synced, AOS restarted: 0 errors; project elements have 1 warning, pre-existing." Say so when a build was only `-CheckOnly`: then nothing is deployed and the change can't be tested yet. List any warnings your change introduced and any `[other]` errors you left alone, with the reason.

## Gotchas

- Don't run two builds of the same package at once, or while Visual Studio is building it. They share the `XppMetadata` cache and the package bin.
- The build restarts the AOS: tell the user before building on a VM others are testing on, or use `-CheckOnly`.
- The sync state is kept per module under `%TEMP%\xppc-state`, not in the database. After a database restore, build once with `-Sync`.
- The sync covers the project's tables, views and data entities. A change that needs a wider sync (an EDT's string size used by tables outside the project, or a full sync after many changes) is not detected: use Visual Studio's *Synchronize database*.
- "No diagnostics log was written" means xppc itself failed. Its console output is printed and saved in `xppc.out.txt` in the log folder. Usual causes are a concurrent build or low disk space.
- A sudden burst of errors in unrelated referenced elements (unresolved .NET types) means the package's own `bin` folder is incomplete. The script passes `-refPath` for `<Package>\bin` and `PackagesLocalDirectory\bin`; run one `-Full` build.
- `xppc` accepts `-classes=` but ignores it: it always compiles the whole package.
- Without `-CheckLabels`, xppc does **not** check label references. An unknown `@ABC:Foo` compiles and shows up raw in the UI. When you add labels, check them in `<model>\AxLabelFile\LabelResources\en-US\<File>.en-US.label.txt` (`Id=Text` lines, `;` comment lines), or run with `-CheckLabels`. Its output is noisy on legacy code that references label files missing from the box.
- The Unified Developer Experience (UDE), where custom metadata lives outside PackagesLocalDirectory and the AOS runs in the cloud, is not supported. On that setup, use Visual Studio instead.
