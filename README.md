# Bulk vMotion

PowerCLI tooling for migrating VMs in bulk, driven by CSV files, in the three phases
the move actually happens in:

| Phase | What moves | What does not |
| --- | --- | --- |
| **1** | vMotion from the old cluster to the new one, and every network adapter is remapped onto the new VDS by VLAN ID | Storage. The disks stay where they are, so the new cluster must already see them |
| **2** | Storage vMotion onto the new datastore | The VM stays on its host and keeps its networking |
| **3** | Cross vCenter vMotion to the new vCenter and cluster, port groups remapped onto that vCenter's VDS by VLAN ID | Storage. The same shared volume is used, so no data moves |

The VMs sit still between phases, sometimes for weeks. Each CSV file records the phase
its VMs have completed and is archived into the matching folder, so **the folder a file
sits in tells you where that wave has got to**.

```
IN/      CSV files waiting for their next phase
Phase1/  waves that have completed phase 1
Phase2/  waves that have completed phase 2
Phase3/  waves that are fully migrated
LOGS/    one .log per run + one _result_.csv per file per phase
```

When the next wave is due, move the file from `Phase1` back into `IN` and run phase 2.

## How the port group mapping works

In phases 1 and 3, for every network adapter of every VM:

1. the port group the adapter is connected to is read from the adapter backing (by port
   group key, so a duplicated port group name cannot cause a mismatch),
2. its VLAN is read from the port group configuration,
3. the port group on the target VDS carrying the same VLAN is selected.

Access VLANs, trunk ranges and private VLANs are kept apart - a trunk never matches a
plain access VLAN. If a VLAN exists on **more than one** target port group the VM is
failed rather than guessed at, unless one candidate has exactly the same name as the
source port group. Two escape hatches:

* `Phase1PortGroup` / `Phase3PortGroup` on the CSV row (per VM), or
* `config/portgroup-exceptions.csv` (per source port group, applies to all VMs).

Uplink port groups are always excluded. Because the old and the new VDS live in the same
vCenter during phases 1 and 2, **always pass `-TargetVDSwitch`** - without it every port
group in the vCenter is a candidate and duplicate VLANs are almost guaranteed.

## Requirements

* Windows PowerShell 5.1 or PowerShell 7+
* PowerCLI 12 or later: `Install-Module VMware.PowerCLI -Scope CurrentUser`
* An account with vMotion, datastore and network permissions on the vCenter(s) involved
* Phase 3 additionally needs vSphere 6.5+, the usual cross vCenter vMotion prerequisites,
  and the same storage presented to both vCenters

## Running a wave

```powershell
# Always dry run first - resolves everything, migrates nothing, changes no file
.\Invoke-BulkVMotion.ps1 -Phase 1 -SourceVIServer vc.corp.local `
    -TargetVDSwitch 'VDS-NEW-01' -DefaultTargetCluster 'CL-NEW-01' -ValidateOnly

# Phase 1: cluster + VDS
.\Invoke-BulkVMotion.ps1 -Phase 1 -SourceVIServer vc.corp.local `
    -TargetVDSwitch 'VDS-NEW-01' -DefaultTargetCluster 'CL-NEW-01' -MaxConcurrentMigrations 4

# Phase 2, weeks later: storage only
.\Invoke-BulkVMotion.ps1 -Phase 2 -SourceVIServer vc.corp.local `
    -DefaultTargetDatastore 'DSC-NEW-PROD'

# Phase 3: on to the new vCenter, same storage
.\Invoke-BulkVMotion.ps1 -Phase 3 -SourceVIServer vc.corp.local -TargetVIServer vc-new.corp.local `
    -TargetVDSwitch 'VDS-VC2' -DefaultTargetCluster 'CL-FINAL-01'
```

`-Phase` is checked against what the file says it is due for. A phase 2 file that ends up
in `IN` during a phase 1 wave is refused, not migrated. Leave `-Phase` out to take the
phase from the files themselves.

## The CSV file

Only `VMName` is required. Each phase reads its own column, falling back to the generic
`Target*` column and then to the run's `-DefaultTarget*` value, so a one-phase file can be
just a list of VM names.

| Column | Used in | Meaning |
| --- | --- | --- |
| `VMName` | all | Name of the VM in the source vCenter |
| `SourceCluster` | all | Only needed to disambiguate a duplicated VM name |
| `Phase1Cluster` | 1 | Destination cluster; defaults to `-DefaultTargetCluster` |
| `Phase1Host` | 1 | Pin to one destination host instead of letting the script pick |
| `Phase1PortGroup` | 1 | Skip the VLAN lookup and use this port group |
| `Phase2Datastore` | 2 | Datastore or datastore cluster to move onto |
| `Phase3Cluster` | 3 | Cluster on the new vCenter |
| `Phase3Host` | 3 | Pin to one host on the new vCenter |
| `Phase3PortGroup` | 3 | Skip the VLAN lookup on the new vCenter's VDS |
| `Notes` | - | Free text, never touched by the script |

