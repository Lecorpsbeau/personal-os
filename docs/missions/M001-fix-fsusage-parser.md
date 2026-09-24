# M001 — Fix FSUsageParser

Status: DONE

## Phase

Phase 1 — Mac Detective

## Objective

Restore compilation by implementing the missing FSUsageParser used by FSUsageCollector and mac_detective.swift.

This mission focuses ONLY on the parser.

Do not redesign the entire Disk I/O system.

## Current problem

The project currently references:

```swift
FSUsageParser()

but no FSUsageParser type currently exists.

The project also expects:

parser.parse(line)

and:

parse(sample)
Expected input

Example fs_usage line:

21:55:20.636784    PgOut[AP]    D=0x0194580d  B=0x7000   /dev/disk3s6   0.000026 W kernel_task.117
Expected output

The parser should create a DiskProcessEvent containing:

timestamp
operation
bytes
processName
pid

For the example above:

processName = kernel_task
pid = 117
operation = W
bytes = 0x7000 converted to decimal
Requirements

The parser must:

Parse valid fs_usage diskio lines.
Extract the timestamp.
Extract the operation.
Extract the byte count.
Extract the process name.
Extract the PID.
Return nil for malformed lines.
Never crash on malformed input.
Be independently testable.
Allowed changes

Allowed:

apps/mac-detective/Sources/mac-detective/FSUsageCollector.swift
Create apps/mac-detective/Sources/mac-detective/FSUsageParser.swift
Add focused parser tests.

Do not modify unrelated modules.

Do NOT

Do not:

rewrite ProcessCollector
implement process rusage
modify Database
modify DiskCollector
modify NetworkCollector
redesign FSUsageCollector
add external dependencies
redesign the Disk I/O architecture
Acceptance criteria

The following must compile:

let parser = FSUsageParser()

let event = parser.parse(sample)

The parser test must print:

Parser OK

The project must pass:

swift build
swift test

Malformed input must be handled safely.

After completion:

Update CURRENT_STATE.md.
Change this mission status to DONE.
Commit with:
fix(mac-detective): implement fsusage parser

