# ClaudeProfiler

A macOS menu bar app that shows how much memory and CPU your Claude processes are eating.

![screenshot](https://github.com/1shanra1/claude-mac-profiler/assets/screenshot.png)

## Install

```bash
git clone https://github.com/1shanra1/claude-mac-profiler.git
cd claude-mac-profiler
./build.sh
open ClaudeProfiler.app
```

## What it does

- Lives in your menu bar as ◆ with total memory usage
- Click to see all Claude processes with memory/CPU breakdown
- Animated pixel art crab reacts to load — chills when idle, sweats when things get heavy
- Heat scales based on % of your system RAM used by Claude

## Credits

Crab sprites from [clawd-tank](https://github.com/marciogranzotto/clawd-tank) by Marcio Granzotto.
