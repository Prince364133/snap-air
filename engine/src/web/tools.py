"""Internet tools, used only when the user asks for something online.
Fetched text is treated as untrusted data by the assistant prompt."""
import html
import re
import urllib.parse

import requests
from src import diag  # noqa: E402

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) SnapAir/2.0",
      "Accept-Language": "en-US,en;q=0.9"}


def online(timeout=2):
    try:
        requests.head("https://duckduckgo.com", timeout=timeout, headers=UA)
        return True
    except requests.RequestException:
        return False


def _text(fragment):
    t = re.sub(r"<[^>]+>", " ", fragment)
    return re.sub(r"\s+", " ", html.unescape(t)).strip()


def web_search(query, k=5):
    r = requests.post("https://html.duckduckgo.com/html/", data={"q": query}, headers=UA, timeout=8)
    r.raise_for_status()
    results = []
    for m in re.finditer(r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>.*?'
                         r'(?:<a[^>]+class="result__snippet"[^>]*>(.*?)</a>)?', r.text, re.S):
        href = html.unescape(m.group(1))
        q = urllib.parse.urlparse(href)
        if "uddg" in q.query:
            href = urllib.parse.parse_qs(q.query).get("uddg", [href])[0]
        if "duckduckgo.com/y.js" in href:
            continue   # ads
        results.append({"title": _text(m.group(2)), "url": href, "snippet": _text(m.group(3) or "")})
        if len(results) >= k:
            break
    return results


def read_page(url, max_chars=6000):
    r = requests.get(url, headers=UA, timeout=10)
    r.raise_for_status()
    page = r.text
    title = _text(re.search(r"<title[^>]*>(.*?)</title>", page, re.S | re.I).group(1)) if re.search(
        r"<title", page, re.I) else url
    page = re.sub(r"(?is)<(script|style|noscript|svg|nav|footer|header|form|aside)[^>]*>.*?</\1>", " ", page)
    main = re.search(r"(?is)<(article|main)[^>]*>(.*?)</\1>", page)
    body = main.group(2) if main else page
    paras = [_text(p) for p in re.findall(r"(?is)<(?:p|h[1-3]|li)[^>]*>(.*?)</(?:p|h[1-3]|li)>", body)]
    text = "\n".join(p for p in paras if len(p) > 30) or _text(body)
    return {"title": title, "url": url, "text": text[:max_chars]}


CDP = "http://127.0.0.1:9222"


def current_tab(max_chars=8000):
    """The page open in Chrome/Edge (started with --remote-debugging-port=9222).
    Uses Playwright over CDP when installed (sees logged-in pages), else fetches the URL."""
    try:
        tabs = requests.get(CDP + "/json", timeout=2).json()
    except (requests.RequestException, ValueError):
        return None
    pages = [t for t in tabs if t.get("type") == "page" and t.get("url", "").startswith("http")]
    if not pages:
        return None
    tab = pages[0]                      # most recently focused tab is listed first
    try:
        from playwright.sync_api import sync_playwright  # optional dependency
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(CDP)
            for ctx in browser.contexts:
                for page in ctx.pages:
                    if page.url == tab["url"]:
                        return {"title": page.title(), "url": page.url, "text": page.inner_text("body")[:max_chars]}
    except Exception as e:
        diag.record("web.cdp_read", e, quiet=True)
    try:
        page = read_page(tab["url"], max_chars)
        page["title"] = tab.get("title") or page["title"]
        return page
    except Exception:
        return {"title": tab.get("title", ""), "url": tab["url"], "text": ""}


WMO = {0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "fog",
       51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
       71: "light snow", 73: "snow", 75: "heavy snow", 80: "rain showers", 81: "rain showers",
       82: "heavy showers", 95: "thunderstorms", 96: "thunderstorms", 99: "thunderstorms"}


def weather(city):
    g = requests.get("https://geocoding-api.open-meteo.com/v1/search",
                     params={"name": city, "count": 1}, timeout=6).json()
    if not g.get("results"):
        return None
    loc = g["results"][0]
    w = requests.get("https://api.open-meteo.com/v1/forecast", timeout=6, params={
        "latitude": loc["latitude"], "longitude": loc["longitude"], "current": "temperature_2m,weather_code",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max", "timezone": "auto",
        "forecast_days": 1}).json()
    cur, day = w.get("current", {}), w.get("daily", {})
    return {
        "city": loc.get("name", city),
        "temp": round(cur.get("temperature_2m", 0)),
        "desc": WMO.get(cur.get("weather_code"), "—"),
        "high": round((day.get("temperature_2m_max") or [0])[0]),
        "low": round((day.get("temperature_2m_min") or [0])[0]),
        "rain": (day.get("precipitation_probability_max") or [0])[0],
    }
