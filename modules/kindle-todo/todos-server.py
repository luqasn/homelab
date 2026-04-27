import os
import pathlib
import io
import xml.etree.ElementTree as ET
from datetime import datetime, date

import requests
from requests.auth import HTTPBasicAuth
from icalendar import Calendar
from PIL import Image, ImageDraw, ImageFont
from flask import Flask, Response

app = Flask(__name__)

def _read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()

def _get_secret(env_var):
    # Prefer direct env var
    value = os.environ.get(env_var)
    if value:
        return value

    # Fallback to file
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    file_path = pathlib.Path(cred_dir, env_var)
    if file_path:
        return _read_file(file_path)

    raise KeyError(f"Missing required secret: {env_var}")

# ── Config ────────────────────────────────────────────────────────────────────
NC_URL    = os.environ["NC_URL"]       # https://cloud.example.com
NC_USER = _get_secret("NC_USER")
NC_PASS = _get_secret("NC_PASS")
NC_LIST   = os.environ.get("NC_LIST", "todo")
LISTEN    = os.environ.get("LISTEN", "0.0.0.0")
PORT      = int(os.environ.get("PORT", "8765"))

# Kindle 4 native resolution
K_W, K_H  = 600, 800

FONT_PATHS = list(filter(None, [
    os.environ.get("FONT_PATH"),          # injected by nix wrapper
    "/run/current-system/sw/share/fonts/truetype/",
    "/run/current-system/sw/share/fonts/truetype/dejavu/",
    "/usr/share/fonts/truetype/dejavu/",
    "/usr/share/fonts/dejavu/",
    "/usr/share/fonts/TTF/",
]))

def to_date(d):
    if d is None:
        return date.max
    return d.date() if isinstance(d, datetime) else d

def fetch_todos():
    url = NC_URL.rstrip("/") + f"/remote.php/dav/calendars/{NC_USER}/{NC_LIST}/"

    # Minimal valid filter: just ask for all VTODO components.
    # Status filtering ("not COMPLETED / CANCELLED") is done in Python below.
    body = """<?xml version="1.0" encoding="UTF-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop>
    <D:getetag/>
    <C:calendar-data/>
  </D:prop>
  <C:filter>
    <C:comp-filter name="VCALENDAR">
      <C:comp-filter name="VTODO"/>
    </C:comp-filter>
  </C:filter>
</C:calendar-query>"""

    r = requests.request(
        "REPORT", url, data=body,
        auth=HTTPBasicAuth(NC_USER, NC_PASS),
        headers={"Content-Type": "application/xml", "Depth": "1"},
        timeout=15,
    )
    r.raise_for_status()

    pending = []
    done    = []
    root = ET.fromstring(r.text)
    for cd in root.iter("{urn:ietf:params:xml:ns:caldav}calendar-data"):
        cal = Calendar.from_ical(cd.text)
        for component in cal.walk("VTODO"):
            status = str(component.get("STATUS", "NEEDS-ACTION")).upper()
            due      = component.get("DUE")
            priority = int(component.get("PRIORITY", 0))
            item = {
                "summary":  str(component.get("SUMMARY", "Untitled")),
                "due":      due.dt if due else None,
                "priority": priority,
            }
            if status in ("COMPLETED", "CANCELLED"):
                done.append(item)
            else:
                pending.append(item)

    pending.sort(key=lambda t: (
        t["priority"] if 1 <= t["priority"] <= 4 else 99,
        to_date(t["due"]),
    ))
    done.sort(key=lambda t: t["summary"])
    return pending, done

