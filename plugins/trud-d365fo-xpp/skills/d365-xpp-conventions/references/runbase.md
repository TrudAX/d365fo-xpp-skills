# RunBase class template

A dialog operation that can also run in batch. The template has three optional parts; keep only the ones the task needs:

- **Query** - the user selects records with the standard *Records to include* filter, `run()` loops over them with a progress bar.
- **Caller** - the class runs from a button on a form and works on the selected record (or records).
- **File upload** - the dialog has a file upload control and `run()` reads the file.

Names in the template: class `ABCVehicleBrandUpdate`, query table `ABCVehicleBrand`, one dialog parameter `ABCVehicleBrandId newBrandId`. Strings are literal text (no labels unless the user asks for them).

## Class declaration and fixed methods

```xpp
public class ABCVehicleBrandUpdate extends RunBaseBatch implements BatchRetryable
{
    ABCVehicleBrandId       newBrandId;          // one member per dialog parameter...
    DialogField             dlgNewBrandId;       // ...and its dialog field

    QueryRun                queryRun;            // query part only

    #AviFiles                                    // query part only
    #define.CurrentVersion(1)
    #localmacro.CurrentList
        newBrandId
    #endmacro
}

public static ABCVehicleBrandUpdate construct()
{
    return new ABCVehicleBrandUpdate();
}

public static ClassDescription description()
{
    return "Update vehicle brands";
}

public static void main(Args _args)
{
    ABCVehicleBrandUpdate runObject = ABCVehicleBrandUpdate::construct();

    if (runObject.prompt())
    {
        runObject.runOperation();
    }
}

public Object dialog()
{
    DialogRunbase dialog = super();

    dlgNewBrandId = dialog.addFieldValue(extendedTypeStr(ABCVehicleBrandId), newBrandId, "New brand", "The brand to set on the selected records");
    dlgNewBrandId.mandatory_RU(true);       // only for mandatory parameters

    return dialog;
}

public boolean getFromDialog()
{
    newBrandId = dlgNewBrandId.value();

    return super();
}

public ABCVehicleBrandId parmNewBrandId(ABCVehicleBrandId _newBrandId = newBrandId)
{
    newBrandId = _newBrandId;
    return newBrandId;
}

public container pack()
{
    return [#CurrentVersion, #CurrentList];
}

public boolean unpack(container _packedClass)
{
    Version version = RunBase::getVersion(_packedClass);

    switch (version)
    {
        case #CurrentVersion:
            [version, #CurrentList] = _packedClass;
            break;

        default:
            return false;
    }
    return true;
}

public boolean canGoBatch()
{
    return false;       // true only if the user asked for batch, or the job is long-running or scheduled
}

public boolean canRunInNewSession()
{
    return false;
}

public boolean isRetryable()
{
    return true;
}

public void run()
{
    if (!this.validate())
    {
        throw error("Validation failed");
    }

    ttsbegin;
    // the work
    ttscommit;
}
```

- `#CurrentList` lists the members that are saved between runs (usually every dialog parameter). Raise `CurrentVersion` when the list changes.
- `dialog.addFieldValue(extendedTypeStr(EDT), value, "Label", "Help")`: pass label and help only when they differ from the EDT's.
- A dialog with no parameters still needs `pack`/`unpack`: `#localmacro.CurrentList` with no members doesn't compile, so drop the macro and pack only `[#CurrentVersion]`.
- If `canGoBatch()` returns true, `run()` must not use client-only things: form data sources of the caller, `Box::`, file downloads.

## Query part

Add `queryRun` and `#AviFiles` (for `#AviSearch`) to the declaration, and:

```xpp
public void initParmDefault()
{
    super();
    this.initQuery();
}

public void initQuery()
{
    Query                   query = new Query();
    QueryBuildDataSource    qbds  = query.addDataSource(tableNum(ABCVehicleBrand));

    SysQuery::findOrCreateRange(qbds, fieldNum(ABCVehicleBrand, RecId)).status(RangeStatus::Hidden);
    queryRun = new QueryRun(query);
}

public QueryRun queryRun()
{
    return queryRun;
}

public boolean showQueryValues()
{
    return true;
}

public container pack()
{
    return [#CurrentVersion, #CurrentList, queryRun.pack()];
}

public boolean unpack(container _packedClass)
{
    Version     version = RunBase::getVersion(_packedClass);
    container   queryCon;

    switch (version)
    {
        case #CurrentVersion:
            [version, #CurrentList, queryCon] = _packedClass;
            if (SysQuery::isPackedOk(queryCon))
            {
                queryRun = new QueryRun(queryCon);
            }
            else
            {
                this.initQuery();
            }
            break;

        default:
            return false;
    }
    return true;
}

public void run()
{
    ABCVehicleBrand     vehicleBrand;
    int                 processedCounter;

    this.progressInit(RunBase::getDescription(classIdGet(this)), SysQuery::countTotal(queryRun), #AviSearch);

    while (queryRun.next())
    {
        vehicleBrand = queryRun.get(tableNum(ABCVehicleBrand));
        // process the record; ttsbegin/ttscommit per record or per batch of records
        processedCounter++;
        progress.incCount();
    }
    info(strFmt("%1 record(s) processed", processedCounter));
}
```

## Caller part

The class runs from an action menu item on a form; `_args.record()` is the current record.

