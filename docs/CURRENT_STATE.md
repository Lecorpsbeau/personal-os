# Personal OS — Current State

## Last updated
2026-09-24

## Current phase
Phase 1 — Mac Detective

## Overall status
In active development.

## Working components

- Process monitoring
- CPU monitoring
- RAM monitoring
- Network monitoring
- Disk monitoring
- SQLite snapshots
- Event/history system
- Periodic sampling

## Current task

Implement process-level Disk I/O monitoring.

The goal is to identify which processes are responsible for disk activity, not only global disk usage.

## Current blocker

The project currently fails to compile with:

`cannot find 'FSUsageParser' in scope`

Location:

`apps/mac-detective/Sources/mac-detective/mac_detective.swift`

Relevant code:

```swift
let parser = FSUsageParser()
bash
cat > docs/ROADMAP.md <<'EOF'
# Personal OS — Roadmap

## Phase 1 — Mac Detective
Status: IN PROGRESS

### Core monitoring
- [x] Process monitoring
- [x] CPU monitoring
- [x] RAM monitoring
- [x] Network monitoring
- [x] Global Disk monitoring
- [x] SQLite snapshots
- [x] Event/history system
- [x] Periodic sampling

### Disk I/O
- [ ] Process-level Disk I/O
- [ ] FSUsageParser
- [ ] Disk I/O history
- [ ] Disk activity ranking
- [ ] Tests
- [ ] Stable release

---

## Phase 2 — Life API
Status: PLANNED

- [ ] Define shared data model
- [ ] API architecture
- [ ] Authentication/local security
- [ ] Database layer
- [ ] Mac Detective API
- [ ] Events API
- [ ] Tasks API
- [ ] Calendar API
- [ ] Notes API

---

## Phase 3 — Dashboard
Status: PLANNED

- [ ] Dashboard architecture
- [ ] System overview
- [ ] Mac statistics
- [ ] Tasks
- [ ] Calendar
- [ ] Courses
- [ ] Activity
- [ ] Goals
- [ ] Personal statistics

---

## Phase 4 — Chrome Extension
Status: PLANNED

- [ ] Browser activity
- [ ] Time tracking
- [ ] Website classification
- [ ] Distraction tracking
- [ ] Save pages
- [ ] Send data to Life API

---

## Phase 5 — OSINT Hub
Status: PLANNED

- [ ] Search
- [ ] Source collection
- [ ] Notes
- [ ] Entity relationships
- [ ] Research projects
- [ ] AI-assisted synthesis

---

## Phase 6 — 2nd Brain
Status: PLANNED

### Course capture
- [ ] Audio input
- [ ] Transcription
- [ ] Course extraction
- [ ] Definitions
- [ ] Formulas
- [ ] Examples

### Revision
- [ ] Automatic summaries
- [ ] Revision sheets
- [ ] QCM generation
- [ ] Spaced repetition
- [ ] Progress tracking

### Tablet workflow
- [ ] Tablet audio capture
- [ ] Sync with Personal OS
- [ ] Automatic processing

---

## Phase 7 — Agenda
Status: PLANNED

- [ ] Events
- [ ] Deadlines
- [ ] Exams
- [ ] Reminders
- [ ] Smart planning
- [ ] Revision scheduling

---

## Phase 8 — Tasks
Status: PLANNED

- [ ] Todo system
- [ ] Projects
- [ ] Priorities
- [ ] Deadlines
- [ ] Recurring tasks
- [ ] Link tasks to courses
- [ ] Link tasks to calendar
- [ ] Link tasks to goals

---

# Long-term vision

Personal OS should become a unified personal system connecting:

Mac + Browser + Courses + Knowledge + Calendar + Tasks + Projects + AI.
