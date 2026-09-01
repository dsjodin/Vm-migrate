# Bulk vMotion

PowerCLI tooling for migrating VMs in bulk, driven by CSV waves, in the three phases the
move actually happens in:

| Phase | What moves | What does not |
| --- | --- | --- |
| **1** | vMotion from the old cluster to the new one; every network adapter is remapped onto the new VDS by VLAN ID | Storage. The disks stay put, so the new cluster must already see them |
| **2** | Storage vMotion onto the new datastore, thin provisioned | The VM stays on its host and keeps its networking |
| **3** | Cross vCenter vMotion to the new vCenter and cluster; port groups remapped onto that vCenter's VDS by VLAN ID | Storage. The same shared volume is used, so no data moves |

The VMs sit still between phases, sometimes for weeks. Each CSV is a **wave** that records
the phase its VMs have completed and is archived into the matching folder, so **the folder
a file sits in tells you where that wave has got to**.

```
IN/       waves waiting for their next phase
Running/  the wave someone is running right now
Phase1/   waves that have completed phase 1
Phase2/   waves that have completed phase 2
Phase3/   waves that are fully migrated
LOGS/     one .log per run + one result CSV per wave per phase
```

When the next wave is due, move the file from `Phase1` back into `IN` and run phase 2.

## First run: store your credentials

Several engineers share the mgmt server, so credentials are per engineer rather than in a
config file. Run this once per vCenter:

```powershell
.\Save-MigrationCredential.ps1 -VIServer vc.corp.local
.\Save-MigrationCredential.ps1 -VIServer vc-new.corp.local   # phase 3 only
```

The password is encrypted with DPAPI to **your Windows account on that machine**: a
colleague logged into the same server cannot read it, and the file is useless if copied
elsewhere. `-Remove` forgets one. Runs then pick the credential up on their own, and
prompt only if there is nothing stored. `-SourceCredential` / `-TargetCredential` still
override everything.

> Windows only. On Linux and macOS PowerShell does not encrypt a SecureString, so saving
> is refused rather than writing your password out in the clear.

## Running a wave

```powershell
# Always dry run first: resolves everything, migrates nothing, and writes back the
# port groups it worked out so you can check them
.\Invoke-BulkVMotion.ps1 -Phase 1 -SourceVIServer vc.corp.local -ValidateOnly

# Then for real
.\Invoke-BulkVMotion.ps1 -Phase 1 -SourceVIServer vc.corp.local

# Phase 2, weeks later
.\Invoke-BulkVMotion.ps1 -Phase 2 -SourceVIServer vc.corp.local

# Phase 3: on to the new vCenter, same storage
.\Invoke-BulkVMotion.ps1 -Phase 3 -SourceVIServer vc.corp.local -TargetVIServer vc-new.corp.local
```

You are shown the waves due for that phase and pick one:

```
Waves available for phase 1
------------------------------------------------------------------------------------------------
 1. wave-app-01.csv                      12 VM(s)  phase 1  Ready
 2. wave-db-02.csv                        8 VM(s)  phase 1  Interrupted - CORP\bob started phase 1 at 09:14, then the process is gone
    wave-web-03.csv                      20 VM(s)  phase 1  Busy - CORP\alice started phase 1 at 10:02 (still running)
    wave-app-04.csv                       6 VM(s)  phase 2  NotDue - due for phase 2
------------------------------------------------------------------------------------------------
Which wave? (number, or Q to quit):
```

The wave you pick moves into `Running/` with a marker naming you, your machine and the
process, so nobody else can start it. When the run ends it goes to `Phase{N}` (all done)
or back to `IN` (something outstanding) - including if the run crashes, because the
release happens in the script's `finally`. A wave left behind by a run that really died
is offered back as **Interrupted**; resuming it skips the VMs that got through.

`-CsvFile` names a wave directly and skips the picker. `-NonInteractive` never prompts:
it runs the only available wave, or fails if there is more than one.

## The CSV

You author these columns. Only `VMName` is required; anything blank falls back to the
run's `-DefaultTargetCluster` / `-DefaultTargetDatastore` / `-TargetVDSwitch`.

