# Victor

All-in-one minimalist daily companion — built for Victor. Apple-inspired UI (soft whites, system typography, rounded cards, bottom tab bar).

## Features

- **Home dashboard** — greeting, date, and today's vitals at a glance
- **Screen time** — pick a social app, start a session; warned at 25 min, alerted at 30 min ("time to log off"). Daily 30-minute limit with history
- **Workouts** — custom timer (h/m/s) + 12 home exercises with illustrations (push-ups, squats, plank, jumping jacks, lunges, burpees, sit-ups, glute bridge, mountain climbers, dips, pistol squat, handstand push-up)
- **Boxing / Jiu-Jitsu** — illustrated techniques: stance, jab, cross, hook, uppercut, footwork, guard, slip; and shrimping, breakfall, closed guard, mount, side control, armbar, triangle, rear naked choke, kimura
- **Bible verses** — random verse notifications every 10 minutes (opt-in), plus a verse of the moment on the Bible tab
- **Daily schedule** — add activities with time and category; reminders repeat until you tap "I've started" (the alarm won't stop until you begin)
- **Water** — log glasses against a daily goal, reminders every hour
- **Sleep** — log bedtime/wake time, track duration and 7-night average
- **Heart rate** — wellness measurement with food/diet recommendations based on your reading (not a medical device)
- **Habits** — daily habit tracker with streaks
- **Focus** — Pomodoro-style focus timer (25 min work / 5 min break)
- **Journal** — mood-based daily entries
- **Settings** — notification permissions, data export/reset

## How to use

Open `Victor/index.html` in any modern browser, or serve it with a local server:

```bash
cd /workspace/Victor
python3 -m http.server 8000
# then open http://localhost:8000
```

For the full "app" experience, add it to your home screen (PWA). It works offline thanks to the service worker.

## Notes

- **Screen time**: browsers cannot access other apps' usage, so sessions are self-reported — start a session when you open a social app and Victor enforces the 30-minute limit.
- **Heart rate**: simulated reading for wellness purposes only — not a medical device.
- **Notifications**: browser notifications require permission and work while the tab/app is open; persistent in-app alarms keep ringing until you start an activity.

## Tech

Vanilla HTML/CSS/JS, localStorage persistence, service worker for offline use. No build step, no dependencies.