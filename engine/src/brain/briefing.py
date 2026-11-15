"""Daily greeting, morning briefing, "Start my day" plan, end-of-day wrap-up
and nightly reflection (activity -> routine facts in the profile).

Rules from customer research: once per day, two short sentences, never during a
call, never launches anything without a tap or a "yes"."""
import datetime as dt
import os
import random

from src import storage
from src.life.activity import fmt_duration, friendly
from src.life.tasks import human_time


def _part_of_day(now):
    h = now.hour
    return "morning" if 4 <= h < 12 else "afternoon" if h < 17 else "evening"


class Briefing:
    def __init__(self, memory, tasks, notes, activity, settings=None, weather_fn=None, agent=None):
        self.memory, self.tasks, self.notes, self.activity = memory, tasks, notes, activity
        self.settings = settings
        self.weather_fn = weather_fn
        self.agent = agent
        self.state_file = storage.path("greeting_state.json")

    def _s(self, k, d):
        v = self.settings.get(k) if self.settings else None
        return d if v is None else v

    # ---------------------------------------------------------- triggers
    def should_greet(self, now=None, in_call=None):
        now = now or dt.datetime.now()
        if not self._s("daily_greeting", True) or in_call or now.hour < 4:
            return False
        st = storage.read_json(self.state_file, {}) or {}
        return st.get("last_greet_day") != now.strftime("%Y-%m-%d")

    def mark_greeted(self, now=None):
        st = storage.read_json(self.state_file, {}) or {}
        st["last_greet_day"] = (now or dt.datetime.now()).strftime("%Y-%m-%d")
        storage.write_json(self.state_file, st)

    # -------------------------------------------------------------- data
    def last_work_day(self, now=None):
        now = now or dt.datetime.now()
        for i in range(1, 15):
            d = (now - dt.timedelta(days=i)).strftime("%Y-%m-%d")
            if os.path.exists(os.path.join(self.activity.folder, f"{d}.json")) or self.notes.on_day(d):
                s = self.activity.summary(d)
                if s["total_active"] > 300 or self.notes.on_day(d):
                    return d, s
        return None, None

    def resolve_project(self, name=None):
        p = self.memory.profile
        projects = p.get("projects") or []
        name = (name or (p.get("routine") or {}).get("last_project") or "").lower()
        if name:
            for pr in projects:
                if pr["name"].lower() == name or os.path.basename(pr.get("path", "")).lower() == name:
                    return pr
            for pr in projects:
                if name in pr["name"].lower():
                    return pr
        d = (self._s("project_dir", "") or "").strip()
        if d and os.path.isdir(d):
            return {"name": os.path.basename(d.rstrip("\\/")), "path": d}
        return projects[0] if len(projects) == 1 else None

    def plan(self):
        """Steps for 'Start my day', learned from the routine (user confirms)."""
        steps = []
        routine = self.memory.profile.get("routine") or {}
        editor = (self.memory.profile.get("editor") or "").lower()
        ide_names = ("antigravity", "code", "cursor", "windsurf", "pycharm", "idea", "webstorm")
        project = self.resolve_project()
        extra = [{"exe": n.lower(), "name": n} for n in (self._s("morning_apps", []) or []) if n]
        for a in routine.get("usual_first_apps", [])[:3] + extra:
            if project and any(k in a["exe"] for k in ide_names):
                continue   # the project step opens the editor
            steps.append({"label": f"Open {a['name']}", "action": {"type": "app", "name": a["name"]}})
        if project:
            steps.append({"label": f"Open {project['name']} in your editor",
                          "action": {"type": "project_open", "path": project["path"], "name": project["name"]}})
            run = project.get("run") or (self.agent.detect_run_command(project["path"]) if self.agent else "")
            if run:
                steps.append({"label": f"Run {project['name']} ({run})",
                              "action": {"type": "project_run", "path": project["path"], "command": run}})
        elif editor:
            steps.append({"label": f"Open {self.memory.profile['editor']}",
                          "action": {"type": "app", "name": self.memory.profile["editor"]}})
        return steps

    def build(self, now=None, include_weather=True):
        now = now or dt.datetime.now()
        p = self.memory.profile
        name = p.get("preferred_name") or p.get("name") or ""
        part = _part_of_day(now)
        hello = random.choice([f"Good {part}{', ' + name if name else ''}!",
                               f"Good {part}{', ' + name if name else ''}."])
        lines = []

        day, s = self.last_work_day(now)
        if s:
            label = "Yesterday" if day == (now - dt.timedelta(days=1)).strftime("%Y-%m-%d") else \
                dt.datetime.strptime(day, "%Y-%m-%d").strftime("On %A")
            bits = [f"were active for {fmt_duration(s['total_active'])}"] if s["total_active"] > 600 else []
            if s["projects"]:
                bits.append(f"worked on {s['projects'][0]['name']} for {fmt_duration(s['projects'][0]['seconds'])}")
            elif s["top_apps"]:
                bits.append(f"spent most time in {s['top_apps'][0]['name']}")
            meetings = [n for n in self.notes.on_day(day) if n.get("kind") == "meeting"]
            if meetings:
                bits.append(f"had {len(meetings)} meeting{'s' if len(meetings) > 1 else ''} with notes")
            done = self.tasks.done_on(day)
            if done:
                bits.append(f"finished {len(done)} task{'s' if len(done) > 1 else ''}")
            if bits:
                lines.append(f"{label} you " + ", ".join(bits) + ".")
        reviews = [n for n in self.notes.items if n.get("review_pending")]
        if reviews:
            lines.append(f"{len(reviews)} meeting note{'s have' if len(reviews) > 1 else ' has'} action items to review.")

        open_tasks = [t for t in self.tasks.open_tasks() if t.get("source") != "timer"]
        today = now.strftime("%Y-%m-%d")
        due_today = [t for t in open_tasks if (t.get("remind_at") or "").startswith(today)]
        overdue = [t for t in open_tasks if t.get("remind_at") and t["remind_at"] < now.isoformat(timespec="minutes")
                   and not t["remind_at"].startswith(today)]
        if due_today:
            first = due_today[0]
            more = f" and {len(due_today) - 1} more" if len(due_today) > 1 else ""
            lines.append(f"Today: {first['title']} {human_time(first['remind_at'], now).replace('today ', '')}{more}.")
        elif overdue:
            lines.append(f"{len(overdue)} task{'s are' if len(overdue) > 1 else ' is'} still open from before — "
                         f"starting with “{overdue[0]['title']}”.")
        elif open_tasks:
            lines.append(f"You have {len(open_tasks)} open task{'s' if len(open_tasks) > 1 else ''}.")

        weather = None
        if include_weather and p.get("city") and self.weather_fn and self._s("internet_tools", True):
            try:
                weather = self.weather_fn(p["city"])
            except Exception:
                weather = None

        steps = self.plan()
        question = "Want me to set things up for you?" if steps else "What would you like to work on today?"
        return {"title": hello, "lines": lines, "question": question, "plan": steps, "weather": weather,
                "day": today}

    @staticmethod
    def spoken(b):
        """Two sentences max for the voice greeting."""
        parts = [b["title"]]
        if b["lines"]:
            parts.append(b["lines"][0])
        parts.append(b["question"])
        return " ".join(parts)

    # ------------------------------------------------------ end of day
    def wrap_up(self, day=None):
        day = day or storage.today()
        s = self.activity.summary(day)
        notes = self.notes.on_day(day)
        done = self.tasks.done_on(day)
        left = self.tasks.open_tasks()
        lines = []
        if s["total_active"]:
            lines.append(f"Active for {fmt_duration(s['total_active'])}"
                         + (f", {fmt_duration(s['focus_seconds'])} of it in focused blocks" if s["focus_seconds"] else "") + ".")
        if s["projects"]:
            lines.append("Projects: " + ", ".join(f"{p['name']} ({fmt_duration(p['seconds'])})" for p in s["projects"][:3]) + ".")
        meetings = [n for n in notes if n.get("kind") == "meeting"]
        if meetings:
            lines.append("Meetings: " + ", ".join(n.get("title", "meeting") for n in meetings) + ".")
        plain = [n for n in notes if n.get("kind") != "meeting"]
        if plain:
            lines.append(f"{len(plain)} note{'s' if len(plain) > 1 else ''} saved.")
        lines.append(f"{len(done)} task{'s' if len(done) != 1 else ''} done, {len(left)} open"
                     + (f" — next: {left[0]['title']}" if left else "") + ".")
        text = " ".join(lines)
        self.memory.set_journal_summary(day, text, field="wrapup")
        return {"day": day, "lines": lines, "text": text}

    # ------------------------------------------------------- reflection
    def reflect(self, now=None):
        """Nightly/at startup: refresh routine facts from activity history."""
        now = now or dt.datetime.now()
        r = self.activity.routine(today=now.date())
        if r["days_observed"]:
            self.memory.profile["routine"] = r
            self.memory.save_profile()
            # observed facts, upserted by key so they're replaced instead of piling up
            if r["days_observed"] >= 2:
                if r.get("typical_start"):
                    self.memory.upsert("obs_start", f"Usually starts work around {r['typical_start']} on weekdays",
                                       "routine", 3)
                if r.get("usual_first_apps"):
                    self.memory.upsert("obs_first_apps", "Usually opens " + ", ".join(
                        a["name"] for a in r["usual_first_apps"]) + " first thing", "routine", 2)
                if r.get("top_projects"):
                    self.memory.upsert("obs_projects", "Main projects lately: " + ", ".join(r["top_projects"]),
                                       "project", 3)
        try:
            self.memory.reflect()
        except Exception as e:
            print("[Briefing] memory reflection failed:", e)
        # summarize the previous day into the journal (used for "what did I do yesterday")
        y = (now - dt.timedelta(days=1)).strftime("%Y-%m-%d")
        j = self.memory.journal(y)
        if not j.get("wrapup") and (self.activity.summary(y)["total_active"] or self.notes.on_day(y)):
            self.wrap_up(y)
        return r
