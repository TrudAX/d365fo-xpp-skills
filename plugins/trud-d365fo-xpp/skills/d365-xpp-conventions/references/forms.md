# Setup form layouts

Two layouts cover setup tables. Both examples below compiled cleanly and match their patterns. Copy the structure, rename, and bind your fields.

Common rules:

- Form name = table name (a second form for the same table gets a suffix). `Caption` = table label. The root data source = the table, `InsertIfEmpty` No. Design `DataSource` and `TitleDataSource` = the root data source.
- Grid columns come from the table's `Overview` field group: a group control named after the field group, with `DataGroup` set, holding one control per field. Name field controls `<Group>_<Field>`.
- The form class is just `[Form] public class <Form> extends FormRun {}` unless the user asks for logic.
- After writing the form, run `<skill-dir>\scripts\Invoke-XppFormPattern.ps1 -Form <file> -Apply`. It sets every property the pattern enforces (`Style`, `WidthMode`, `HeightMode`, `Width`, `FrameType`, `ColumnsMode`, `PatternVersion`...), so you only have to get the controls, their order, names and data binding right.
- Form control properties follow the same strict order as all metadata XML: the base properties (`Name`, then the rest alphabetically: `AllowEdit`, `AutoDeclaration`, `HeightMode`, `Type`, `Width`, `WidthMode`...), then `FormControlExtension`, then `Controls`, then the type-specific properties alphabetically (`ButtonDisplay`, `Command`, `DataField`, `DataGroup`, `DataSource`, `NormalImage`...). A property in the wrong place is silently dropped.

## Simple list (`SimpleList`)

For a setup table whose fields all fit in a grid row. Action pane, quick filter, editable grid. The whole file:

```xml
<?xml version="1.0" encoding="utf-8"?>
<AxForm xmlns:i="http://www.w3.org/2001/XMLSchema-instance" xmlns="Microsoft.Dynamics.AX.Metadata.V6">
	<Name>ABCVehicleBrand</Name>
	<SourceCode>
		<Methods xmlns="">
			<Method>
				<Name>classDeclaration</Name>
				<Source><![CDATA[
[Form]
public class ABCVehicleBrand extends FormRun
{
}
]]></Source>
			</Method>
		</Methods>
		<DataSources xmlns="" />
		<DataControls xmlns="" />
		<Members xmlns="" />
	</SourceCode>
	<DataSources>
		<AxFormDataSource xmlns="">
			<Name>ABCVehicleBrand</Name>
			<Table>ABCVehicleBrand</Table>
			<Fields />
			<ReferencedDataSources />
			<InsertIfEmpty>No</InsertIfEmpty>
			<DataSourceLinks />
			<DerivedDataSources />
		</AxFormDataSource>
	</DataSources>
	<Design>
		<Caption xmlns="">Vehicle brands</Caption>
		<DataSource xmlns="">ABCVehicleBrand</DataSource>
		<Pattern xmlns="">SimpleList</Pattern>
		<PatternVersion xmlns="">1.1</PatternVersion>
		<Style xmlns="">SimpleList</Style>
		<TitleDataSource xmlns="">ABCVehicleBrand</TitleDataSource>
		<Controls xmlns="">
			<AxFormControl xmlns=""
				i:type="AxFormActionPaneControl">
				<Name>MainActionPane</Name>
				<Type>ActionPane</Type>
				<FormControlExtension
					i:nil="true" />
				<Controls />
			</AxFormControl>
			<AxFormControl xmlns=""
				i:type="AxFormGroupControl">
				<Name>FilterGroup</Name>
				<Pattern>CustomAndQuickFilters</Pattern>
				<PatternVersion>1.1</PatternVersion>
				<Type>Group</Type>
				<WidthMode>SizeToAvailable</WidthMode>
				<FormControlExtension
					i:nil="true" />
				<Controls>
					<AxFormControl>
						<Name>QuickFilter</Name>
						<FormControlExtension>
							<Name>QuickFilterControl</Name>
							<ExtensionComponents />
							<ExtensionProperties>
								<AxFormControlExtensionProperty>
									<Name>targetControlName</Name>
									<Type>String</Type>
									<Value>MainGrid</Value>
								</AxFormControlExtensionProperty>
								<AxFormControlExtensionProperty>
									<Name>placeholderText</Name>
									<Type>String</Type>
								</AxFormControlExtensionProperty>
								<AxFormControlExtensionProperty>
									<Name>defaultColumnName</Name>
									<Type>String</Type>
								</AxFormControlExtensionProperty>
							</ExtensionProperties>
						</FormControlExtension>
					</AxFormControl>
				</Controls>
				<ArrangeMethod>HorizontalLeft</ArrangeMethod>
				<FrameType>None</FrameType>
				<Style>CustomFilter</Style>
				<ViewEditMode>Edit</ViewEditMode>
			</AxFormControl>
			<AxFormControl xmlns=""
				i:type="AxFormGridControl">
				<Name>MainGrid</Name>
				<Type>Grid</Type>
				<FormControlExtension
					i:nil="true" />
				<Controls>
					<AxFormControl xmlns=""
						i:type="AxFormGroupControl">
						<Name>Overview</Name>
						<Type>Group</Type>
						<FormControlExtension
							i:nil="true" />
						<Controls>
							<AxFormControl xmlns=""
								i:type="AxFormStringControl">
								<Name>Overview_VehicleBrandId</Name>
								<Type>String</Type>
								<FormControlExtension
									i:nil="true" />
								<DataField>VehicleBrandId</DataField>
								<DataSource>ABCVehicleBrand</DataSource>
							</AxFormControl>
							<AxFormControl xmlns=""
								i:type="AxFormStringControl">
								<Name>Overview_Description</Name>
								<Type>String</Type>
								<FormControlExtension
									i:nil="true" />
								<DataField>Description</DataField>
								<DataSource>ABCVehicleBrand</DataSource>
							</AxFormControl>
						</Controls>
						<DataGroup>Overview</DataGroup>
						<DataSource>ABCVehicleBrand</DataSource>
					</AxFormControl>
				</Controls>
				<DataSource>ABCVehicleBrand</DataSource>
				<Style>Tabular</Style>
			</AxFormControl>
		</Controls>
	</Design>
	<Parts />
</AxForm>
```

