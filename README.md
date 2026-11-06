# Tidy

A macOS menu bar app that shows what is draining your battery, filling your memory and taking up your disk. It runs locally and is free.

## What it shows

- **Battery:** live system draw in watts, time left, GPU use and battery health. Apps are ranked by Apple's energy impact score, with a Since restart view for bursty background work. It also lists what is keeping the Mac awake or holding audio open, and you can close those.
- **Memory:** free memory, whether the Mac is writing swap to the SSD right now, and the apps using the most memory.
- **Disk:** large caches, build output, simulators, agent sessions and logs. Items go to the Trash only after you confirm.

**Ask Claude** sends the current list to your local [`claude` CLI](https://claude.com/claude-code) for advice. It's optional, and nothing else leaves the Mac.

## Build

Requires macOS 14 or later and the Swift toolchain.

```bash
./build.sh
open Tidy.app
```

Copy `Tidy.app` to `/Applications` to keep it.

## Safety

- System services and company-managed security tools can't be quit from Tidy.
- Stopping an App Store install needs admin rights. macOS asks for the password itself, and Tidy never sees it.
- The Disk tab refuses anything modified in the last 24 hours or outside your home folder. Chats and backups are never pre-ticked.

## Limits

Per-app numbers are an energy impact score, not watts. macOS doesn't split screen or GPU power per app without admin access.

## Debug checks

Debug builds include a self-test and a tab renderer:

```bash
swift build
.build/debug/Tidy --selftest
.build/debug/Tidy --snapshot <folder>
```

The self-test briefly opens and quits Chess, starts and stops `caffeinate`, and moves one empty test folder to the Trash.
