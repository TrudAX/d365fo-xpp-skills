# D365FO X++ Development (`trud-d365fo-xpp`)

Skills that help Claude develop in X++ for Microsoft Dynamics 365 Finance and Operations (D365FO) on a standard development VM.

## Skills

### `d365-xpp-compile`

After Claude creates or changes X++ elements (classes, tables, forms, extensions, EDTs, enums, menu items, data entities, security objects, labels), the skill makes Claude:

1. Add the changed elements to the task's Visual Studio project (`.rnrproj`), the way Visual Studio does. It also normalizes the element XML to the Visual Studio file format (UTF-8 without BOM, CRLF, no newline at end of file), so git diffs stay clean.
2. Compile the project with the X++ compiler, `xppc.exe`. Visual Studio's *Build project* can't run from the command line, and X++ compiles a whole package anyway, so the skill compiles the package the project's model belongs to. The output goes to a scratch folder.
3. Analyse the result: every error, marked `[project]` or `[other]`, warnings for the project's elements only, and the exact XML file line and source text for each code error. Claude fixes the errors and compiles again, then runs a full compile before handing the work back.

Optional checks: labels referenced by the project's elements exist (`-CheckLabels`), and stale compiler-cache entries left after a rename or delete are cleaned up (`-RemoveStaleCache`).

## Requirements

- A Windows D365FO development environment with `<drive>:\AosService\PackagesLocalDirectory\bin\xppc.exe`. The folder is found automatically; override it with `-PackagesDir` or `$env:D365_PACKAGES_DIR`.
- Windows PowerShell 5.1 (included in Windows).
- Claude Code, or Cowork on the same machine, because the skill runs local PowerShell scripts. In claude.ai chat the skill loads, but it can't reach the D365FO machine.
- Not supported or tested: the Unified Developer Experience (UDE), where custom metadata lives outside `PackagesLocalDirectory`.

## What the plugin runs and changes

Everything runs locally. The scripts make no network connections.

- **Runs** `xppc.exe` from `PackagesLocalDirectory\bin`.
- **Writes** compiler output and logs to `%TEMP%\xppc-scratch\<module>`. The deployed binaries in `PackagesLocalDirectory\<Package>\bin` are never touched.
- **Updates** the package's `XppMetadata` compiler cache. Visual Studio updates the same cache, and it isn't source-controlled.
- **Edits** the `.rnrproj` project file named in the command, plus the element XML files Claude passes to `Add-XppProjectItem.ps1` (line-ending and BOM normalization only). With `-Create`, it creates a new `.rnrproj` and `.sln`.
- **Deletes** compiler-cache files whose source element no longer exists, and only when `-RemoveStaleCache` is passed.

The skill doesn't deploy, sync the database, or restart services. To run or test a change, you still build it in Visual Studio.

## License

MIT. See [LICENSE](LICENSE).