## List and details with a tabular grid (`SimpleListDetails-Grid`)

For a record with more fields than a grid row holds, or with lines. Left: navigation list (quick filter + read-only grid of the `Overview` group). Right: header fields, then FastTabs.

Create these field groups on the table if they're missing:

| Field group | Label | Used by |
|---|---|---|
| `Overview` | Overview | navigation grid (key + description) |
| `DetailsHeaderGroup` | Details header | header above the FastTabs |
| one per details FastTab, e.g. `General` | the tab caption | a group control inside the tab page |

FastTab kinds:

- **Fields tab page:** `<Caption>TabPage` (`GeneralTabPage`), `Pattern` `FieldsFieldGroups`, `DataSource` = root data source, holding group controls bound to field groups.
- **Lines tab page:** `TabPage<Caption>` (`TabPageModels`), `Pattern` `ToolbarList`: an action pane `ActionPaneControl<Caption>` with a button group `NewDeleteGroup<Caption>` (`DataSource` = lines data source) holding New and Delete command buttons, then a grid `Grid<Caption>` bound to the lines data source. The lines data source has `JoinSource` = root data source; the lines table needs a relation to the header table (here `ABCVehicleModel.VehicleBrandId`).

The data sources and design (the root element, `Name` and `SourceCode` are as in the simple list):