| Column | Phase | Meaning |
| --- | --- | --- |
| `VMName` | all | Name of the VM in the source vCenter |
| `SourceCluster` | all | Only needed to disambiguate a duplicated VM name |
| `Phase1Cluster` | 1 | Destination cluster |
| `Phase1VDS` | 1 | Distributed switch this VM lands on |
| `Phase2Datastore` | 2 | Datastore or datastore cluster to move onto |
| `Phase3Cluster` | 3 | Cluster on the new vCenter |
| `Phase3VDS` | 3 | Distributed switch on the new vCenter |
| `Notes` | - | Free text, never touched |

The script fills these in - do not write them by hand:

| Column | Meaning |
| --- | --- |
| `Phase1PortGroups`, `Phase3PortGroups` | The port group chosen for **every** adapter: `Network adapter 1=PG-Prod-100; Network adapter 2=PG-Bkp-300` |
| `PhaseCompleted` | 0, 1, 2 or 3. Drives what runs next |
| `CompletedAt`, `CompletedBy` | When, and which engineer |
| `ResultVIServer`, `ResultCluster`, `ResultHost`, `ResultDatastore` | Where the VM actually landed |

`Phase1Host` / `Phase3Host` also work if you ever need to pin a VM to one host instead of
letting the script choose.

`docs/samples/wave1.csv` is a wave as you would author it;
`docs/samples/wave1-after-phase1.csv` is the same file after a phase 1 run.

## Port groups, VLANs and multiple NICs

For every adapter of every VM, in phases 1 and 3:

1. the port group it is on is read from the adapter backing (by port group key, so a
   duplicated port group name cannot cause a mismatch),
2. its VLAN is read from the port group configuration,
3. the port group on that VM's target VDS carrying the same VLAN is chosen.

A VM with several NICs on different VLANs is handled per adapter - each lands on the port
group for its own VLAN, and all of them are recorded in one cell.

Access VLANs, trunk ranges and private VLANs are kept apart: a trunk never matches a plain
access VLAN. If a VLAN exists on **more than one** port group of the target switch, the VM
is failed rather than guessed at, unless one candidate has exactly the same name as the
source port group.

**This is what the dry run is for.** `-ValidateOnly` writes the port groups it resolved
into `PhaseNPortGroups` without migrating anything. Open the file, check every NIC landed
where you expect, correct anything ambiguous, and the real run uses what is in the cell.
`config/portgroup-exceptions.csv` does the same thing globally, by source port group name.

## Concurrency

Rather than a flat limit, the tool applies vSphere's own resource cost model, so it never
asks vCenter for something vCenter would only queue:

| Resource | Maximum | vMotion costs | Storage vMotion costs |
| --- | --- | --- | --- |
| Host | 8 | 1 | 4 |
| Datastore | 128 | 1 | 16 against each of source and destination |
| vMotion network | 8 | 1 | - |

Which gives the familiar derived limits: **8 vMotions or 2 Storage vMotions per host**, and
**8 Storage vMotions per datastore**. When a VM has to wait, the log says which resource is
full.

Migrations *other engineers* have started are counted too: the running relocate tasks are
read from vCenter each polling cycle and charged against the same budget, so two people
running waves at once share the estate properly. That accounting is deliberately
approximate and errs high - another session's destination is not readable, so only the
source host is charged, and a relocate is costed as a Storage vMotion. `-IgnoreExternalTasks`
turns it off.

> **Network speed:** VMware tiers the network limit at 1GigE (max 4) and 10GigE (max 8)
> only - there is no higher tier, so 10GigE, 25GigE and 100GigE all cap at 8, and the host
> limit of 8 binds first anyway. Leave `-VMotionNetworkLimit` at 8 unless your vMotion
> network is 1GigE, in which case set it to 4.

## Partial waves

A wave only moves to `PhaseN` once **every** row has reached phase N. If 8 of 10 VMs
succeed, the file goes back to `IN` with those 8 rows marked done. Fix the two failing rows
and run the same phase again: the 8 are skipped as `AlreadyDone` and only the stragglers
are migrated. Nothing has to be edited out by hand.

