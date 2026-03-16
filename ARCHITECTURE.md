# How the OpenGrok Helper Works

This page tells you how the helper module is built and how it stays smart.

## 1. What is it?
The OpenGrok Helper is like a teacher for many computer boxes. It makes sure each box finishes its work at the right time (usually at night) without making the computer too tired.

## 2. Cool Features
- **Time Watcher**: It knows when to work and when to sleep.
- **Feeling Checks**: 
  - **Brain (CPU)**: Checks if the "brain" is thinking too hard right now.
  - **Memory**: Checks if there is enough "thinking space" left.
  - **Internet**: Checks if the "internet pipe" is too full.
  - **Busy Score**: Checks if there are too many other programs running.
- **Fair Turns**: It makes sure every box gets a turn to work based on how long it usually takes.
- **Diary**: It writes down everything it does in a notebook so you can read it later.

## 3. The Tools It Uses
- **Language**: Bash (The secret code for computers)
- **Notebook**: SQLite3 (A tiny but very fast book to remember things)
- **Boxes**: Docker (Where the work actually happens)

## 4. The Notebook (Database)

### 4.1 Rules Table (`config`)
This is where the helper reads the rules, like "Work begins at 6 PM."

### 4.2 Boxes Table (`services`)
This is a list of all the boxes the helper needs to look after.

### 4.3 Work Table (`jobs`)
This is where the helper writes down when a box started and finished its work.

## 5. How It Thinks (The Big Loop)

### 5.1 The Main Plan
1. Read the rules from the notebook.
2. Check the clock. If it's too early or too late, go back to sleep.
3. Check the computer's body. If it's too tired (like the brain is at 70%), wait for a bit.
4. Look for the next box that needs help. It picks the one that usually takes the most time!
5. Start the work and write it down in the diary.

### 5.2 Looking at Feelings
- **Brain**: It looks at how busy the brain is right now.
- **Memory**: It looks at how much space is left for new thoughts.
- **Disk**: It looks at how busy the computer is reading books (files).
- **Internet**: It looks at how fast the internet is moving.

## 6. Asking the Helper
You can ask the helper, "How are you doing?" by typing `--status`. It will show you a list of boxes and if they are done or still waiting.

## 7. Special Tricks
- **Language Help**: It understands many languages so it doesn't get confused by different words.
- **Safe Writing**: It is very careful when writing in its notebook so it doesn't lose any information.
