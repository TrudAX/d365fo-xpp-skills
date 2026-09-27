# X++ compile diagnostics: meanings and fixes

The monikers are taken from real xppc output: `build.xml` → `<Moniker>`, shown in brackets in the report. The messages are abbreviated.

## Contents
- [Errors seen in practice](#errors-seen-in-practice)
- [Chain of Command and extensions](#chain-of-command-and-extensions)
- [Warnings worth fixing in new code](#warnings-worth-fixing-in-new-code)
- [Warnings usually left alone](#warnings-usually-left-alone)
- [Metadata and form diagnostics](#metadata-and-form-diagnostics)
- [Not reported by xppc](#not-reported-by-xppc)

## Errors seen in practice

| Moniker | Message (abbrev.) | Usual cause and fix |
|---|---|---|
| `ExpectedToken` | `';' expected.` | Syntax error. The reported position is often the token **after** the real problem, so check the previous line for a missing `;`, `)` or `}`. One syntax error can hide the other errors in the same method: fix it first and recompile. |
| `NotDeclared` | `'x' is not declared.` | Typo, missing local variable declaration, or a class member that isn't declared in the class declaration. X++ is case-insensitive, so look for a spelling difference, not a casing difference. |
| `ClassDoesNotContainMethod` | `Table 'SalesTable' does not contain a definition for method 'm' and no extension method ...` | Wrong method name, a method on a different type, or an extension class that isn't in this package or its references. Check the real API in the element XML under `PackagesLocalDirectory\<pkg>\<model>\AxClass\`, or with Grep. |
| `TableDoesNotContainField` | `Table 'T' does not contain a field named 'F'.` | The field name is wrong. Extension fields keep their own names (e.g. `ABCPackagingType`), and the table extension must be in this package or in a referenced one. Fields are listed in `AxTable\T.xml` or `AxTableExtension\T.<suffix>.xml`. |
| `ParameterMissing` | Required parameter missing in a call | Often an `[other]` error after you changed a method signature. Update every caller, or give the new parameter a default value. |
| `ClassDoesNotExist` | `Class 'X' does not exist.` | Typo, an element that isn't created yet, or an element in a package that this package doesn't reference (`Descriptor\<Model>.xml` → `ModuleReferences`). Don't add package references without asking the user. |
| `ChainOfCommandNextCallMustBeUnconditioned` | `Call to 'next' should be done only once and unconditionally.` | A CoC wrapper must call `next` exactly once and not inside `if` or `try` blocks. Store the result in a variable, then apply your logic before or after the call. |

## Chain of Command and extensions

| Moniker | Meaning and fix |
|---|---|
| `NextCallParamtersMismatch` | The wrapper must repeat the base method's full signature, including optional parameters with the same default values, and pass all of them to `next`. |
| `NotCoCProtectedMethodInExtensionClass` | You added a new `protected` method in a `final` extension class. Make it `private` or `public`. Only protected methods that wrap a base method are allowed. |
| `ChainOfCommandInInternalMethodIsNotSupported` | You can't wrap `internal` or `InternalUseOnly` methods. Find a public or protected hook, a delegate, or an event instead. |
| `DerivedMethodMustNotBeStatic` | The method name clashes with an instance method of the base (e.g. `Common.clear`). Rename it. |
| `EventHandlerInClassExtension` | Event handler subscriptions belong in a regular class, not in an `[ExtensionOf]` class. Move them. |
| `InternalUseOnly*Inaccessible` | You called an API that Microsoft marked internal. It may compile only as a warning, but it's not supported: find a public API instead. |

Also remember: an extension class must be `final`, named `<Something>_Extension`, and carry `[ExtensionOf(classStr(X))]` (or `tableStr`, `formStr`, `formDataSourceStr(...)`, and so on).

## Warnings worth fixing in new code

| Moniker | Fix |
|---|---|
| `CastFromExtensibleEnum`, `ExtensibleEnumInNumericalAssignment`, `ExtensibleEnumInComparisonAgainstNumericalValue` | Never treat an extensible enum as an int. Compare with the enum literal (`SalesStatus::Backorder`). Convert with `enum2Symbol`/`symbol2Enum` or `enum2Str`. |
| `ObsoleteEntityUsage`, `ObsoleteEntityUsageWithReason`, `ReferencedObjectIsObsolete`, `IntrinsicArgIsMarkedAsObsolete` | Use the replacement named in the message. |
| `TypeConversionLosesRange`, `TypeConversionLosesRangeAndPrecision`, `IntegerDivAndModLosePrecision` | Use the right type (int64, real, EDT) or convert explicitly (`real2int`, `any2Int64`). |
| `UnreachableStatement` | Remove the dead code after `return` or `throw`, or fix the control flow. |
| `ImplicitConversionFromDateToUtcDateTime` | Use `DateTimeUtil::newDateTime(date, time)`. |
| `ConstructorMustCallSuper` | Call `super()` on every path in `new()`. |
| `ServerKeywordDeprecated`, `ClientKeywordDeprecated` | Drop `server`/`client` from new method signatures. |

## Warnings usually left alone

Warnings in existing code that you didn't touch are baseline noise; a large customization package can have several hundred. Leave them unless the user asks. Examples: `TaskListItem` (TODO comments; informational), `IsRuntimeServicesMode`.

## Metadata and form diagnostics

These have paths like `AxTable/Name/Fields/F` and no line number. The fix is in element properties, not code.

| Moniker | Fix |
|---|---|
| `ErrorFormDesignPatternUnspecified`, `ErrorFormControlPatternUnspecified` | New forms and control groups need a pattern (VS: *Apply pattern*), or an explicit *Custom* pattern. |
| `DuplicateLabelDetected` | Two entities share a label. Warning only. |
| `RelationHasNoContraints`, `InvalidProperty` (relation type) | Complete the table relation: add constraints, and set `RelationshipType` (Association/Aggregation/Composition). |
| `ConfigurationKeyDoesNotExist` | The referenced configuration key is missing, or it's in an unreferenced package. |
| `FieldGroupWithNoFields`, `ClusteredIndexMaxSize`, `ViewWithIndexes`, `DataEntityRelationRelatedDataEntityCardinalityMustBeSpecified` | Fix the property named in the message. |

## Not reported by xppc

- **Missing labels.** Nothing in the compile catches them; see `-CheckLabels`. Label files are `Id=Text` lines followed by an optional ` ;comment` line, UTF-8 with BOM, CRLF.
- **Database sync problems**, such as index or field-length changes on existing data. These show up only when the user syncs.
- **Best-practice rules.** VS runs these only when the project enables them.
- **Runtime-only issues**, such as a menu item without a privilege, security not assigned to a duty or role, or a data entity mapping. Check these by review.
