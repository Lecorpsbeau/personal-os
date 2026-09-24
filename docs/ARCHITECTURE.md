# Personal OS — Architecture

Personal OS is a modular personal operating system.

## Phase 1 — Mac Detective

Mac Detective collects information about the Mac, detects unusual activity, and stores historical data.

### Architecture

```text
MacDetective
│
├── System metrics
│   ├── CPU
│   ├── Memory
│   ├── Disk
│   └── Network
│
├── Process metrics
│   ├── PID
│   ├── Name
│   ├── CPU usage
│   ├── Memory
│   └── Disk I/O (in development)
│
├── Detection
│   └── Detector
│
├── Persistence
│   └── SQLite Database
│
└── Disk activity investigation
    ├── FSUsageCollector
    ├── FSUsageParser
    └── CProcessRusage
Main components
mac_detective.swift

Main entry point.

Responsibilities:

initialize collectors
collect periodic snapshots
save snapshots
run detections
print useful information

The main file should remain relatively thin.

SystemSnapshot

Represents a complete system snapshot.

Contains:

timestamp
CPU
memory
disk activity
network activity
processes
ProcessCollector

Collects process-level information:

PID
process name
CPU usage
memory usage
disk I/O

Process-level disk I/O is currently incomplete.

DiskCollector

Collects global disk activity using IOKit.

NetworkCollector

Collects network traffic using Darwin networking APIs.

Detector

Detects unusual activity such as:

CPU spikes
memory spikes
disk activity spikes
network spikes
Database

SQLite persistence layer.

Current tables:

system_samples
process_samples
events
CProcessRusage

C bridge intended to retrieve process-level disk I/O using macOS process resource usage APIs.

FSUsageCollector

Runs macOS fs_usage and receives filesystem activity.

FSUsageParser

Parses fs_usage output into structured DiskProcessEvent objects.

This component is currently missing and is the subject of mission M001.

Disk I/O architecture

There are two distinct concepts:

Global disk activity

Collected by DiskCollector.

This answers:

How much is the entire system reading/writing?

Process disk activity

Collected through:

CProcessRusage
fs_usage

This answers:

Which process is responsible for disk activity?

These systems should not be confused.

Technical debt

Current known technical debt:

FSUsageParser missing
FSUsageCollector incomplete
CProcessRusage integration incomplete
process_samples does not yet reliably store disk I/O
tests are minimal
SQLite schema will evolve
main entry point contains too much orchestration
Future architecture
Mac Detective
      │
      ▼
Life API
      │
      ▼
Personal OS Database
      │
      ├── Dashboard
      ├── Chrome Extension
      ├── 2nd Brain
      ├── Agenda
      ├── Tasks
      └── OSINT Hub

