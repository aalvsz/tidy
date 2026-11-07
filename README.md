# Tidy

A macOS menu bar app that shows what is draining your battery, filling your memory and taking up your disk. It runs locally and is free.

## What it shows

- **Battery:** live system draw in watts, time left, GPU use and battery health. Apps are ranked by Apple's energy impact score, with a Since restart view for bursty background work. It also lists what is keeping the Mac awake or holding audio open, and you can close those.
- **Memory:** free memory, whether the Mac is writing swap to the SSD right now, and the apps using the most memory.
- **Disk:** large caches, build output, simulators, agent sessions and logs. Items go to the Trash only after you confirm.

## Optional AI advice

The **Ask** buttons explain what Tidy found and suggest what to delete. Everything else works without them. Pick a provider with the gear button:

| Provider | Uses | Needs |
|---|---|---|
| Auto | The first one below that's set up | Nothing |
| Claude Code | Your Claude subscription | [`claude` CLI](https://claude.com/claude-code), signed in |
| Codex | Your ChatGPT subscription | [`codex` CLI](https://github.com/openai/codex), signed in |
| OpenAI API | Pay per use | API key |
| Anthropic API | Pay per use | API key |
| Custom endpoint | Any OpenAI-compatible API, such as OpenRouter, Groq, Ollama or LM Studio | Base URL and model, plus a key if the endpoint needs one |

API keys are stored in your Keychain. The chosen provider receives process names and file paths from the current list. Nothing leaves the Mac until you press Ask.

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
.build/debug/Tidy --aitest
TIDY_TEST_KEY=... .build/debug/Tidy --endpoint <base URL> <model>
```

`--aitest` checks both API formats against a local stub server, so you don't need a key. It also asks each installed CLI for a real answer. `--endpoint` sends a ping and the real battery question to any OpenAI-compatible API. It reads the key from `TIDY_TEST_KEY`, so the key never appears in the command line.

The self-test briefly opens and quits Chess, starts and stops `caffeinate`, and moves one empty test folder to the Trash.
