# Dialog fields: RunBase and SysOperation

Read this before adding a field to the dialog of a standard RunBase class or a SysOperation contract, or before reacting to such a field. For a new RunBase class of your own, use the template in `d365-xpp-conventions`.

## RunBase: react to a field your extension added

Wrap `dialogPostRun` and register a method of the extension class. Name it through the **target** class in `methodStr(…)`; it may be `private`:

```xpp
[ExtensionOf(classStr(LedgerTransferOpening))]
final class LedgerTransferOpening_ContosoCustomizations_Extension
{
    private DialogField abcSkipZeroField;

    public Object dialog()
    {
        DialogRunbase dialog = next dialog();

        abcSkipZeroField = dialog.addField(extendedTypeStr(NoYesId), "Skip zero balances");
        return dialog;
    }

    public void dialogPostRun(DialogRunbase _dialog)
    {
        next dialogPostRun(_dialog);

        abcSkipZeroField.registerOverrideMethod(
            methodStr(FormCheckBoxControl, modified),
            methodStr(LedgerTransferOpening, abcSkipZeroModified),
            this);
    }

    private boolean abcSkipZeroModified(FormCheckBoxControl _control)
    {
        // _control.value() is the new value
        return true;
    }
}
```

A lookup on a dialog field is registered the same way, with `methodStr(FormStringControl, lookup)` as the first argument.

To keep the field's value between runs and in batch, add it to the pack list with the `SysPackExtensions` pattern, as for any field an extension adds to a RunBase class.

## SysOperation

- A `[DataMember]` `parm` method added by a contract extension gets its own dialog field, reaches the service method and survives `pack` / `unpack` of the controller.
- In a UI builder (or its extension), register overrides in a `postBuild()` or `postRun()` wrapper after `next`. Get the field with `this.bindInfo().getDialogField(this.dataContractObject(), methodStr(<Contract>, abcParmX))`: name the **target contract**, also for a method that the contract extension added.