```xpp
    ABCVehicleBrand     callerVehicleBrand;        // in the class declaration

public ABCVehicleBrand parmCallerVehicleBrand(ABCVehicleBrand _callerVehicleBrand = callerVehicleBrand)
{
    callerVehicleBrand = _callerVehicleBrand;
    return callerVehicleBrand;
}

public static void main(Args _args)
{
    ABCVehicleBrandUpdate runObject = ABCVehicleBrandUpdate::construct();

    if (!_args || _args.dataset() != tableNum(ABCVehicleBrand))
    {
        throw error(Error::missingRecord(funcName()));
    }
    runObject.parmCallerVehicleBrand(_args.record());

    // With the query part: restrict the query to the caller. getLast() first, because prompt()
    // calls it otherwise and would overwrite the range with the last saved query.
    runObject.getLast();
    SysQuery::findOrCreateRange(runObject.queryRun().query().dataSourceTable(tableNum(ABCVehicleBrand)),
                                fieldNum(ABCVehicleBrand, RecId)).value(queryValue(_args.record().RecId));

    if (runObject.prompt())
    {
        runObject.runOperation();
    }
}
```

**Several selected records** (the menu item button on a grid with multi-select): loop over the marked records of the caller's form data source in `run()`, and keep `canGoBatch()` false because the form data source doesn't exist in batch.

```xpp
public void run()
{
    FormDataSource      formDataSource = FormDataUtil::getFormDataSource(callerVehicleBrand);
    ABCVehicleBrand     vehicleBrandLocal;
    ABCVehicleBrand     vehicleBrandUpd;
    int                 processedCounter;

    for (vehicleBrandLocal = formDataSource.getFirst(true) ? formDataSource.getFirst(true) : formDataSource.cursor();
         vehicleBrandLocal;
         vehicleBrandLocal = formDataSource.getNext())
    {
        ttsbegin;
        select firstonly forupdate vehicleBrandUpd
            where vehicleBrandUpd.RecId == vehicleBrandLocal.RecId;
        // update vehicleBrandUpd
        ttscommit;
        processedCounter++;
    }
    formDataSource.research(true);
    info(strFmt("%1 record(s) processed", processedCounter));
}
```

In `dialog()`, show what will be processed: `dialog.addText(strFmt("Process %1 record(s)", count))` with the same loop counting the marked records.

## File upload part

Members in the class declaration:

```xpp
    DialogRunbase                       dialog;
    FileUploadTemporaryStorageResult    fileUploadResult;
    private const str FileUploadName = 'FileUpload';
    private const str OkButtonName   = 'OkButton';
```

```xpp
public Object dialog()
{
    DialogGroup         dialogGroup;
    FormBuildControl    formBuildControl;
    FileUploadBuild     dialogFileUpload;

    dialog = super();

    dialogGroup      = dialog.addGroup("File");
    formBuildControl = dialog.formBuildDesign().control(dialogGroup.name());
    dialogFileUpload = formBuildControl.addControlEx(classStr(FileUpload), FileUploadName);
    dialogFileUpload.style(FileUploadStyle::MinimalWithFilename);
    dialogFileUpload.baseFileUploadStrategyClassName(classStr(FileUploadTemporaryStorageStrategy));
    dialogFileUpload.fileTypesAccepted('.csv');     // '.xlsx' for Excel
    dialogFileUpload.fileNameLabel("File name");

    return dialog;
}

public boolean getFromDialog()
{
    FileUpload fileUploadControl = this.getFormControl(dialog, FileUploadName);

    fileUploadResult = fileUploadControl.getFileUploadResult();

    return super();
}

// The OK button stays disabled until the upload has finished.
public void dialogPostRun(DialogRunbase _dialog)
{
    FileUpload fileUpload = this.getFormControl(_dialog, FileUploadName);

    super(_dialog);
    fileUpload.notifyUploadCompleted += eventhandler(this.uploadCompleted);
    this.setDialogOkButtonEnabled(_dialog, false);
}

protected void uploadCompleted()
{
    FileUpload fileUpload = this.getFormControl(dialog, FileUploadName);

    fileUpload.notifyUploadCompleted -= eventhandler(this.uploadCompleted);
    this.setDialogOkButtonEnabled(dialog, true);
}

protected void setDialogOkButtonEnabled(DialogRunbase _dialog, boolean _isEnabled)
{
    FormControl okButtonControl = this.getFormControl(_dialog, OkButtonName);

    if (okButtonControl)
    {
        okButtonControl.enabled(_isEnabled);
    }
}

protected FormControl getFormControl(DialogRunbase _dialog, str _controlName)
{
    return _dialog.formRun().control(_dialog.formRun().controlId(_controlName));
}

public void run()
{
    System.IO.Stream    stream;
    CommaTextStreamIo   textIo;
    container           line;

    if (!fileUploadResult || !fileUploadResult.getUploadStatus())
    {
        throw error("File is empty");
    }
    try
    {
        stream = fileUploadResult.openResult();
        textIo = CommaTextStreamIo::constructForRead(stream);
        textIo.read();                                  // header row
        ttsbegin;
        for (line = textIo.read(); textIo.status() == IO_Status::Ok; line = textIo.read())
        {
            // conPeek(line, 1), conPeek(line, 2), ...
        }
        ttscommit;
    }
    finally
    {
        fileUploadResult.deleteResult();
    }
}
```

- A class with a file upload can't run in batch (the file is in the user's session): keep `canGoBatch()` false.
- If the model references the DEVCommon package (TrudAX/XppTools), read the file with `DEVFileReaderCSV` (`readCSVFile(stream)`, `readHeaderRow()`, `readNextRow()`, `getStringByName('Column')`) or `DEVFileReaderExcel` (`openFile(stream)`, same row methods) instead of `CommaTextStreamIo`.

## Menu item

An action menu item with the class name, `ObjectType` Class, `Label` = `description()`, `HelpText` "<label> operation". For the caller part, the form button is a `MenuFunctionButton` with `MenuItemName` = the menu item, `MenuItemType` Action, `DataSource` = the caller data source (and `MultiSelect` Yes for several records).
