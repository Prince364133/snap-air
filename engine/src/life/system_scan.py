"""First-run "get to know this PC": installed editors/browsers/apps and the
user's project folders. Runs locally; results seed the profile."""
import os
import re

EDITORS = [("antigravity", "Antigravity"), ("visual studio code", "VS Code"), ("cursor", "Cursor"),
           ("windsurf", "Windsurf"), ("pycharm", "PyCharm"), ("intellij", "IntelliJ IDEA"),
           ("webstorm", "WebStorm"), ("android studio", "Android Studio"), ("sublime text", "Sublime Text"),
           ("zed", "Zed"), ("visual studio 20", "Visual Studio"), ("notepad++", "Notepad++")]
BROWSERS = [("google chrome", "Chrome"), ("brave", "Brave"), ("microsoft edge", "Edge"),
            ("firefox", "Firefox"), ("opera", "Opera"), ("arc", "Arc"), ("vivaldi", "Vivaldi")]
COMMS = [("slack", "Slack"), ("teams", "Teams"), ("zoom", "Zoom"), ("discord", "Discord"),
         ("whatsapp", "WhatsApp"), ("telegram", "Telegram"), ("outlook", "Outlook")]
MARKERS = ("package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "pubspec.yaml",
           "pom.xml", "build.gradle", "composer.json", "Gemfile", ".git")
SKIP = {"node_modules", ".venv", "venv", "env", ".git", "dist", "build", "__pycache__", ".next", "target",
        "AppData", "Program Files", "Windows", ".gradle", ".cache", "site-packages", "vendor"}


def scan_apps(app_index):
    app_index.ready.wait(timeout=20)
    names = list(app_index.apps)

    def present(table):
        found = []
        for key, label in table:
            if any(key in n for n in names) and label not in found:
                found.append(label)
        return found

    return {"editors": present(EDITORS), "browsers": present(BROWSERS), "communication": present(COMMS),
            "app_count": len(names)}


def _project_info(path):
    name = os.path.basename(path.rstrip("\\/"))
    kind = []
    if os.path.exists(os.path.join(path, "package.json")):
        kind.append("node")
    if any(os.path.exists(os.path.join(path, f)) for f in ("pyproject.toml", "requirements.txt", "manage.py")):
        kind.append("python")
    if os.path.exists(os.path.join(path, "pubspec.yaml")):
        kind.append("flutter")
    if os.path.exists(os.path.join(path, "Cargo.toml")):
        kind.append("rust")
    if os.path.exists(os.path.join(path, "go.mod")):
        kind.append("go")
    try:
        mtime = max(os.path.getmtime(os.path.join(path, f)) for f in os.listdir(path)[:200])
    except (OSError, ValueError):
        mtime = 0
    return {"name": name, "path": path, "kind": kind, "mtime": mtime}


def find_projects(roots=None, max_depth=3, limit=40):
    home = os.path.expanduser("~")
    roots = roots or [os.path.join(home, d) for d in
                      ("Desktop", "Documents", "projects", "Projects", "code", "Code", "dev", "source\\repos",
                       "workspace", "repos", "github", "src")]
    found = {}

    def walk(d, depth):
        if depth > max_depth or len(found) >= limit * 3:
            return
        try:
            entries = os.listdir(d)
        except OSError:
            return
        if any(m in entries for m in MARKERS) and d not in roots:
            found[os.path.normcase(d)] = _project_info(d)
            return   # don't descend into a project's subfolders
        for e in entries:
            if e in SKIP or e.startswith("."):
                continue
            p = os.path.join(d, e)
            if os.path.isdir(p):
                walk(p, depth + 1)

    for r in roots:
        if os.path.isdir(r):
            walk(r, 0)
    projects = sorted(found.values(), key=lambda p: -p["mtime"])[:limit]
    return projects


def guess_name():
    user = os.environ.get("USERNAME") or os.path.basename(os.path.expanduser("~"))
    user = re.sub(r"[\d_.]+", " ", user).strip()
    return user.split()[0].title() if user else ""


def scan(app_index):
    apps = scan_apps(app_index)
    projects = find_projects()
    from src.brain.llm import recommend_model, system_ram_gb
    total, free = system_ram_gb()
    return {"apps": apps, "projects": [{k: p[k] for k in ("name", "path", "kind")} for p in projects],
            "name_guess": guess_name(), "ram_total": round(total, 1), "ram_free": round(free, 1),
            "recommended_model": recommend_model(total, free)}
