# Dynamics 365 F&O ERP MCP Server — Reference

Detailed reference for the D365 Finance & Operations ERP MCP server exposed (via the local proxy)
to Claude Code as the server **`d365fo-perf`**. Covers the connection model, the full tool set,
when each tool is called, exact parameters, and the SQL dialect.

---

## 1. Connection & security model

| Item | Value |
|------|-------|
| Endpoint (upstream) | `https://<your-environment>.operations.dynamics.com/mcp` |
| Transport | MCP **Streamable HTTP** (JSON + optional Server-Sent Events) |
| Entra tenant | `<your-entra-tenant-id>` |
| Auth to reach it | App-only (client-credentials) bearer token, audience = base F&O URL |
| Identity in D365 | The Entra app is mapped to a D365 user (*Sysadmin ▸ Setup ▸ Microsoft Entra ID applications*) |
| Current identity | `Admin` / **System administrator** (`-SYSADMIN-`), default company **DAT** |
| Allowed-clients gate | The app's client ID must be `Allowed = true` on the *Allowed MCP clients* form |

**Security properties (from Microsoft's model):**
- Every request runs under the authenticated user's D365 security — roles, duties, privileges,
  record-level and data security all apply. The MCP server does **not** elevate privilege.
- Business logic, validations and workflows are **not** bypassed — tools call the same OData /
  custom-service / server APIs as any other channel. A transaction rejected in the client is
  rejected here too.
- **Field-level security** is enforced: a query touching a field the user can't read is rejected
  wholesale, returning the restricted field names.
- The MCP server stores no customer data; it is a pass-through to the F&O environment.

**Handshake sequence (managed by the client):**
1. `POST /mcp` → `initialize` (returns `serverInfo`, capabilities, and an `mcp-session-id` header)
2. `POST /mcp` → `notifications/initialized` (HTTP 202)
3. `POST /mcp` → `tools/list`, then normal tool calls — all carrying the `mcp-session-id`
- Note: `initialize` is slow here (~9–15 s). Tools appear in Claude Code as `mcp__d365fo-perf__<tool>`.

---

## 2. Tool families & the golden path

The server exposes **22 tools** in four families:

- **Identity** (1) — resolve who the caller is.
- **Data** (7) — OData entities; the **default** path for read and CRUD.
- **API** (2) — invoke X++/OData *actions* (business operations that aren't plain CRUD).
- **Form** (12) — drive the actual UI; the **fallback** when data/API can't do it.

**Server's own tool-selection guidance:**
> Default to **data** tools for create/read/update/delete. Use **form/API** tools when data tools
> fail or when explicitly requested. For data: `data_find_entity_type` → `data_get_entity_metadata`
> → create/read/update/delete. Never guess entity set or field names.

### Decision flow

1. **Read / report / count** → data chain ending in `data_find_entities_sql`.
2. **Create / update / delete a record** → data chain ending in the matching `data_*` write
   (fetch metadata with `includeKeys=true` first).
3. **Run a business operation** (post / calculate / process) → `api_find_actions` → `api_invoke_action`.
4. **UI-only logic, or data/API can't do it** → the `form_*` sequence, **one call at a time**.

---

## 3. Identity tool

### `get_current_user` — *(no parameters)*
Returns the connected user's id, name, email, party id, language/locale, object id, and enabled roles.
**Called when:** a request mentions "my / me / I / mine", or before any write, to resolve identity and
roles rather than guessing. Here it returns `Admin` / System administrator / company `DAT`.

---

## 4. Data tools (OData entities)

Mandatory chain — **do not guess** entity or field names:
`data_find_entity_type` → `data_get_entity_metadata` → read / create / update / delete.

### `data_find_entity_type`
- **Params:** `entitySetSearchFilter` (req), `topHitCount` (opt, default 10)
- **Called when:** first step of any data request — map a business concept ("customer group") to the
  real **EntitySetName** (`CustomerGroups`). One search term per call; use multiple calls for multiple terms.

### `data_get_entity_metadata`
- **Params:** `entitySetName` (req); optional booleans:
  - `includeEnumValues` (default **true**) — enum symbol→value maps for use in SQL/writes
  - `includeFieldConstraints` (default **false**) — e.g. `IsReadOnly`, `MaxLength`
  - `includeKeys` (default **false**) — key fields; **required before update/delete**
  - `includeRelationships` (default **false**) — navigation/relations
- **Called when:** after finding the entity and before querying or writing — to get exact field names,
  enum values, and (for writes) the key fields. Returns `RootTableIsGlobal` (whether the entity is
  company-specific), the field list, and enum definitions.

### `data_find_entities_sql`
- **Params:** `sqlExpression` (req) · `companyId` (opt — a specific ID like `2000`/`DAT`, or
  `Cross-company`; defaults to the user's default company) · `returnAsResource` (opt `"true"`/`"false"`,
  default false)
- **Called when:** **all reads / reporting** — filtering, sorting, grouping, aggregation, joins.
- **Full SQL dialect:** see §7.

### `data_create_entities`
- **Params:** `odataPath` (req, e.g. `Customers`) · `entityDefinitionsJson` (req — JSON array of records)
- **Called when:** inserting records. **No deep inserts.** Fetch metadata first. OData formatting for
  dates/numbers/strings; time = integer seconds since midnight.

### `data_update_entities`
- **Params:** `updatedOdataPathAndFieldValuesJson` (req) — JSON array of
  `{ "ODataPath": "...", "UpdatedFieldValues": { ... } }`
- **Called when:** modifying records. Fetch metadata with `includeKeys=true` first.
  Company-specific entities include a `dataAreaId` key segment
  (`Customers(dataAreaId='USMF', CustomerAccount='US-001')`); global entities (e.g. `Workers`) do not
  (`Workers(PersonnelNumber='000123')`). No deep updates.

### `data_delete_entities`
- **Params:** `odataPaths` (req) — `{ "ODataPaths": ["...", "..."] }`
- **Called when:** removing records by OData key path. Same key rules as update.

---

## 5. API tools (actions)

For operations that are a *process*, not a record edit (post, calculate, run, generate).

### `api_find_actions`
- **Params:** `searchTerm` (req). One term per call.
- **Called when:** the task is a business operation rather than CRUD — to discover the action and its
  parameter schema.

### `api_invoke_action`
- **Params:** `name` (req — the action menu item name) · `parameters` (req — valid JSON with correct
  types; **enums as symbol names**, e.g. `"Active"` not `0`) · `companyId` (opt) ·
  `returnAsResource` (opt bool, default false)
- **Called when:** executing the action found via `api_find_actions`.

---

## 6. Form tools (UI automation)

The fallback path — used only when data/API tools can't accomplish the task, or when the UI itself is
required. **Rules:**
- Use control / menu / column / tab **names**, not labels.
- **Stateful** — they act on the single active form in the session.
- **Never call two form tools in parallel.** The only exception is `form_find_menu_item`.
- Controls are editable unless `IsEditable: false`.

Typical sequence: find menu item → open → (open tab / find controls) → set values / click → save → close.

| Tool | Params | Called when |
|------|--------|-------------|
| `form_find_menu_item` | `menuItemFilter` (req); `companyId`, `responseSize` (opt, default 50) | Locate a form/action/report menu item by name. **Only form tool safe in parallel.** |
| `form_open_menu_item` | `name` (req); `type` (req: **Display \| Action \| Output**) | Open the form/action/report. |
| `form_find_controls` | `controlSearchTerm` (req) | A needed control isn't in the current state (likely on a collapsed tab). One term per call. |
| `form_open_or_close_tab` | `tabName`, `tabAction` (**Open \| Close**) | Expand a tab to expose its controls (or tidy up). |
| `form_set_control_values` | `setControlValues[]` of `{controlName, value}` | Set field values — **non-lookup** fields only. |
| `form_open_lookup` | `lookupName` (req) | Set a field that needs a lookup (`HasLookup=true`) instead of `set_control_values`. |
| `form_click_control` | `controlName` (req); `actionId` (opt) | Press a button; pick a radio option (label/value); page a grid (`LoadNextPage`/`LoadPrevPage`); hier-grid `LoadData`; listbox `OptionId`; tree `Expand`/`Collapse`/`Select`/`Unselect`. |
| `form_filter_form` | `controlName`, `filterValue` | Apply a form-wide filter to find a record. |
| `form_filter_grid` | `gridName`, `gridColumnName`, `gridColumnValue` | Filter one grid column. Ranges `12..14`, `<12`, `>12`, `(DayRange(-30,0))`; empty string clears. **⚠ Clears marked rows.** |
| `form_sort_grid_column` | `gridName`, `gridColumnName`, `sortDirection` (**Ascending \| Descending**) | Order a grid. |
| `form_select_grid_row` | `gridName`, `rowNumber`; `marking` (**Marked \| Unmarked**) | Select/mark a row. `Marked` accumulates for multi-select — don't filter between marks (filtering clears marks); page with `LoadNextPage` instead. |
| `form_save_form` | *(none)* | Commit changes on the active form. |
| `form_close_form` | *(none)* | Close the form when done. |

---

## 7. `data_find_entities_sql` — complete SQL dialect

**Supported**
- `SELECT`, `FROM`, `[INNER \| LEFT] JOIN … ON`, `WHERE`, `GROUP BY`, `ORDER BY`, `TOP N`
- Operators: `= <> > < >= <= LIKE "NOT LIKE" AND OR NOT "IS NULL" "IS NOT NULL"`
- Aggregates: `COUNT SUM AVG MIN MAX`, and `SUM(col1 +/- col2)`
- Arithmetic in `WHERE`: `+ - * /`
- `WHERE [NOT] EXISTS (SELECT 1 FROM T t WHERE t.Key = root.Key)` — subquery must reference **exactly
  one table** and include a `WHERE`; combinable with `AND` only; the EXISTS table is not in SELECT output.

**Not supported (query rejected)**
- `IN` / scalar subqueries, CTEs, `HAVING`, `RIGHT`/`FULL OUTER JOIN`, `OFFSET/FETCH`
- Window functions / `OVER` (`SUM(x) OVER()`, `ROW_NUMBER()`, `RANK()`, `LAG()`, `LEAD()`)
- T-SQL functions in `WHERE` / `GROUP BY`
- `EXISTS` without `WHERE`; `EXISTS` combined with `OR`
- Arithmetic constants in SUM (`SUM(col+10)`); arithmetic in SELECT outside aggregates

**Graceful degradation (runs, returns a warning)**
- T-SQL functions in `SELECT` or `ORDER BY`
- Duplicate aggregations on the same field
- `AVG`/`MIN`/`MAX` with arithmetic

**Rules**
- Use the **plural EntitySetName** in `FROM`/`JOIN` (from `data_get_entity_metadata`).
- Always alias tables and columns; **never `SELECT *`**.
- Date/datetime literals in single quotes: `'2024-01-31'`, `'2024-01-31T10:30:00'`.
- Use **numeric enum values** in `WHERE`. `IS NULL` maps to a default-value comparison (warning issued).
- Wrap reserved-word aliases in brackets: `[LineNo]`.
- **Field-level security:** referencing any unreadable field anywhere (SELECT, aggregate, WHERE, JOIN,
  GROUP BY, ORDER BY) rejects the whole query and returns the restricted field names — remove and retry.
- Use the `companyId` parameter for company context; only put `dataAreaId` in SELECT for `Cross-company`.

**Example**
```sql
SELECT cg.CustomerGroupId AS GroupId, cg.Description AS Description
FROM   CustomerGroups cg
ORDER BY cg.CustomerGroupId
```
(with `companyId = "2000"`)

---

## 8. Practical notes

- **Data entity vs base table:** counts/reads go through the OData **data entity**, which may apply its
  own view/filters — numbers can differ slightly from a raw `COUNT(*)` on the underlying table.
- **Company scope:** company-specific entities need `companyId`; default is the user's default company
  (`DAT`). Use `Cross-company` + `dataAreaId` in SELECT to span all companies.
- **Enums:** SQL/WHERE uses **numeric** enum values; action parameters use enum **symbol names**.
- **Writes are high-impact here** — the identity is System administrator. Confirm scope before any
  create/update/delete or form save.
- **Performance:** `initialize` and large queries can take several seconds; the proxy sets generous
  timeouts and streams SSE.

---

## 9. Full tool index

```
get_current_user

data_find_entity_type      data_get_entity_metadata   data_find_entities_sql
data_create_entities       data_update_entities       data_delete_entities

api_find_actions           api_invoke_action

form_find_menu_item        form_open_menu_item        form_find_controls
form_open_or_close_tab     form_set_control_values    form_open_lookup
form_click_control         form_filter_form           form_filter_grid
form_sort_grid_column      form_select_grid_row       form_save_form
form_close_form
```