# ── Render (Kindle 4 — 600×800, 16-level grayscale) ──────────────────────────
def render_png(todos, done_todos=None) -> bytes:
    if done_todos is None:
        done_todos = []

    PAD   = 20
    ROW_H = 58

    max_rows = (K_H - 2 * PAD) // ROW_H

    # Clamp pending rows; show done rows only when all pending fit
    visible_pending = todos[:max_rows]
    overflow        = len(todos) - len(visible_pending)
    if overflow == 0:
        remaining      = max_rows - len(visible_pending)
        visible_done   = done_todos[:remaining]
    else:
        visible_done   = []

    # Pure grayscale palette — high contrast for e-ink
    BG     = 255   # white
    FG     = 0     # black
    DUE_G  = 110   # medium gray for due-date text
    OVER_G = 30    # near-black for overdue
    DONE_G = 150   # gray for completed items

    img  = Image.new("L", (K_W, K_H), BG)
    draw = ImageDraw.Draw(img)

    def font(name, size):
        for path in FONT_PATHS:
            try:
                return ImageFont.truetype(path + name, size, encoding="unic")
            except OSError:
                continue
        return ImageFont.load_default()

    f_body  = font("DejaVuSans.ttf",      26)
    f_small = font("DejaVuSans.ttf",      20)
    f_bold  = font("DejaVuSans-Bold.ttf", 26)

    today  = datetime.today().date()
    y_base = PAD

    def draw_row(i, todo, y, is_done=False):
        row_fg = DONE_G if is_done else FG

        # Due date (right-aligned, before truncating summary)
        due_w = 0
        if todo["due"] and not is_done:
            due_d  = to_date(todo["due"])
            days   = (due_d - today).days
            if days < 0:
                due_str = f"! {due_d.strftime('%d %b')}"
                color   = OVER_G
            elif days < 7:
                due_str = f"noch {days} Tage" if days > 0 else "heute"
                color   = OVER_G
            else:
                due_str = due_d.strftime("%d %b")
                color   = DUE_G
            due_w  = draw.textlength(due_str, font=f_small)
            due_x  = K_W - PAD - due_w
            due_ty = y + (ROW_H - 20) // 2
            draw.text((due_x, due_ty), due_str, font=f_small, fill=color)

        # Summary text — truncate to fit available width
        text_x  = PAD
        avail_w = K_W - text_x - PAD - (due_w + 10 if due_w else 0)
        summary = todo["summary"]
        while summary and draw.textlength(summary, font=f_body) > avail_w:
            summary = summary[:-1]
        if summary != todo["summary"]:
            summary = summary[:-1] + "…"

        text_y = y + (ROW_H - 26) // 2

        # Render word-by-word so @mentions appear in grey
        ASSIGN_G = 160
        x = text_x
        words = summary.split(" ")
        for wi, word in enumerate(words):
            segment = word + (" " if wi < len(words) - 1 else "")
            color   = ASSIGN_G if word.startswith("@") else row_fg
            draw.text((x, text_y), segment, font=f_body, fill=color)
            x += draw.textlength(segment, font=f_body)

        # Strikethrough for done items
        if is_done:
            tw    = draw.textlength(summary, font=f_body)
            mid_y = text_y + 13
            draw.line([text_x, mid_y, text_x + tw, mid_y], fill=DONE_G, width=2)

    if not visible_pending and not visible_done:
        draw.text((PAD, y_base + 12), "All done — nothing pending!", font=f_body, fill=FG)
    else:
        for i, todo in enumerate(visible_pending):
            draw_row(i, todo, y_base + i * ROW_H)

        if visible_done:
            off = len(visible_pending)
            for j, todo in enumerate(visible_done):
                draw_row(off + j, todo, y_base + (off + j) * ROW_H, is_done=True)

    # Quantise to 16 levels — matches Kindle 4's actual e-ink palette
    img = img.quantize(colors=16).convert("L")

    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()

# ── Flask routes ──────────────────────────────────────────────────────────────
@app.route("/todos.png")
def todos_png():
    try:
        pending, done = fetch_todos()
        png   = render_png(pending, done)
        return Response(png, mimetype="image/png",
                        headers={"Cache-Control": "no-store"})
    except Exception as exc:
        # Return a plain error image rather than an HTML 500 page
        img  = Image.new("L", (K_W, K_H), 255)
        draw = ImageDraw.Draw(img)
        draw.text((28, 28), "Error fetching todos:", font=ImageFont.load_default(), fill=0)
        draw.text((28, 52), str(exc)[:80],           font=ImageFont.load_default(), fill=0)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return Response(buf.getvalue(), status=502, mimetype="image/png")

@app.route("/healthz")
def health():
    return "ok"

if __name__ == "__main__":
    app.run(host=LISTEN, port=PORT)