```xml
	<DataSources>
		<AxFormDataSource xmlns="">
			<Name>ABCVehicleBrand</Name>
			<Table>ABCVehicleBrand</Table>
			<Fields />
			<ReferencedDataSources />
			<InsertIfEmpty>No</InsertIfEmpty>
			<DataSourceLinks />
			<DerivedDataSources />
		</AxFormDataSource>
		<AxFormDataSource xmlns="">
			<Name>ABCVehicleModel</Name>
			<Table>ABCVehicleModel</Table>
			<Fields />
			<ReferencedDataSources />
			<JoinSource>ABCVehicleBrand</JoinSource>
			<InsertIfEmpty>No</InsertIfEmpty>
			<DataSourceLinks />
			<DerivedDataSources />
		</AxFormDataSource>
	</DataSources>
	<Design>
		<Caption xmlns="">Vehicle brands</Caption>
		<DataSource xmlns="">ABCVehicleBrand</DataSource>
		<Pattern xmlns="">SimpleListDetails-Grid</Pattern>
		<PatternVersion xmlns="">1.4</PatternVersion>
		<Style xmlns="">SimpleListDetails</Style>
		<TitleDataSource xmlns="">ABCVehicleBrand</TitleDataSource>
		<Controls xmlns="">
			<AxFormControl xmlns=""
				i:type="AxFormActionPaneControl">
				<Name>MainActionPane</Name>
				<Type>ActionPane</Type>
				<FormControlExtension
					i:nil="true" />
				<Controls>
					<AxFormControl xmlns=""
						i:type="AxFormButtonGroupControl">
						<Name>FormButtonGroupControlMain</Name>
						<Type>ButtonGroup</Type>
						<FormControlExtension
							i:nil="true" />
						<Controls />
					</AxFormControl>
				</Controls>
			</AxFormControl>
			<AxFormControl xmlns=""
				i:type="AxFormGroupControl">
				<Name>NavigationListGroup</Name>
				<HeightMode>SizeToAvailable</HeightMode>
				<Type>Group</Type>
				<Width>300</Width>
				<WidthMode>Manual</WidthMode>
				<FormControlExtension
					i:nil="true" />
				<Controls>
					<AxFormControl>
						<Name>NavListQuickFilter</Name>
						<WidthMode>SizeToAvailable</WidthMode>
						<FormControlExtension>
							<Name>QuickFilterControl</Name>
							<ExtensionComponents />
							<ExtensionProperties>
								<AxFormControlExtensionProperty>
									<Name>targetControlName</Name>
									<Type>String</Type>
									<Value>MainGrid</Value>
								</AxFormControlExtensionProperty>
								<AxFormControlExtensionProperty>
									<Name>placeholderText</Name>
									<Type>String</Type>
								</AxFormControlExtensionProperty>
								<AxFormControlExtensionProperty>
									<Name>defaultColumnName</Name>
									<Type>String</Type>
								</AxFormControlExtensionProperty>
							</ExtensionProperties>
						</FormControlExtension>
					</AxFormControl>
					<AxFormControl xmlns=""
						i:type="AxFormGridControl">
						<Name>MainGrid</Name>
						<AllowEdit>No</AllowEdit>
						<Type>Grid</Type>
						<FormControlExtension
							i:nil="true" />
						<Controls>
							<AxFormControl xmlns=""
								i:type="AxFormGroupControl">
								<Name>Overview</Name>
								<Type>Group</Type>
								<FormControlExtension
									i:nil="true" />
								<Controls>
									<AxFormControl xmlns=""
										i:type="AxFormStringControl">
										<Name>Overview_VehicleBrandId</Name>
										<Type>String</Type>
										<FormControlExtension
											i:nil="true" />
										<DataField>VehicleBrandId</DataField>
										<DataSource>ABCVehicleBrand</DataSource>
									</AxFormControl>
									<AxFormControl xmlns=""
										i:type="AxFormStringControl">
										<Name>Overview_Description</Name>
										<Type>String</Type>
										<FormControlExtension
											i:nil="true" />
										<DataField>Description</DataField>
										<DataSource>ABCVehicleBrand</DataSource>
									</AxFormControl>
								</Controls>
								<DataGroup>Overview</DataGroup>
								<DataSource>ABCVehicleBrand</DataSource>
							</AxFormControl>
						</Controls>
						<DataSource>ABCVehicleBrand</DataSource>
						<MultiSelect>No</MultiSelect>
						<ShowRowLabels>No</ShowRowLabels>
						<Style>Tabular</Style>
					</AxFormControl>
				</Controls>
				<FrameType>None</FrameType>
				<Style>SidePanel</Style>
			</AxFormControl>
			<AxFormControl xmlns=""
				i:type="AxFormGroupControl">
				<Name>VerticalSplitterGroup</Name>
				<Type>Group</Type>
				<FormControlExtension
					i:nil="true" />
				<Controls />
				<Style>SplitterVerticalContainer</Style>
			</AxFormControl>
			<AxFormControl xmlns=""
				i:type="AxFormGroupControl">
				<Name>DetailsHeaderGroup</Name>
				<Pattern>FieldsFieldGroups</Pattern>
				<PatternVersion>1.1</PatternVersion>
				<Type>Group</Type>
				<WidthMode>SizeToAvailable</WidthMode>
				<FormControlExtension
					i:nil="true" />
				<Controls>
					<AxFormControl xmlns=""
						i:type="AxFormStringControl">
						<Name>DetailsHeaderGroup_VehicleBrandId</Name>
						<Type>String</Type>
						<FormControlExtension
							i:nil="true" />
						<DataField>VehicleBrandId</DataField>
						<DataSource>ABCVehicleBrand</DataSource>
					</AxFormControl>
					<AxFormControl xmlns=""
						i:type="AxFormStringControl">
						<Name>DetailsHeaderGroup_Description</Name>
						<Type>String</Type>
						<FormControlExtension
							i:nil="true" />
						<DataField>Description</DataField>
						<DataSource>ABCVehicleBrand</DataSource>
					</AxFormControl>
				</Controls>
				<ColumnsMode>Fill</ColumnsMode>
				<DataGroup>DetailsHeaderGroup</DataGroup>
				<DataSource>ABCVehicleBrand</DataSource>
				<FrameType>None</FrameType>
			</AxFormControl>
			<AxFormControl xmlns=""
				i:type="AxFormTabControl">
				<Name>DetailsTab</Name>
				<Type>Tab</Type>
				<FormControlExtension
					i:nil="true" />
				<Controls>
					<AxFormControl xmlns=""
						i:type="AxFormTabPageControl">
						<Name>GeneralTabPage</Name>
						<Pattern>FieldsFieldGroups</Pattern>
						<PatternVersion>1.1</PatternVersion>
						<Type>TabPage</Type>
						<FormControlExtension
							i:nil="true" />
						<Controls>
							<AxFormControl xmlns=""
								i:type="AxFormGroupControl">
								<Name>General</Name>
								<Type>Group</Type>
								<FormControlExtension
									i:nil="true" />
								<Controls>
									<AxFormControl xmlns=""
										i:type="AxFormStringControl">
										<Name>General_CountryRegionId</Name>
										<Type>String</Type>
										<FormControlExtension
											i:nil="true" />
										<DataField>CountryRegionId</DataField>
										<DataSource>ABCVehicleBrand</DataSource>
									</AxFormControl>
								</Controls>
								<DataGroup>General</DataGroup>
								<DataSource>ABCVehicleBrand</DataSource>
							</AxFormControl>
						</Controls>
						<ColumnsMode>Fill</ColumnsMode>
						<Caption>General</Caption>
						<DataSource>ABCVehicleBrand</DataSource>
					</AxFormControl>
					<AxFormControl xmlns=""
						i:type="AxFormTabPageControl">
						<Name>TabPageModels</Name>
						<Pattern>ToolbarList</Pattern>
						<PatternVersion>1.2</PatternVersion>
						<Type>TabPage</Type>
						<FormControlExtension
							i:nil="true" />
						<Controls>
							<AxFormControl xmlns=""
								i:type="AxFormActionPaneControl">
								<Name>ActionPaneControlModels</Name>
								<Type>ActionPane</Type>
								<FormControlExtension
									i:nil="true" />
								<Controls>
									<AxFormControl xmlns=""
										i:type="AxFormButtonGroupControl">
										<Name>NewDeleteGroupModels</Name>
										<Type>ButtonGroup</Type>
										<FormControlExtension
											i:nil="true" />
										<Controls>
											<AxFormControl xmlns=""
												i:type="AxFormCommandButtonControl">
												<Name>AddButtonModels</Name>
												<Type>CommandButton</Type>
												<FormControlExtension
													i:nil="true" />
												<ButtonDisplay>TextWithImageLeft</ButtonDisplay>
												<Command>New</Command>
												<NormalImage>New</NormalImage>
												<Primary>Yes</Primary>
											</AxFormControl>
											<AxFormControl xmlns=""
												i:type="AxFormCommandButtonControl">
												<Name>RemoveButtonModels</Name>
												<Type>CommandButton</Type>
												<FormControlExtension
													i:nil="true" />
												<ButtonDisplay>TextWithImageLeft</ButtonDisplay>
												<Command>DeleteRecord</Command>
												<NormalImage>Delete</NormalImage>
												<Primary>Yes</Primary>
												<SaveRecord>No</SaveRecord>
											</AxFormControl>
										</Controls>
										<DataSource>ABCVehicleModel</DataSource>
									</AxFormControl>
								</Controls>
								<Style>Strip</Style>
							</AxFormControl>
							<AxFormControl xmlns=""
								i:type="AxFormGridControl">
								<Name>GridModels</Name>
								<Type>Grid</Type>
								<FormControlExtension
									i:nil="true" />
								<Controls>
									<AxFormControl xmlns=""
										i:type="AxFormStringControl">
										<Name>GridModels_VehicleModelId</Name>
										<Type>String</Type>
										<FormControlExtension
											i:nil="true" />
										<DataField>VehicleModelId</DataField>
										<DataSource>ABCVehicleModel</DataSource>
									</AxFormControl>
									<AxFormControl xmlns=""
										i:type="AxFormStringControl">
										<Name>GridModels_Description</Name>
										<Type>String</Type>
										<FormControlExtension
											i:nil="true" />
										<DataField>Description</DataField>
										<DataSource>ABCVehicleModel</DataSource>
									</AxFormControl>
								</Controls>
								<DataSource>ABCVehicleModel</DataSource>
							</AxFormControl>
						</Controls>
						<Caption>Models</Caption>
					</AxFormControl>
				</Controls>
				<Style>FastTabs</Style>
			</AxFormControl>
		</Controls>
	</Design>
```
