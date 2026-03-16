# OpenGrok Helper

This is a smart helper for your computer! It helps many "service boxes" (called OpenGrok) stay organized. It makes sure they do their work only when the computer is not busy and when it is nighttime.

## What It Does

- **Night Worker**: It only starts work at night (like from 6:00 PM to 6:00 AM) so it doesn't slow you down during the day.
- **Smart Listener**: It checks a list every few minutes to see if you changed any rules. You don't have to restart it!
- **Body Check**: 
  - **Brain (CPU)**: It checks how hard the computer's brain is working.
  - **Memory (RAM)**: It checks if there is enough space for the computer to think.
  - **Internet**: It checks if the internet is too busy.
  - **Disk**: It checks if the computer is busy reading or writing files.
- **Good Memory**: It uses a small notebook (called SQLite3) to remember which boxes finished their work and which ones are still waiting.
- **Helper Team**: It can help many boxes at the same time if the computer feels strong enough!
- **Friendly Reports**: It can tell you a summary of what it did if you ask for its "status."

## Where Things Are

```text
opengrok-scheduler/
├── bin/                # The tools and scripts (The brains)
├── sql/                # The layout for the notebook
├── data/               # Where the notebook is kept
├── tests/              # Games to check if the tools work right
├── logs/               # A diary of everything the helper did
├── README.md           # This guide
├── ARCHITECTURE.md     # A big map of how it works
└── TASK.md             # A checklist of things to do
```

## How to Start

### 1. What You Need
- A Linux computer
- Some special tools (SQLite3, sysstat)
- Docker (The boxes)

### 2. Make the Notebook
Run this to make the diary and notebook:
```bash
mkdir -p data logs
sqlite3 data/scheduler.db < sql/init_db.sql
```

### 3. Add Your Boxes
Tell the helper which boxes need to be organized:
```bash
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('box-1', 10);"
```

### 4. Start the Helper!
```bash
chmod +x bin/*.sh
./bin/scheduler.sh
```

## Fun Commands

### Do One Now! (--service)
If you want one box to finish right now, ask nicely:
```bash
./bin/scheduler.sh --service box-1
```

### How Are We Doing? (--status)
Ask the helper to show you a report:
```bash
./bin/scheduler.sh --status
```

### Start Over (--init)
If you want to clear today's diary and start fresh:
```bash
./bin/scheduler.sh --init
```

## Rules You Can Change

The helper looks at its notebook for these rules:

| Rule Name | What It Is | Normal Setting |
|:---|:---|:---|
| `start_time` | When to start working | `18:00` (6 PM) |
| `end_time` | When to stop working | `06:00` (6 AM) |
| `resource_threshold` | How busy the computer can be (%) | `70` |
| `check_interval` | How long to wait before checking again (seconds) | `300` (5 mins) |

## Testing

If you want to play and see if it works, try these:
```bash
./tests/test_monitor.sh           # Check if it can feel the computer's body
./tests/test_scheduler_logic.sh   # Check if it knows what time it is
```