The script adds these itself as each phase completes - do not fill them in by hand:

| Column | Meaning |
| --- | --- |
| `PhaseCompleted` | 0, 1, 2 or 3. Drives what runs next |
| `CompletedAt` | When that phase finished for this VM |
| `ResultVIServer`, `ResultCluster`, `ResultHost`, `ResultDatastore`, `ResultPortGroup` | Where the VM actually landed |

`docs/samples/wave1.csv` is a file as you would author it;
`docs/samples/wave1-after-phase1.csv` is the same file after a phase 1 wave.

## Partial waves

A file only moves to `PhaseN` once **every** row has reached phase N. If 8 of 10 VMs
succeed, the file stays in `IN` with those 8 rows marked done. Fix the two failing rows
and run the same phase again: the 8 that are finished are skipped (`AlreadyDone`) and
only the stragglers are migrated. Nothing has to be edited out by hand.

`-MoveCsvWhen` controls this: `AllSuccess` (default), `Always`, or `Never`.
`-ValidateOnly` never moves or modifies a file.

## Parameters worth knowing

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Phase` | from the files | Which phase this run is; refuses files that disagree |
| `-ValidateOnly` | off | Resolve and report everything, migrate nothing. Run this first |
| `-MaxConcurrentMigrations` | 2 | How many migrations run at once. Stay within your host/network limits |
| `-MigrationTimeoutMinutes` | 120 | A VM is reported `TimedOut` after this; the vCenter task keeps running |
| `-StopOnError` | off | Stop starting new migrations from a file as soon as one VM fails |
| `-DatastoreReserveGB` | 100 | Free space that must remain on the target datastore (phase 2) |
| `-DiskStorageFormat` | `AsDefined` | `Thin`, `Thick` or `EagerZeroedThick`, applied only when disks actually move |
| `-VMotionPriority` | `High` | Passed to `Move-VM` for powered-on VMs |
| `-CsvFile` | - | Process one specific file instead of scanning `IN` |
| `-ArchiveRoot` | script folder | Where the `Phase1`/`Phase2`/`Phase3` folders live |
| `-IgnoreInvalidCertificate` | off | For vCenters with self-signed certificates |
| `-WhatIf` | off | Plans everything and reports what would be migrated, without doing it |

Exit codes: `0` everything succeeded, `1` at least one VM or file failed, `2` the run
itself stopped (connection failure, bad configuration).

## What is checked before a VM is touched

A VM is only migrated once all of this resolves - otherwise it is reported `Failed`, the
file stays in `IN`, and the run continues with the next VM:

* the VM exists and its name is unambiguous
* no pending vCenter question on the VM
* the destination cluster has a connected host (or the named host is connected)
* **phase 1**: every datastore the VM uses is mounted on the destination host - storage
  does not move in phase 1, so a host that cannot see the disks would fail the vMotion
* **phase 2**: the datastore exists and has room for the VM plus the reserve
* **phase 3**: the VM's datastore exists on the new vCenter under the same name, which is
  what "the same shared volume" means in practice
* the destination folder exists and is unambiguous
* **phases 1 and 3**: every network adapter resolves to exactly one target port group

Powered-off VMs are migrated as a cold relocate and logged as such. Work that is not
needed is not done: a VM already in the target cluster keeps the host DRS gave it, and a
VM that only needs its port groups changed is reconnected with `Set-NetworkAdapter`
rather than sent through a pointless relocate.

## Logging

Each run writes `LOGS/bulk-vmotion_<timestamp>.log` with the resolved VLAN table, the
full plan for every VM (source, destination, datastore, per-adapter port group mapping, a
`Will change` line naming compute/storage/network), migration progress and a closing
summary. Per file and phase, `LOGS/<name>_phase<N>_result_<timestamp>.csv` records one
row per VM with status, duration, the port groups used and the failure message when there
is one. Use `-LogLevel Debug` for more detail.

## Tests

```powershell
Invoke-Pester -Path .\Tests
```

`Tests/BulkVMotion.Tests.ps1` covers VLAN parsing, port group matching, CSV validation,
the phase state machine and the CSV write-back. `Tests/Invoke-BulkVMotion.Tests.ps1` runs
the real script end to end against the PowerCLI test doubles in `Tests/Fakes` - including
carrying one file through all three phases - so no vCenter is needed. Neither suite
touches a live environment.

## Layout

```
Invoke-BulkVMotion.ps1              the runner
Modules/BulkVMotion/                logging, CSV and phase handling, VLAN mapping, migration
config/                             settings.json and portgroup-exceptions.csv (gitignored)
docs/samples/                       sample CSVs, config and exception map
Tests/                              Pester tests and the PowerCLI test doubles
```
