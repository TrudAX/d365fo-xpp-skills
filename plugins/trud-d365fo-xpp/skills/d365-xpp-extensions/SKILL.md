---
name: d365-xpp-extensions
description: Rules and recipes for extending standard Dynamics 365 Finance & Operations (D365 F&O, AX7) X++ code from your own model - Chain of Command wrappers ([ExtensionOf], next), pre/post, data-event and form event handlers, delegate subscribers, form, data source and control extensions, lookups (control, field, reference group, multi-select) and fields added to RunBase or SysOperation dialogs. Use this before writing or reviewing any [ExtensionOf] class or event handler class, and whenever the task changes, blocks or adds to standard behaviour - "add a check before posting", "default this field on the sales line", "filter this lookup", "add a field to this dialog", "hide this button on the form", "why is my extension not called", "review this extension" - even when the user doesn't say Chain of Command, CoC or extension.
---

# D365 X++ extensions

How to write and review extensions of standard D365 F&O code: Chain of Command (CoC) wrappers, event handlers, form extensions, lookups and dialog fields.

This skill sits on top of what you already know. It doesn't explain `[ExtensionOf]`, `next`, data events, `XppPrePostArgs`, `EventHandlerResult`, `SysTableLookup`, `SysPackExtensions` or context classes. It holds the rules that are easy to get wrong from memory, the signatures and names that are hard to produce reliably, and recipes to copy.

