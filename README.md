# Bulk vMotion

PowerCLI tooling for migrating VMs in bulk from one vSphere cluster to another,
driven by CSV files. The VMs also change distributed switch, so each network
adapter is moved to the port group on the new VDS **that carries the same VLAN ID**
as the port group the adapter is on today.

Drop CSV files in `IN`, run the script, and every file whose VMs have all been
migrated is moved to `MOVED`. Everything the run does is written to a log file in
`LOGS`, together with a per-VM result CSV.

```
IN/     CSV files waiting to be processed
MOVED/  CSV files whose VMs have all been migrated (timestamped)
LOGS/   one .log per run + one _result_.csv per processed CSV file
```

## How the port group mapping works

For every network adapter of every VM:

1. the port group the adapter is connected to is read from the adapter backing
   (by port group key, so a duplicated port group name cannot cause a mismatch),
2. its VLAN is read from the port group configuration,
3. the port group on the target VDS carrying the same VLAN is selected.

Access VLANs, trunk ranges and private VLANs are kept apart - a trunk never
matches a plain access VLAN. If a VLAN exists on **more than one** target port
group the VM is failed rather than guessed at, unless one candidate has exactly
the same name as the source port group. Two escape hatches exist:

* a `TargetPortGroup` value on the CSV row (per VM), or
* `config/portgroup-exceptions.csv` (per source port group, applies to all VMs).

Uplink port groups are always excluded.

## Requirements

* Windows PowerShell 5.1 or PowerShell 7+
* PowerCLI 12 or later: `Install-Module VMware.PowerCLI -Scope CurrentUser`
* An account with vMotion, datastore and network permissions on **both** vCenters
* Cross vCenter vMotion additionally requires vSphere 6.5+, matching SSO/EAM
  prerequisites and network reachability between the clusters

## Getting started

```powershell
# 1. Optional: keep the standing arguments in a config file
Copy-Item .\docs\samples\settings.json .\config\settings.json
notepad .\config\settings.json

# 2. Put a CSV in the IN folder
Copy-Item .\docs\samples\wave1.csv .\IN\wave1.csv

# 3. Dry run first - resolves everything, migrates nothing
.\Invoke-BulkVMotion.ps1 -SourceVIServer vc-old.corp.local -TargetVIServer vc-new.corp.local `
    -TargetVDSwitch 'VDS-NEW-01' -DefaultTargetCluster 'CL-NEW-01' -ValidateOnly

# 4. Run it for real
.\Invoke-BulkVMotion.ps1 -SourceVIServer vc-old.corp.local -TargetVIServer vc-new.corp.local `
    -TargetVDSwitch 'VDS-NEW-01' -DefaultTargetCluster 'CL-NEW-01' -MaxConcurrentMigrations 4
```

Omit `-TargetVIServer` when both clusters live in the same vCenter.

## The CSV file

Only `VMName` is required. Everything else falls back to the `-DefaultTarget*`
parameters, so a minimal file is just a list of VM names.

| Column | Required | Meaning |
| --- | --- | --- |
| `VMName` | yes | Name of the VM in the source vCenter |
| `SourceCluster` | no | Only needed to disambiguate a duplicated VM name |
| `TargetCluster` | no | Destination cluster; defaults to `-DefaultTargetCluster` |
| `TargetHost` | no | Pin the VM to one destination host instead of letting the script pick |
| `TargetDatastore` | no | Datastore or datastore cluster; required for cross vCenter |
| `TargetFolder` | no | Destination VM folder |
| `TargetPortGroup` | no | Skip the VLAN lookup and use this port group |
| `Notes` | no | Free text, ignored by the script |

```csv
VMName,TargetCluster,TargetDatastore,TargetPortGroup,Notes
vm-app-01,CL-NEW-01,DSC-NEW-PROD,,Port group found by VLAN
vm-dmz-01,CL-NEW-02,DSC-NEW-DMZ,PG-NEW-DMZ-Web,VLAN is ambiguous so the port group is named
```

See `docs/samples/wave1.csv`.

## When is the CSV moved to MOVED?

Controlled by `-MoveCsvWhen`:

| Value | Behaviour |
| --- | --- |
| `AllSuccess` (default) | Moved only when every VM in the file migrated successfully |
| `Always` | Moved once the file has been processed, whatever the outcome |
| `Never` | Never moved |

A file that stays in `IN` can be corrected and run again - already migrated VMs
should be removed from it first. `-ValidateOnly` never moves anything. The
archived name gets a timestamp (`wave1_20260901-081102.csv`), so re-running the
same file name never overwrites an earlier archive.

## Parameters worth knowing

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ValidateOnly` | off | Resolve and report everything, migrate nothing. Run this first. |
| `-MaxConcurrentMigrations` | 2 | How many vMotions run at the same time. Stay within your host/network limits. |
| `-MigrationTimeoutMinutes` | 120 | A VM is reported as `TimedOut` after this; the vCenter task itself keeps running. |
| `-StopOnError` | off | Stop starting new migrations from a file as soon as one VM fails. |
| `-DatastoreReserveGB` | 100 | Free space that must remain on the target datastore after the VM lands. |
| `-DiskStorageFormat` | `AsDefined` | `Thin`, `Thick` or `EagerZeroedThick` when the disks are moved. |
| `-VMotionPriority` | `High` | Passed to `Move-VM` for powered-on VMs. |
| `-CsvFile` | - | Process one specific CSV instead of scanning `IN`. |
| `-IgnoreInvalidCertificate` | off | For vCenters with self-signed certificates. |
| `-WhatIf` | off | Plans everything and reports what would be migrated, without doing it. |

Exit codes: `0` everything succeeded, `1` at least one VM or CSV file failed,
`2` the run itself stopped (connection failure, bad configuration).

## What is checked before a VM is migrated

A VM is only migrated once all of this resolves - otherwise it is reported as
`Failed` and the run continues with the next VM:

* the VM exists and its name is unambiguous
* no pending vCenter question on the VM
* the destination cluster has a connected host (or the named host is connected)
* the destination is not the host the VM already runs on (same-vCenter runs)
* the datastore exists and has room for the VM plus the reserve
* the destination folder exists and is unambiguous
* **every** network adapter resolves to exactly one target port group

Powered-off VMs are migrated as a cold relocate and logged as such.

## Logging

Each run writes `LOGS/bulk-vmotion_<timestamp>.log` containing the resolved VLAN
table, the full plan for every VM (source, destination, datastore, per-adapter
port group mapping), start/progress/completion of each migration and a closing
summary. Per CSV file, `LOGS/<name>_result_<timestamp>.csv` records one row per VM
with status, duration, the port groups used and the failure message when there is
one. Use `-LogLevel Debug` for more detail.

## Tests

```powershell
Invoke-Pester -Path .\Tests
```

`Tests/BulkVMotion.Tests.ps1` covers the VLAN parsing, port group matching, CSV
validation and the archive move. `Tests/Invoke-BulkVMotion.Tests.ps1` runs the
real script end to end against the PowerCLI test doubles in `Tests/Fakes`, so no
vCenter is needed. Neither suite touches a live environment.

## Layout

```
Invoke-BulkVMotion.ps1              the runner
Modules/BulkVMotion/                logging, CSV handling, VLAN mapping, migration
config/                             settings.json and portgroup-exceptions.csv (gitignored)
docs/samples/                       sample CSV, config and exception map
Tests/                              Pester tests and the PowerCLI test doubles
```
