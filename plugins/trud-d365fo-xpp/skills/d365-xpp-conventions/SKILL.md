---
name: d365-xpp-conventions
description: Conventions for creating Dynamics 365 Finance & Operations (D365 F&O, AX7) X++ elements as metadata XML - new tables and table fields, EDTs, table relations, setup forms (simple list, list and details with a tabular grid), RunBase dialog and batch classes, table/form/enum extensions, Chain of Command and event handler classes, menu items and security privileges. Use this before writing the XML whenever you create a table, add fields to a table or table extension, create a form, an extension or extension class, a RunBase/RunBaseBatch class or other periodic operation, a menu item or a privilege - even when the user only says "create a table for X", "add a field", or "make a job that updates Y".
---

# D365 X++ element conventions

Defaults for new elements, taken from the TRUDUtils Visual Studio add-in that generated them for years. Apply them without being asked. The user's explicit instructions win; so do the conventions already visible in the target model (if its key EDTs extend another type than `Num`, or its extension classes follow another scheme, follow the model).

## Before writing anything

- **Task project and git branch:** set them up first, as `d365-xpp-compile` describes (*Task setup*).
- **Prefix and model:** the ones the user or CLAUDE.md names; otherwise infer them from existing elements in the target model. Ask only if neither tells you.
- **Table design: ask when in doubt.** If the request leaves a table, field, index or relation open (which table, type or size, mandatory, key, relation target, per company), ask once, with your proposed default for each point. This skill's defaults aren't doubts.
- **No labels unless asked.** Write literal text in `Label`, `HelpText`, `Caption` and X++ strings (`info("...")`, `checkFailed("...")`). Don't create label files or use label IDs (not even `@SYS` ones) unless the user asks for labels.
- **No trivial comments in X++:** none that repeat the code (`// Find the record`), no `///` headers that only restate the signature. The comments in the `references/` templates are notes for you, not code to copy.
- **Security errors: stop and ask.** The skill is for dev VMs with full rights. On access denied or a permission, policy or login error, report it and ask; don't work around it, unless the user or CLAUDE.md says how.
- **Reuse existing extensions.** Before creating `<Element>.<Model>` or an extension class, look in the model folder for one (`AxTableExtension\SalesTable.*.xml`; a class with `[ExtensionOf(tableStr(SalesTable))]`, or `d365-xpp-xref -ExtensionsOf`) and add to it.
- **XML:** copy the root element (with its `xmlns` attributes) and the property order from a standard element of the same type. Element order and namespaces matter: forms use `xmlns="Microsoft.Dynamics.AX.Metadata.V6"` and menu items `xmlns="Microsoft.Dynamics.AX.Metadata.V1"` on the root, while tables, EDTs, classes and privileges have none. Anything misplaced is silently ignored; `d365-xpp-compile` reports it as `[ignored]`.
- **After writing:** add the elements to the project and compile (`d365-xpp-compile`). New or changed tables, fields and indexes also need a database sync; say so.

## New table

A setup table (code + description) comes with its EDT, a form, a display menu item and two privileges, unless the user asks for less. Other tables (transactions, logs, parameters) get only what was asked, with the same table properties. Example names for prefix ABC and entity "Vehicle brand":

- **Table** `ABCVehicleBrand`: `Label` "Vehicle brands", `TableGroup` Group, `TitleField1` the key, `TitleField2` Description, `CacheLookup` Found, `CreatedBy`, `CreatedDateTime`, `ModifiedBy`, `ModifiedDateTime` and `AllowRowVersionChangeTracking` Yes.
- **Key EDT** `ABCVehicleBrandId`: string, `Extends` `Num` (no `StringSize` when it extends), `Label` "Vehicle brand", `HelpText` "Identification of the vehicle brand", `ReferenceTable` + `TableReferences` to the key field.
- **Key field** `VehicleBrandId` (entity name without the prefix): `AllowEdit` No (it stays editable on a new record), `IgnoreEDTRelation` Yes, `Mandatory` Yes.
- **Description field** `Description` with EDT `Description`.
- **Index** `VehicleBrandIdIdx` on the key, `AlternateKey` Yes; it is the table's `ClusteredIndex`, `PrimaryIndex` and `ReplacementKey`. Indexes are unique by default: a non-unique one needs `AllowDuplicates` Yes.
- **Field groups:** `AutoReport` (key), `AutoLookup`, `AutoIdentification` (`AutoPopulate` Yes, key), `AutoSummary`, `AutoBrowse`, and `Overview` (label "Overview": key, Description).
- **Method** `public static ABCVehicleBrand find(ABCVehicleBrandId _vehicleBrandId, boolean _forUpdate = false)`.

## New fields

