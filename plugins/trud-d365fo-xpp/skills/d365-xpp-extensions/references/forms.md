# Form extensions: recipes

Read this before writing code for a form, a form data source or a form control. The rules on what to wrap, the order of events and stopping a save are in `SKILL.md` (*Forms*).

- [Reaching the form and its members](#reaching-the-form-and-its-members)
- [Adding a control at run time](#adding-a-control-at-run-time)
- [Per-form state without a `formStr` extension](#per-form-state-without-a-formstr-extension)
- [`registerOverrideMethod`](#registeroverridemethod)

## Reaching the form and its members

- In a `formStr` extension, form variables, data sources, buffers and auto-declared controls are in scope by bare name, as in the form's own code: `SalesTable_ds`, `SalesTable`, `salesTableType`.
- In a data source, data field or control extension, use `element`: `element.args()`, `element.SalesLine_ds`, `element.salesTableType`, form methods, and methods that a `formStr` extension added (`element.abcUpdateFromLine()`). A bare `SalesLine_ds` isn't in scope there.
- **A statement can't start with `element.<DataSource>_ds.`:** `element.SalesLine_ds.refresh();` is compile error `IllegalToken` (Invalid token '('). In an expression it compiles (`str name = element.SalesLine_ds.name();`). For a statement, use `this` when it is the data source you extend (`this.refresh();`), or `element.dataSource(formDataSourceStr(SalesTable, SalesLine)).refresh();`, or a variable: `FormDataSource salesLine_ds = element.SalesLine_ds;`.
- From a static handler, call a method that a `formStr` extension added through a late-bound reference: `Object formObject = sender.formRun(); formObject.abcRefresh();`
- A control by name: `formRun.control(formRun.controlId(formControlStr(F, C)))` or `formRun.design().controlName(formControlStr(F, C))`. `valueStr()` works on any `FormControl`; `text()` / `value()` / `selection()` on typed controls.
- Data sources and controls added by your own form extension are valid targets: `formDataSourceStr(SalesTable, ABCSalesLineNote)`, `formControlStr(SalesTable, ABCPrintLabelButton)`.

## Adding a control at run time

Add the control in the `AxFormExtension` whenever it isn't conditional. When it must be conditional, build it in the `Initializing` handler:

```xpp
[FormEventHandler(formStr(SalesCreateOrder), FormEventType::Initializing)]
public static void SalesCreateOrder_onInitializing(xFormRun _sender, FormEventArgs _e)
{
    FormBuildGroupControl buildGroup = _sender.form().design(1).control(
        formControlStr(SalesCreateOrder, groupSalesOrder)) as FormBuildGroupControl;

    if (buildGroup)
    {
        FormBuildStringControl ctrl = buildGroup.addControl(FormControlType::String, 'ABCCampaignNote') as FormBuildStringControl;

        ctrl.extendedDataType(extendedTypeNum(Description));
        ctrl.label("Campaign note");
    }
}
// read back later: formRun.control(formRun.controlId('ABCCampaignNote'))
```

`group` is an X++ keyword and can't be a variable name (`InvalidVariableNameXppKeyword`). In an `Initialized` handler, add to the run-time group instead: `FormGroupControl.addControl(…)`. Both ways work.

## Per-form state without a `formStr` extension

Member variables on a `formStr` extension class are the simple way to keep state per form. When there is only a handler class, register an instance of it on the form:

```xpp
public final class CustTableForm_ContosoCustomizations_EventHandler
{
    private boolean abcCreditChecked;       // per-form state

    public void new(FormRun _formRun)
    {
        _formRun.registerExtensionInstance(classStr(CustTableForm_ContosoCustomizations_EventHandler), this);
    }

    [FormEventHandler(formStr(CustTable), FormEventType::Initializing)]
    public static void CustTable_onInitializing(xFormRun _sender, FormEventArgs _e)
    {
        new CustTableForm_ContosoCustomizations_EventHandler(_sender as FormRun);
    }

    [FormEventHandler(formStr(CustTable), FormEventType::Initialized)]
    public static void CustTable_onInitialized(xFormRun _sender, FormEventArgs _e)
    {
        FormRun formRun = _sender as FormRun;
        CustTableForm_ContosoCustomizations_EventHandler instance =
            formRun.getExtensionInstance(classStr(CustTableForm_ContosoCustomizations_EventHandler));

        instance.abcCreditChecked = false;      // use the instance from here on
    }
}
```

## `registerOverrideMethod`

Register after the object exists: after `next init()` of the form or data source, in an `Initialized` handler, or in `dialogPostRun` / `postBuild` / `postRun` for dialogs.

First argument and the signature of your method:

| Override | Register on | First argument | Your method |
|---|---|---|---|
| Lookup of a data source field | The field object, `<DataSource>_ds.object(fieldNum(T, F))` | `methodStr(FormDataObject, lookup)` | `public void abcLookup(FormStringControl _control)`: it receives the **calling control**, not the field object. One registration serves every control bound to the field. |
| Reference lookup | The field object | `methodStr(FormDataObject, lookupReference)` | `public Common abcLookupReference(FormReferenceControl _control)` |
| Reference resolve | The **reference group control**, never the field | `methodStr(FormReferenceControl, resolveReference)` | `public Common abcResolveReference(FormReferenceGroupControl _control)` |
| Jump ref | The field object | `methodStr(FormDataObject, jumpRef)` | `private void abcJumpRef(FormDataObject _fieldObject)` |

The method may be `private`. Second and third argument, by where the method lives:

| Third argument | Second argument |
|---|---|
| `this` in a `formStr` extension | `formMethodStr(<Form>, abcMethod)`: the form name, because the method is part of the form |
| The `FormRun` (`sender`) in a static handler | `methodStr(<Form>Form_<Model>_Extension, abcMethod)` |
| An instance of a helper class | `methodStr(ABCHelper, method)`; the helper reaches the form through `_control.formRun()` |
| `this` in a RunBase class, a UI builder, or an extension of one | `methodStr(<TargetClass>, abcMethod)` |