**Where a rule here differs from what you remember or from Microsoft Learn, follow this skill.** Unless [Rules that were not run](#rules-that-were-not-run) lists it, every rule about compile or run-time behaviour was compiled and run on application version 10.0.39, and the samples were compile-checked there. On a much newer version, verify a rule when the result depends on it.

Samples use the prefix `ABC` (members `abc…`) and the model `ContosoCustomizations`. Use the prefix and model you work in.

Other skills in this plugin cover the rest: `d365-xpp-conventions` for the names of extension and handler classes, `d365-xpp-xref` to find the extension class a model already has, `d365-xpp-compile` for the task's project and the build.

## Steps

1. **Read the base method** in the standard `Ax*.xml`: signature, access modifier and attributes (`[Hookable(false)]`, `[Wrappable(false)]`, `[Replaceable]`, `final`). `[Hookable(false)]` is common, so check it before you plan a wrapper. Visual Studio doesn't list the methods nested in a form that can be wrapped; take those from the form's XML or from [Forms](#forms).
2. **Find the extension class the model already has** for the target and add to it: one extension class per target and concern. Use `d365-xpp-xref` (`-ExtensionsOf`), or search the model's `AxClass` folder, case-insensitive, for `ExtensionOf\(\s*tableStr\(\s*SalesLine\s*\)` (real code has `tablestr`, `Classstr`, `FormDataSourcestr`).
3. **Pick the mechanism** ([next section](#pick-the-mechanism)).
4. **Write it.**
   - Class names come from `d365-xpp-conventions` (*Extensions*). Every method and field you add gets the prefix.
   - In the `AxClass` file, class attributes and `using` lines go in `<Declaration>` before `class`, member variables inside the declaration braces, and method attributes inside that method's `<Source>` above the signature. `<Method><Name>` equals the X++ method name.
   - Read the reference file first: `references/forms.md` for form code, `references/lookups.md` for a lookup, `references/dialogs.md` for a RunBase or SysOperation dialog.
5. **Build** with `d365-xpp-compile` after every change, and run a full build before you finish: some errors, such as a wrong display-method binding, are reported by a full build only.
6. **Say what you did not run.** A clean build proves signatures and the placement of `next`, nothing more: every pattern in [Patterns that compile and are wrong](#patterns-that-compile-and-are-wrong) compiles. For a form change, check in the client that the wrapper runs, the standard behaviour still runs and the form still saves, or say that this wasn't checked.

## Pick the mechanism

| Need | Use |
|---|---|
| Change or add to what a public or protected method does | A CoC wrapper. This is the default. |
| The method can't be wrapped, but it is public and not `[Hookable(false)]` | A pre/post handler. |
| Logic that belongs to the table: defaults, derived fields, related rows | CoC on the table method. |
| Another feature only observes the table | A data event handler. |
| The standard code raises a delegate for this purpose | A delegate subscriber. |
| React to a form, data source or control event | A form event handler; CoC on the nested element when you need code on both sides of the call or the form's state. |

**Can be wrapped:**

- public and protected methods, `protected internal` methods, and methods of a `final` class;
- a kernel table method (`insert`, `update`, `validateWrite`, …), even when the table doesn't override it;
- X++ static methods of `Global` (`isConfigurationkeyEnabled`, `strRemoveCr`, …), through `[ExtensionOf(classStr(Global))]`; the wrapper runs for unqualified calls;
- entity methods such as `defaultRow()`;
- custom X++ methods written inside a form's data source or control, on your own and on standard forms. Microsoft Learn says they can't be wrapped; they can, and the wrapper runs;
- methods of data sources and controls that your own form extension added.

**Can't be wrapped:** `private`; `internal`, even in the same model; `[Hookable(false)]`; `[Wrappable(false)]`; a `final` method without `[Wrappable(true)]`.

**Pre/post handlers attach to public methods only.** A protected target is compile error `InvalidPrePostTarget` unless it carries `[Hookable(true)]`. Private methods, `[Hookable(false)]` methods and a kernel table method that the table doesn't override are compile errors too.

## Chain of Command

### Wrapper signature

- Copy the base access modifier. A `public` wrapper of a `protected` method is error `ChainOfCommandMethodAccessModifierMismatch`.
- Drop default parameter values: `public void create(boolean _append)`. Keeping `= false` is a compile error.
- Keep `static` on a static method.
- Parameter names may differ from the base, and X++ is case-insensitive. Keep the base spelling anyway.
- A method of an extension class that has the name of a public or protected base method is a wrapper and must call `next`.

### Where `next` may stand

- **Allowed:** at the top level, and inside `try`, `finally`, `using`, `unchecked (…)`, `changecompany (…)`, a plain `{ }` block, and between `ttsbegin` and `ttscommit`.
- **Compile error** (`ChainOfCommandNextCallMustBeUnconditioned`): inside `if`, a loop, `switch` or `catch`; in a logical expression; a second `next`; after `if (…) { return …; }`.
- **`[Replaceable]` base method:** `next` may be conditional or left out.
- **Data source added by a form extension:** a conditional `next` compiles in its methods, and only there. A path that skips `next write()` leaves that record unsaved while the parent record is saved, so check every path.

### Stopping or neutralising a standard method

To stop it, throw before `next`. This compiles, and it is the only way to stop a method that isn't `[Replaceable]`:

```xpp
public void post()
{
    if (!this.abcCanPost())
    {
        throw error("Posting is blocked for this journal.");
    }
    next post();
}
```

To make it do nothing for your caller only, change the argument it receives. The flag is a field of the extension class that the caller sets through a `parm` method:

```xpp
protected void printReport(CustInvoiceJour _custInvoiceJour)    // illustrative base method: it prints when it gets a record
{
    CustInvoiceJour forReport = _custInvoiceJour;

    if (abcSkipReport)              // set by the caller through abcParmSkipReport(true)
    {
        forReport = null;
    }
    next printReport(forReport);
}
```

### Members and state

- Reach a protected field of the target by bare name or as `this.field`. Private fields and methods are out of reach.
- An extension class may declare instance and `static` fields, with initialisers: `private Set abcProcessedRecIds = new Set(Types::Int64);`, `private static boolean abcSkipValidation;`. A `public` field is visible on the target (`myClass.abcState = 12;`); prefer `private` plus a `parm` method.
- To expose a protected base field, default the parameter to the bare field: `public TransDate abcParmTransDate(TransDate _transDate = transDate) { transDate = _transDate; return transDate; }`
- New methods: `public` when callers of the target use them, `private` for helpers. A `protected` one compiles with warning `NotCoCProtectedMethodInExtensionClass` and can be called only inside the class.
- Two extension classes that add a method of the same name don't compile (`DuplicatedMethodExtension`). This is why every added member carries the prefix.
- Macros (`#DEFINE`, `#LOCALMACRO`) are allowed in the declaration of an extension class, so the RunBase pack pattern (`#CurrentVersion`, `#CurrentList`) works there.
- A `new()` of the extension class (no parameters) doesn't run when the target is created. It runs before the first use of an extension member. Don't put anything in it that must happen at construction.
- `methodStr(…)` returns only the method name. `methodStr(<Target>, m)`, `methodStr(<Target>_<Model>_Extension, m)` and `formMethodStr(<Form>, m)` are the same string at run time; the class you name only has to contain `m` for the compiler.
- When two extension classes wrap one method, the wrappers run nested with the base innermost. Which one is outer isn't defined: don't depend on it.
- Don't put `[ExtensionOf]` on a class that holds only static event handlers. It compiles and does nothing.
- Data entity extension class: `[ExtensionOf(tableStr(<Entity>))]`. View: `viewStr(<View>)`.
- Functions for `Global` go in the model's existing `Global` extension class. A new one is declared `final static class`.
- To run the base call without security policies, write `unchecked (Uncheck::XDS) { next …; }`. Don't toggle `XDSServices.setXDSState`.

### Passing a value into standard code

Open a context around the call and read it in a wrapper deeper down. This also works in a wrapper of a `Global` function. That wrapper runs for every unqualified call in the application, so keep it cheap and let the context decide:

```xpp
[ExtensionOf(classStr(Global))]
final static class Global_ContosoCustomizations_Extension
{
    static str strRemoveCr(str s)
    {
        str              ret     = next strRemoveCr(s);
        ABCExportContext context = ABCExportContext::current();

        if (context && context.parmTrimResult())
        {
            ret = strLRTrim(ret);
        }
        return ret;
    }
}
```

The caller opens it with `using (ABCExportContext context = new ABCExportContext()) { context.parmTrimResult(true); … }`, and `next` may stand inside such a `using` block.

## Tables

### When your code is not called

- `insert_recordset`, `update_recordset` and `delete_from` **skip a wrapper** of `insert` / `update` / `delete` when the table itself doesn't override that method. The statement stays one set-based SQL statement. When the table overrides the method, the statement runs row by row and the wrappers run for every row.
- A data event handler (`Inserting`, `Inserted`, …) makes those statements run row by row and is called per row, unless the caller sets `skipEvents(true)`. `skipDataMethods(true)` alone doesn't stop the events. So a handler on a large table has a cost for every set-based statement on it.
- `doInsert()`, `doUpdate()` and `doDelete()` run neither wrappers nor data events.

Before you rely on a table wrapper, find out how the rows you care about are written.

### Saving a field

Assign the field before `next insert()` / `next update()`, or in `Inserting` / `Updating`. A value assigned after `next`, in `Inserted` / `Updated`, or in a post handler isn't saved.

### `orig()` during an update

| Place | `orig()` holds |
|---|---|
| Wrapper before `next update()`, `Updating` event, pre handler | Old values |
| `Updated` event | Old values |
| Wrapper after `next update()`, post handler | New values |

Read old values before `next`, or in the `Updated` event.

### Failing a validation

| Place | This fails it | This doesn't |
|---|---|---|
| Wrapper of `validateWrite` | `ret = next validateWrite(); ret = ret && checkFailed("…");` and return `ret` | |
| `ValidatingWrite` data event | `args.parmValidateResult(false)`; `ValidatedWrite` is then not raised | |
| `ValidatedWrite` data event | `args.parmValidateResult(false)` | `checkFailed("…")` alone |
| Post handler | `_args.setReturnValue(_args.getReturnValue() && checkFailed("…"))` | `checkFailed("…")` alone |

The validating and validated data events (`…Write`, `…Delete`) carry `ValidateEventArgs`.

### Display methods and computed columns

- A display or edit method on a table extension class is bound in metadata as **class name, dot, method**: `<DataMethod>SalesTable_ContosoCustomizations_Extension.abcDisplayCustGroupName</DataMethod>`. The plain method name is error `DataMethodNotFoundOnDataSource`, and only a full build reports it. A display method on a form data source extension class is bound the same way.
- A computed column method is always `public static` and is bound with `::`: `<ComputedFieldMethod>SalesOrderHeaderV2Entity_ContosoCustomizations_Extension::abcComputeTotalWeight</ComputedFieldMethod>`.
- `[SysClientCacheDataMethod]` takes `_updateOnWrite`, default `true`: the cached value is already refreshed on write without an argument.

### Queries

A query is extended declaratively (`AxQuerySimpleExtension`: data sources and ranges), not by an extension class.

## Event handlers and delegates

- Subscribe to a static delegate with `staticDelegateStr(C, name)` and to an instance delegate with `delegateStr(C, name)`. The other way round is a compile error.
- Find a delegate's parameter list by searching the declaring class for `delegate void <name>`. Delegates often sit on companion classes (`FinancialDimensionValueEntityDelegates`, `SRSPrintDestinationSettingsDelegates`).
- Answer an `EventHandlerResult` only inside your own `case`. Don't test `hasResult()` to decide, and never answer in a `default:` branch.
- `EventHandlerRejectResult`: call `reject()` or `checkFailed("Message text")`.
- `XppPrePostArgs.getArgNum(n)` is 1-based. Prefer `getArg(identifierStr(_name))`.
- `FormControlCancelEventArgs`: `cancel(true)` to cancel; the getter is `cancelled()`.
- To stop the action from a `Clicked` or `ValidatingDelete` handler, `throw error("…")` / `throw warning("…")` works.
- Handler classes are plain `final` classes with `public static void` methods. A static handler placed in an `[ExtensionOf]` class gives warning `EventHandlerInClassExtension`.
- Handler method names: `<Element>_on<Event>` for data and form events (`InventItemBarcode_onUpdating`), `<Class>_<Pre|Post>_<method>` for pre/post handlers.
- For a parameter the event interface forces on you: `[SuppressBPWarning('BPParameterNotUsed', 'Parameter required by the event interface')]`.

## Forms

Form extensions (`AxFormExtension`) hold no code; all code goes in `AxClass` files. The standard form needs no recompiling.

**Read `references/forms.md` before you write form code.** It covers how to reach form members from each extension level, adding a control at run time, per-form state for a handler class, and the arguments of `registerOverrideMethod`. The rules below apply to every form change.

### What to wrap, and the signatures

- Wrap a data source method in a `formDataSourceStr` extension. In a `formStr` extension it is a compile error with `next`, and without `next` it compiles as a new method that nothing calls.
- Data source `create`: `public void create(boolean _append)`.
- Data field lookup: `public void performFormLookup(xFormRun _form, FormControl _formControl)`.
- **Don't wrap or override `written()`** of a data source. It compiles and is never called on save. Subscribe to the `Written` event.

### Order of events

- `init`: `Initializing` is raised inside `super()`, before the data sources are initialised. `Initialized` handlers run **before** the code after `next init()` and before the form's own code after `super()`. Code that must run last goes after `next init()`.
- Click: wrapper code before `next clicked()` → `Clicking` → `Clicked` → wrapper code after `next`. Use `FormControlEventType::Clicking` to run before a click without CoC.
- An event handler attribute on a **non-static** method of a `formStr` extension works and runs on the form instance. Prefer an `init()` wrapper when you need form state.

### Stopping a save

- In a data source `ValidatingWrite` or `ValidatedWrite` handler, cast the args to `FormDataSourceCancelEventArgs` and call `cancel(true)`. Both block the save.
- `cancel(checkFailed("…"))` shows the message and **saves**, because `checkFailed` returns `false`. Write `checkFailed("…"); args.cancel(true);`, or `args.cancel(args.cancel() || shouldCancel)`.
- `Writing` can't cancel.

## Lookups

Take the first row that fits. The recipes are in `references/lookups.md`; read it before you write the lookup.

| # | Situation | Technique |
|---|---|---|
| 1 | A relation or EDT reference gives the right lookup | No code. |
| 2 | One control, standard or added by your form extension | Control `Lookup` event handler that ends with `CancelSuperCall()`. |
| 3 | A data source field shown in several controls, or the lookup needs form state | `registerOverrideMethod(methodStr(FormDataObject, lookup), …)` on the field object in `init()`. |
| 4 | `RecId` foreign key in a reference group | `lookupReference` on the field object **and** `resolveReference` on the reference group control. |
| 5 | Dialog field | `DialogField.registerOverrideMethod(methodStr(FormStringControl, lookup), …)` (`references/dialogs.md`). |
| 6 | Keep the standard lookup, run it differently | CoC on the data field, `next` inside. |
| 7 | The lookup is built by a table or class method | CoC on that method. It changes every form that uses it, so guard on the caller. If the method is `[Replaceable]`, the wrapper may skip `next`. |
| 8 | Several values in one control | `SysLookupMultiSelectCtrl`. |

## Dialogs

`references/dialogs.md` has the recipe for a field that your extension adds to a standard RunBase dialog, and the rules for SysOperation contracts and UI builders. In both, register overrides after the dialog exists (`dialogPostRun`, `postBuild`, `postRun`) and name the **target** class, not the extension class, in `methodStr(…)`.

## Patterns that compile and are wrong

You will meet these in existing project code. Don't copy them, and report them in a review.

| Pattern | Write instead |
|---|---|
| `Lookup` handler with no `CancelSuperCall()` | Cancel on the path that showed a lookup. |
| `cancel(checkFailed(…))` in a form data source handler | The record is saved. `checkFailed(…); args.cancel(true);` |
| Post handler or `ValidatedWrite` handler that only calls `checkFailed` | Write the result back: `setReturnValue(…)`, `parmValidateResult(false)`. |
| Field assigned after `next insert()` / `next update()` or in an `-ed` event | Assign it before `next`. |
| `resolveReference` registered on the field object | Register it on the reference group control. |
| Wrapper or override of data source `written()` | `Written` event. |
| Table `insert` / `update` / `delete` wrapper expected to cover set-based statements | Check whether the table overrides the method ([When your code is not called](#when-your-code-is-not-called)). |
| Conditional `next` in `write` / `validateWrite` of a data source added by a form extension | Legal there only. Check that no path drops the save by mistake. |
| `controlName("literal")`, `dataSource(<number>)` | `formControlStr`, `formDataSourceStr`. |
| `[ExtensionOf]` class that holds only static handlers | A plain handler class. |
| Two extension classes for one target | One class per target and concern. |
| Handler named `…_Post_insert` that carries `[PreHandlerFor]` | Re-read the attribute when you copy a handler; name it after what it is. |
| Commented-out `/* [DataEventHandler(…)] */` blocks | Dead code. Don't revive it without checking the fields it uses. |

Review checklist:

- Class: `final`, name ends in `_Extension`, one `[ExtensionOf]` that matches the level, no other extension class for the target.
- Wrapper: signature equals the base without default values, `static` kept, `next` once and unconditional, its result captured and returned.
- Fields to be saved are assigned before `next insert()` / `next update()`.
- Added members carry the prefix.
- Handlers: `public static void`, the right event tense, the failure written back (`setReturnValue`, `parmValidateResult`, `cancel(true)`).
- `Lookup` handler cancels the super call; a delegate subscriber answers only its case.
- No numeric data source index, no control or field name as a literal, no company id literal.
- Batch state is packed; contexts are opened with `using`.
- Full build with zero errors.

## Rules that were not run

These come from Microsoft's documentation, standard source, or production code that compiles. Verify them when the result depends on them.

- Data entities: the extension class on `tableStr(<Entity>)`, wrapping entity methods.
- Computed columns: the `::` binding.
- Views and query extensions.
- `unchecked (Uncheck::XDS)`: it compiles and runs; its effect on a policy wasn't checked.
- `[SysClientCacheDataMethod]`: the default was read from the attribute's source.
- The answering rules for `EventHandlerResult` and `EventHandlerRejectResult`, the `cancelled()` getter, and throwing from a `Clicked` or `ValidatingDelete` handler.
- A wrapper whose parameter names differ from the base.
- The `jumpRef` registration and the cross-company lookup in the reference files.
- A report data provider extension was run in X++ only; nothing was rendered in SSRS.
