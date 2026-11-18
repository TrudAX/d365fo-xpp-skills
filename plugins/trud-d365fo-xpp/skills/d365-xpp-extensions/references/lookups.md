# Lookup recipes

Pick the technique from the table in `SKILL.md` (*Lookups*), then copy the recipe here.

- [Control `Lookup` handler](#control-lookup-handler)
- [Field-level lookup in a `formStr` extension](#field-level-lookup-in-a-formstr-extension)
- [Reference group (`RecId` foreign key)](#reference-group-recid-foreign-key)
- [Keep the standard lookup and validation, without security policies](#keep-the-standard-lookup-and-validation-without-security-policies)
- [Multi-select](#multi-select)

## Control `Lookup` handler

Always call `CancelSuperCall()` on the path that showed your lookup. Without it, on a control that has a standard lookup, the user gets your lookup plus the warning "More than one form was opened at once for the lookup control."

For a lookup that depends on another control and another company: read that control's `valueStr()`, then `queryBuildDataSource.company(value)`.

## Field-level lookup in a `formStr` extension

One registration on the data source field serves every control bound to it, and the method has the form's state at hand.

```xpp
[ExtensionOf(formStr(SalesTable))]
final class SalesTableForm_ContosoCustomizations_Extension
{
    public void init()
    {
        next init();

        SalesTable_ds.object(fieldNum(SalesTable, CustGroup)).registerOverrideMethod(
            methodStr(FormDataObject, lookup),
            formMethodStr(SalesTable, abcCustGroupLookup),
            this);
    }

    public void abcCustGroupLookup(FormStringControl _control)
    {
        Query          query          = new Query();
        SysTableLookup sysTableLookup = SysTableLookup::newParameters(tableNum(CustGroup), _control);

        sysTableLookup.addLookupField(fieldNum(CustGroup, CustGroup));
        sysTableLookup.addLookupField(fieldNum(CustGroup, Name));
        query.addDataSource(tableNum(CustGroup)).addRange(fieldNum(CustGroup, PaymTermId)).value(SysQuery::valueNotEmptyString());
        sysTableLookup.parmQuery(query);
        sysTableLookup.performFormLookup();
    }
}
```

No `CancelSuperCall` is needed: the registered method replaces the kernel one.

## Reference group (`RecId` foreign key)

Two methods are involved, and they are hooked in different places:

- `lookupReference` shows the list (and serves type-ahead). Hook it on the **data source field**.
- `resolveReference` turns typed text into a record. Hook it on the **reference group control**. A `resolveReference` override on the field object, or a wrapper of it on the data field, is never called: typed text then resolves against all rows, and a row that your lookup hides can be typed and saved.

```xpp
public void init()
{
    next init();

    // the list: on the data source field
    <DataSource>_ds.object(fieldNum(<Table>, <RefField>)).registerOverrideMethod(
        methodStr(FormDataObject, lookupReference),
        formMethodStr(<Form>, abcCategoryLookupReference),
        this);

    // typed text: on the reference group control
    FormReferenceGroupControl categoryControl = this.design().controlName(formControlStr(<Form>, <ReferenceGroup>));

    categoryControl.registerOverrideMethod(
        methodStr(FormReferenceControl, resolveReference),   // FormReferenceGroupControl doesn't compile here
        formMethodStr(<Form>, abcCategoryResolveReference),
        this);
}

public Common abcCategoryLookupReference(FormReferenceControl _control)
{
    SysReferenceTableLookup lookup = SysReferenceTableLookup::newParameters(tableNum(EcoResCategory), _control);
    Query                   query  = new Query();

    query.addDataSource(tableNum(EcoResCategory)).addRange(fieldNum(EcoResCategory, IsActive)).value(queryValue(NoYes::Yes));
    lookup.addLookupfield(fieldNum(EcoResCategory, Name));
    lookup.parmQuery(query);
    return lookup.performFormLookup();
}

public Common abcCategoryResolveReference(FormReferenceGroupControl _control)
{
    EcoResCategory category;
    str            typed = _control.filterValue(
        AbsoluteFieldBinding::construct(fieldStr(EcoResCategory, Name), tableStr(EcoResCategory))).value();

    select firstonly category
        where category.Name == typed
           && category.IsActive == NoYes::Yes;

    return category;    // an empty buffer refuses the typed value
}
```

- A CoC wrapper of `resolveReference()` on the reference group control (`formControlStr`) is called for typed values too.
- Don't filter with a wrapper of `lookupReference()` on the control that calls `next` first and opens its own lookup after it: the user gets the standard lookup with all rows. Standard code contains this pattern; don't copy it.
- When you write the metadata by hand: a reference group shows nothing unless the related table's `AutoIdentification` field group lists the replacement key field and the reference group has a child control whose `DataRelationPath` is the relation name.

## Keep the standard lookup and validation, without security policies

Wrap `performFormLookup` (not `lookup`) and `validate` on the data field:

```xpp
[ExtensionOf(formDataFieldStr(CustTable, CustTable, CustGroup))]
final class CustTableForm_CustTableDS_CustGroup_ContosoCustomizations_Extension
{
    public void performFormLookup(xFormRun _form, FormControl _formControl)
    {
        unchecked (Uncheck::XDS)
        {
            next performFormLookup(_form, _formControl);
        }
    }

    public boolean validate()
    {
        boolean ret;

        unchecked (Uncheck::XDS)
        {
            ret = next validate();
        }
        return ret;
    }
}
```

## Multi-select

`SysLookupMultiSelectCtrl::construct(FormRun _frmRun, FormStringControl _namesCtrl, str _queryName, boolean _isMandatory = false, container _selectField = conNull())`

The control is a string control (here one that a form extension added), the query lists the rows to choose from, and the container names the table and field whose values are stored.

```xpp
[ExtensionOf(formStr(CustParameters))]
final class CustParametersForm_ContosoCustomizations_Extension
{
    private SysLookupMultiSelectCtrl abcCustGroupsCtrl;

    public void init()
    {
        next init();

        abcCustGroupsCtrl = SysLookupMultiSelectCtrl::construct(
            this,
            this.design().controlName(formControlStr(CustParameters, SalesParameters_ABCExcludedCustGroups)),
            queryStr(ABCCustGroupQuery),
            false,
            [tableNum(CustGroup), fieldNum(CustGroup, CustGroup)]);
    }

    public str abcSelectedCustGroups()
    {
        return con2Str(abcCustGroupsCtrl.getSelectedFieldValues(), ';');   // get() returns the record ids
    }
}
```

The control's `Modified` event is raised after the user presses **Select**; read the values there.
