# Optimize the refresh after a compile (development VM)

After a build, Visual Studio restarts the AOS. You then wait for the restart and for the first open of your
form. The four steps below shorten that wait. They were measured on a cloud-hosted Tier1 VM (8 vCPU, 32 GB,
platform 7.0.8199) with a runnable class and three list pages.

| Step | Measured effect |
|------|-----------------|
| 1. OData metadata build off | New code is visible about 45 s after the restart, instead of 3.5 to 4.5 min |
| 2. Defender rules | Small for the restart: Defender's file filters used about 2 s of CPU in one restart |
| 3. Two `web.config` keys | The first open of a form after a restart is 7 to 14 s faster |
| 4. Two services off | Not measured; they free CPU and memory |

## 1. Switch off the OData metadata build at AOS start

Run this in the AOS database (`AxDB`):

```sql
UPDATE SYSTEMPARAMETERS SET ODATABUILDMETADATACACHEONAOSSTARTUP = 0 WHERE ODATABUILDMETADATACACHEONAOSSTARTUP <> 0
```

With 1, every AOS start builds the OData metadata cache (about 165 s) before the AOS answers. With 0, the
first OData request after a restart builds it instead. A database copied from another environment can bring
the 1 back.

## 2. Add the Windows Defender rules

In an elevated PowerShell, with the [d365fo.tools](https://github.com/d365collaborations/d365fo.tools) module:

```powershell
Install-Module d365fo.tools
```

```powershell
Add-D365WindowsDefenderRules
```

The command adds Defender exclusions for the `AOSService` folder, the Visual Studio and .NET folders, the
processes of Visual Studio, MSBuild, the X++ compiler, IIS and SQL Server, and the file types `xml`, `xpp`,
`md`, `man` and `netmodule`. The exclusions are broad, so use them on development VMs only.

## 3. Add two keys to `web.config`

Back up `AOSService\webroot\web.config` outside the webroot, add these lines to `<appSettings>` and restart
IIS:

```xml
<add key="Infrastructure.EnableAzureSqlAccessTokenUpdater" value="false" />
<add key="Infrastructure.EnableAzureStorageAccessTokenUpdater" value="false" />
```

Both keys were missing on our VM. A missing key already means `false`, so the behaviour doesn't change. But
for a missing key the platform parses the whole `web.config` again on every read
(`BaseConfigSetting.GetConfiguration`, about 4 ms each), and it reads the SQL key each time a table is used
for the first time after a restart.

Time from the AOS restart until the grid shows rows, with the page opened first after the restart (average
of two runs):

| Page | Without the keys | With the keys |
|------|------------------|---------------|
| All customers | 49 s | 42 s |
| All vendors | 47 s | 40 s |
| All sales orders | 64 s | 50 s |

Later opens of the same pages take 2 to 5 s either way.

## 4. Stop two services

```powershell
Stop-Service MR2012ProcessService -Force; Set-Service MR2012ProcessService -StartupType Disabled
```

```powershell
Stop-Service DynamicsAxBatch -Force; Set-Service DynamicsAxBatch -StartupType Manual
```

- **Management Reporter 2012 Process Service** (`MR2012ProcessService`): disable it unless you work on
  financial reports.
- **Microsoft Dynamics 365 Unified Operations: Batch Management Service** (`DynamicsAxBatch`): set it to
  manual and start it when you test batch jobs. On a copy of another environment's database, a running batch
  service also starts that environment's batch jobs.

## Check again after servicing

- **Package deployment:** on our VM a deployable package set both services back to automatic start. The
  `web.config` keys and the OData parameter stayed.
- **Database refresh:** check the OData parameter.
- **Platform update:** check that `web.config` still has the two keys.

## What remains

About 45 s from the restart to the output of a runnable class. Around 19 s of it is the AOS kernel start,
mostly registering the chain-of-command and event handlers of custom and ISV packages on one thread. The rest
is service start, the first page load and the navigation menu. We found no setting for these:
`COMPlus_JITMinOpts=1` on the app pool made the restart slower, and `limitednav=true` changed nothing.