- **Every field has an EDT.** Use the EDT the user names, creating it if it doesn't exist (`<Prefix><Name>`, label and help text on the EDT). Without one, pick a fitting standard EDT, else the type default: Int `Integer`, Real `Amount`, Date `TransDate`, DateTime `TransDateTime`, Time `TimeHour24`, Int64 `RefRecId`, Enum `NoYesId`, Container `InfologData`, Memo `FreeTxt`. A string without a fitting standard EDT gets a new EDT with a `StringSize`. Set `StringSize` only on an EDT without `Extends`.
- **Label and HelpText on the field only when they differ from the EDT's.**
- **Name from the label:** PascalCase, special characters removed, `V` prefix if it starts with a digit.
- **Field group:** add the field to the group the user names; create a missing group with that label and the PascalCase label as its name.
- **Relation:** if the field's EDT, or an EDT it extends, has a `ReferenceTable` (or old-style `Relations`), add an `AxTableRelationForeignKey` named after the related table (`<RelatedTable>_<Field>` if taken): `Cardinality` ZeroMore, `RelatedTableCardinality` ZeroOne (ExactlyOne for a mandatory field), `RelationshipType` Association, `OnDelete` Restricted, and an `AxTableRelationConstraintField` with `Field`, `RelatedField` and `SourceEDT`. Copy the EDT relation's fixed-value conditions as `AxTableRelationConstraintRelatedFixed`.
- **Display method** (when asked for one): `[SysClientCacheDataMethodAttribute(true)] public display <EDT> <name>()`.
- **Table extension:** fields go into the model's `<Table>.<Model>` extension. Prefix the names of new fields, field groups, indexes and relations there (`ABCVehicleBrandId`).

## Forms

- **Setup table → simple list** form (`SimpleList` pattern): same name as the table, `Caption` = table label, root data source `InsertIfEmpty` No, action pane, quick filter, grid of the `Overview` field group.
- **List and details** (`SimpleListDetails-Grid`, "tabular") when the record has more fields than fit in a grid row, or lines.
- **Read `references/forms.md`** for both layouts before writing the form XML.
- Then **check the form** with `<skill-dir>\scripts\Invoke-XppFormPattern.ps1 -Form <form .xml>`; `-Apply` stamps every property the patterns enforce (Style, WidthMode, ArrangeMethod, PatternVersion...). The compiler doesn't check patterns.

## RunBase classes

For a periodic job, a dialog operation, a data update or a file import, write a RunBase class (not SysOperation, unless the user asks for it or the model's existing operations use it). Read `references/runbase.md` and start from its template.

- `extends RunBaseBatch implements BatchRetryable`; `isRetryable()` returns true; `canRunInNewSession()` returns false.
- `canGoBatch()` returns **false**, unless the user asks for batch processing or the work is long-running (many records, scheduled, recurring); then true, and `run()` must work without a client.
- Name it after the action (`ABCVehicleBrandUpdate`). `description()` returns a literal string, which is also the menu item label.

## Extensions

| Element | Name |
|---|---|
| Table, form, enum, EDT, view, data entity, menu, menu item, security role/duty extension | `<Element>.<Model>`, e.g. `SalesTable.ContosoCustomizations` |
| Extension class of a class, table, view, data entity, map | `<Element>_<Model>_Extension`, e.g. `SalesTable_ContosoCustomizations_Extension` |
| Extension class of a form | `<Form>Form_<Model>_Extension` (`Form` keeps it apart from the table of the same name) |
| Form data source / data field / control | `<Form>Form_<DataSource>DS_<Model>_Extension`, `<Form>Form_<DataSource>DS_<Field>_<Model>_Extension`, `<Form>Form_<Control>_<Model>_Extension` |
| Event handler class | `<Element>_<Model>_EventHandler`, form: `<Form>Form_<Model>_EventHandler` |

Class names are limited to 80 characters; if longer, use the prefix instead of the model name. Extension classes are `final`.

## Menu items and privileges

- **Menu item:** name = the object's name; display for a form, action for a class, output for a report. `Label` = form caption or class `description()`. `HelpText` "Set up <label>" for a setup form, "<label> operation" for a class.
- **Privileges:** `<MenuItem>View` (entry point `Grant` with `Read` Allow) and `<MenuItem>Maintain` (`Grant` with `Correct`, `Create`, `Delete`, `Read` and `Update` all Allow). Labels "<menu item label> view" / "<menu item label> maintain". An action menu item usually needs only the Maintain privilege. A data entity is granted under `DataEntityPermissions` (`IntegrationMode` All). Add privileges to a duty or role only when asked.

## Scripts

`<skill-dir>\scripts\Invoke-XppFormPattern.ps1` uses the platform's own pattern engine (the form designer's "Apply pattern"). It finds `PackagesLocalDirectory` with `d365-xpp-compile`'s `XppCommon.ps1` (`-PackagesDir` overrides). Windows PowerShell 5.1; from Bash use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`.

| Call | What it does |
|---|---|
| `-Pattern SimpleListDetails-Grid` | Prints the control tree the pattern requires: type, required/optional, "many", sub-patterns, enforced property values. |
| `-List` | Lists the active patterns. |
| `-Form <form .xml>` | Checks the design and every sub-pattern container: missing required controls, controls the pattern doesn't allow, property values that differ. |
| `-Form <form .xml> -Apply` | Applies the patterns and saves the form. Saves nothing if the control structure doesn't match. `-Pattern <name>` sets the design pattern first. |

Exit codes: 0 = OK, 1 = the form doesn't match, 2 = setup failure. The analyzer matches controls by type and order, so a missing control can be reported on its neighbour; compare with the `-Pattern` tree. After `-Apply`, run `Add-XppProjectItem.ps1` as for any edited element.