## Parameters worth knowing

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Phase` | from the wave | Which phase this run is; only waves due for it can be picked |
| `-ValidateOnly` | off | Resolve everything and fill in the port groups, migrate nothing |
| `-VMotionNetworkLimit` | 8 | Set to 4 only on a 1GigE vMotion network |
| `-IgnoreExternalTasks` | off | Do not count other engineers' migrations against the budget |
| `-MigrationTimeoutMinutes` | 120 | A VM is reported `TimedOut` after this; the vCenter task keeps running |
| `-StopOnError` | off | Stop starting new migrations as soon as one VM fails |
| `-DatastoreReserveGB` | 100 | Free space that must remain on the target datastore (phase 2) |
| `-DiskStorageFormat` | `Thin` | Applied only when disks actually move |
| `-CsvFile` | - | Run this wave and skip the picker |
| `-NonInteractive` | off | Never prompt; run the only available wave or fail |
| `-TakeOver` | off | Take a wave another engineer's run still claims. Be sure their run is really gone |
| `-ArchiveRoot` | script folder | Where `Running/` and `Phase1..3/` live |
| `-IgnoreInvalidCertificate` | off | For vCenters with self-signed certificates |
| `-WhatIf` | off | Plan everything and report, without migrating |

Exit codes: `0` everything succeeded, `1` at least one VM failed, `2` the run itself
stopped (connection failure, bad wave, blocked by a limit).

## What is checked before a VM is touched

A VM is only migrated once all of this resolves - otherwise it is reported `Failed`, the
wave goes back to `IN`, and the run continues with the next VM:

* the VM exists and its name is unambiguous
* no pending vCenter question on the VM
* the destination cluster has a connected host (or the named host is connected)
* **phase 1**: every datastore the VM uses is mounted on the destination host - storage
  does not move in phase 1, so a host that cannot see the disks would fail the vMotion
* **phase 2**: the datastore exists and has room for the VM plus the reserve
* **phase 3**: the VM's datastore exists on the new vCenter under the same name, which is
  what "the same shared volume" means in practice
* **phases 1 and 3**: every network adapter resolves to exactly one target port group

Powered-off VMs are migrated as a cold relocate and logged as such. Work that is not
needed is not done: a VM already in the target cluster keeps the host DRS gave it, and a VM
that only needs its port groups changed is reconnected with `Set-NetworkAdapter` rather
than sent through a pointless relocate.

VM folder placement is not settable - VMs land in the default folder on the new vCenter.

## Logging

Each run writes `LOGS/bulk-vmotion_<engineer>_<timestamp>.log` with the VLAN table of every
switch used, the full plan for each VM (source, destination, datastore, switch, per adapter
port group mapping, and a `Will change` line naming compute/storage/network), migration
progress and a closing summary. Per wave and phase,
`LOGS/<wave>_phase<N>_<engineer>_result_<timestamp>.csv` records one row per VM with status,
duration, port groups and any failure message. Use `-LogLevel Debug` to also see why a VM
is waiting for capacity.

## Tests

```powershell
Invoke-Pester -Path .\Tests
```

`Tests/BulkVMotion.Tests.ps1` covers VLAN parsing, port group matching and lists, the phase
state machine, CSV write-back, the cost model, wave state and credentials.
`Tests/Invoke-BulkVMotion.Tests.ps1` runs the real script end to end against the PowerCLI
test doubles in `Tests/Fakes` - multi-NIC VMs, per-VM switches, the Running lifecycle
including a crashed run, concurrency ceilings, and one wave carried through all three
phases. No vCenter is needed and neither suite touches a live environment.

## Layout

```
Invoke-BulkVMotion.ps1              the runner
Save-MigrationCredential.ps1        one-time per engineer credential setup
Modules/BulkVMotion/                logging, CSV and phase handling, VLAN mapping,
                                    admission control, wave picker, migration
config/                             settings.json and portgroup-exceptions.csv (gitignored)
docs/samples/                       sample waves, config and exception map
Tests/                              Pester tests and the PowerCLI test doubles
```
