#!/usr/bin/env python3
"""
KindlePorter — Tandoor → Kindle web service.
Fetches a recipe from Tandoor, builds a MOBI, uploads via SSH to a jailbroken Kindle.

Run:
    cp .env.example .env          # fill in your settings
    python3 app.py
    open http://localhost:5000
"""

import io
import json
import os
import pathlib
import queue
import re
import shutil
import subprocess
import tempfile
import threading
import time
import html as html_lib
import urllib.error
import urllib.request
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request, stream_with_context

try:
    import paramiko
except ImportError:
    raise SystemExit("pip install paramiko")

try:
    from ebooklib import epub
except ImportError:
    raise SystemExit("pip install ebooklib")

app = Flask(__name__)

# ── Config (from .env or environment) ───────────────────────────────────────

def _read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()

def _get_secret(env_var, default=None):
    # Prefer direct env var
    value = os.environ.get(env_var)
    if value:
        return value

    # Fallback to file
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not cred_dir:
        return default
    file_path = pathlib.Path(cred_dir, env_var)

    if file_path.is_file():
        return _read_file(file_path)

    if default is not None:
        return default
    raise KeyError(f"Missing required secret: {env_var}")

CFG = {
    "TANDOOR_URL":       os.getenv("TANDOOR_URL", ""),
    "TANDOOR_TOKEN":     _get_secret("TANDOOR_TOKEN"),
    "KINDLE_HOST":       os.getenv("KINDLE_HOST", ""),
    "KINDLE_PORT":       int(os.getenv("KINDLE_PORT", "22")),
    "KINDLE_USER":       os.getenv("KINDLE_USER", "root"),
    "KINDLE_PASSWORD":   _get_secret("KINDLE_PASSWORD", ""),
    "KINDLE_KEY_PATH":   os.getenv("KINDLE_KEY_PATH", (os.environ.get("CREDENTIALS_DIRECTORY") or '') + '/KINDLE_KEY' ),
    "KINDLE_DOCS_PATH":  os.getenv("KINDLE_DOCS_PATH", "/mnt/us/documents/"),
    "PORT":              int(os.environ.get("PORT", "8766")),
}


# ── Tandoor API ──────────────────────────────────────────────────────────────

def tandoor_get(path: str, base_url: str, token: str) -> dict:
    url = f"{base_url.rstrip('/')}{path}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())


def list_recipes(base_url: str, token: str) -> list[dict]:
    """Fetch all recipes from Tandoor (handles pagination)."""
    recipes = []
    page = 1
    while True:
        data = tandoor_get(f"/api/recipe/?page={page}", base_url, token)
        results = data.get("results", [])
        if not results and page == 1 and isinstance(data, list):
            # Some versions return a plain list
            recipes.extend(data)
            break
        recipes.extend(results)
        if not data.get("next"):
            break
        page += 1
    return recipes


def fetch_image_bytes(image_url: str, base_url: str, token: str) -> bytes | None:
    if not image_url:
        return None
    if not image_url.startswith("http"):
        image_url = f"{base_url.rstrip('/')}{image_url}"
    req = urllib.request.Request(image_url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read()
    except Exception:
        return None


# ── eBook builder ────────────────────────────────────────────────────────────

KINDLE_CSS = """
body { font-family: Georgia, serif; font-size: 1em; line-height: 1.6; color: #000; margin: 0; padding: 0; }
h1 { font-size: 1.6em; text-align: center; border-bottom: 2px solid #000; padding-bottom: 0.3em; }
h2 { font-size: 1.2em; margin-top: 1.2em; border-bottom: 1px solid #555; }
.meta { text-align: center; font-size: 0.85em; color: #444; margin-bottom: 1em; }
.description { font-style: italic; border-left: 3px solid #aaa; padding-left: 0.8em; margin-bottom: 1em; }
table.ing { width: 100%; border-collapse: collapse; font-size: 0.9em; margin-bottom: 1em; }
table.ing th { text-align: left; border-bottom: 1px solid #000; padding: 0.2em 0.4em; }
table.ing td { padding: 0.2em 0.4em; border-bottom: 1px solid #ddd; vertical-align: top; }
td.amt, td.unit { white-space: nowrap; width: 5em; }
.steps ol { padding-left: 1.2em; }
.steps li { margin-bottom: 0.8em; }
.step-ing { font-size: 0.9em; font-style: italic; color: #333; margin-bottom: 0.3em; }
.step-ing strong { font-style: normal; }
.cover { text-align: center; padding-top: 3em; }
.cover h1 { font-size: 2em; border: none; }
.cover .sub { font-size: 0.9em; color: #555; margin-top: 2em; }
"""


def _fmt(amount) -> str:
    if amount is None: return ""
    try:
        f = float(amount)
        return str(int(f)) if f == int(f) else f"{f:.2g}"
    except Exception:
        return str(amount)


def _ingredients_html(steps):
    rows, seen = [], set()
    for step in steps:
        for ing in step.get("ingredients", []):
            food = (ing.get("food") or {})
            unit = (ing.get("unit") or {})
            name = food.get("name", "")
            if not name: continue
            unit_name = unit.get("name", "")
            amount = _fmt(ing.get("amount"))
            key = (name, unit_name, amount)
            if key in seen: continue
            seen.add(key)
            note = ing.get("note", "")
            note_html = f" <em>({html_lib.escape(note)})</em>" if note else ""
            rows.append(
                f"<tr><td class='amt'>{html_lib.escape(amount)}</td>"
                f"<td class='unit'>{html_lib.escape(unit_name)}</td>"
                f"<td>{html_lib.escape(name)}{note_html}</td></tr>"
            )
    if not rows: return ""
    return (
            "<h2>Ingredients</h2>"
            "<table class='ing'><tr><th>Amount</th><th>Unit</th><th>Ingredient</th></tr>"
            + "".join(rows) + "</table>"
    )


def _step_ingredients_html(ingredients):
    """Format ingredients belonging to a single step."""
    parts = []
    for ing in ingredients:
        food = (ing.get("food") or {})
        unit = (ing.get("unit") or {})
        name = food.get("name", "")
        if not name:
            continue
        unit_name = unit.get("name", "")
        amount = _fmt(ing.get("amount"))
        note = ing.get("note", "")
        line = f"{html_lib.escape(amount)} {html_lib.escape(unit_name)} {html_lib.escape(name)}".strip()
        if note:
            line += f" <em>({html_lib.escape(note)})</em>"
        parts.append(line)
    if not parts:
        return ""
    return "<p class='step-ing'><strong>Ingredients:</strong> " + "; ".join(parts) + "</p>"


def _steps_html(steps):
    items = []
    for step in steps:
        inst = (step.get("instruction") or "").strip()
        if not inst:
            continue
        inst = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", inst)
        inst = re.sub(r"\*(.+?)\*", r"<em>\1</em>", inst)
        inst = inst.replace("\n", "<br/>")
        step_ing = _step_ingredients_html(step.get("ingredients", []))
        items.append(f"<li>{step_ing}{inst}</li>")
    if not items:
        return ""
    return "<div class='steps'><h2>Instructions</h2><ol>" + "".join(items) + "</ol></div>"


def build_epub(recipe: dict, base_url: str, token: str) -> bytes:
    name = recipe.get("name", "Recipe")
    book = epub.EpubBook()
    book.set_identifier(f"tandoor-{recipe.get('id', 0)}")
    book.set_title(name)
    book.set_language("en")

    css_item = epub.EpubItem(uid="style", file_name="styles/k.css",
                             media_type="text/css", content=KINDLE_CSS.encode())
    book.add_item(css_item)

    # Cover image
    image_item = None
    img_bytes = fetch_image_bytes(recipe.get("image", ""), base_url, token)
    if img_bytes:
        ext = (recipe.get("image", "").rsplit(".", 1)[-1].split("?")[0].lower()) or "jpg"
        mt = {"jpg": "image/jpeg", "jpeg": "image/jpeg",
              "png": "image/png", "gif": "image/gif"}.get(ext, "image/jpeg")
        image_item = epub.EpubItem(uid="img", file_name=f"images/cover.{ext}",
                                   media_type=mt, content=img_bytes)
        book.add_item(image_item)
        book.set_cover(f"images/cover.{ext}", img_bytes)

    def xhtml(body_content, title=""):
        return (
                "<?xml version='1.0' encoding='utf-8'?>"
                "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" "
                "\"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">"
                "<html xmlns=\"http://www.w3.org/1999/xhtml\">"
                f"<head><title>{html_lib.escape(title or name)}</title>"
                "<link rel='stylesheet' type='text/css' href='../styles/k.css'/>"
                "</head><body>" + body_content + "</body></html>"
        ).encode()

    # Cover page
    cover_ch = epub.EpubHtml(title="Cover", file_name="cover.xhtml", lang="en")
    cover_ch.content = xhtml(
        f"<div class='cover'><h1>{html_lib.escape(name)}</h1>"
        "<p class='sub'>Exported from Tandoor</p></div>", "Cover"
    )
    cover_ch.add_item(css_item)
    book.add_item(cover_ch)

    # Recipe page
    steps = recipe.get("steps", [])
    meta_parts = []
    if recipe.get("servings"):
        meta_parts.append(f"Servings: {recipe['servings']}"
                          + (f" {recipe.get('servings_text','')}" if recipe.get("servings_text") else ""))
    if recipe.get("working_time"):
        meta_parts.append(f"Prep: {recipe['working_time']} min")
    if recipe.get("waiting_time"):
        meta_parts.append(f"Cook: {recipe['waiting_time']} min")
    meta_html = (f"<p class='meta'>{'&nbsp;·&nbsp;'.join(meta_parts)}</p>" if meta_parts else "")

    desc = (recipe.get("description") or "").strip()
    desc_html = f"<div class='description'>{html_lib.escape(desc)}</div>" if desc else ""
    img_html = (f"<div style='text-align:center;margin-bottom:1em;'>"
                f"<img src='../images/{image_item.file_name.split('/')[-1]}' "
                f"alt='{html_lib.escape(name)}' style='max-width:90%;'/></div>"
                if image_item else "")

    recipe_ch = epub.EpubHtml(title=name, file_name="recipe.xhtml", lang="en")
    recipe_ch.content = xhtml(
        f"<h1>{html_lib.escape(name)}</h1>{meta_html}{img_html}{desc_html}"
        + _ingredients_html(steps) + _steps_html(steps)
    )
    recipe_ch.add_item(css_item)
    if image_item: recipe_ch.add_item(image_item)
    book.add_item(recipe_ch)

    book.toc = (epub.Link("cover.xhtml", "Cover", "cover"),
                epub.Link("recipe.xhtml", name, "recipe"))
    book.add_item(epub.EpubNcx())
    book.add_item(epub.EpubNav())
    book.spine = ["nav", cover_ch, recipe_ch]

    buf = io.BytesIO()
    with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
        epub.write_epub(tmp.name, book)
        with open(tmp.name, "rb") as f:
            data = f.read()
        Path(tmp.name).unlink(missing_ok=True)
    return data


def epub_to_mobi(epub_bytes: bytes, log) -> bytes:
    convert = shutil.which("ebook-convert")
    if not convert:
        raise RuntimeError(
            "Calibre not found. Install from https://calibre-ebook.com/ "
            "and ensure ebook-convert is on your PATH."
        )
    with tempfile.TemporaryDirectory() as tmp:
        epub_path = Path(tmp) / "recipe.epub"
        mobi_path = Path(tmp) / "recipe.mobi"
        epub_path.write_bytes(epub_bytes)
        log("Running ebook-convert …")
        result = subprocess.run(
            [convert, str(epub_path), str(mobi_path),
             "--output-profile", "kindle",
             "--mobi-file-type", "old"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"ebook-convert failed:\n{result.stderr[-500:]}")
        return mobi_path.read_bytes()


# ── SSH upload ────────────────────────────────────────────────────────────────

def upload_via_ssh(mobi_bytes: bytes, filename: str, cfg: dict, log) -> str:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    connect_kwargs = dict(
        hostname=cfg["KINDLE_HOST"],
        port=cfg["KINDLE_PORT"],
        username=cfg["KINDLE_USER"],
        timeout=15,
    )
    if cfg["KINDLE_KEY_PATH"]:
        connect_kwargs["key_filename"] = cfg["KINDLE_KEY_PATH"]
        log(f"Connecting to {cfg['KINDLE_USER']}@{cfg['KINDLE_HOST']} using SSH key …")
    else:
        connect_kwargs["password"] = cfg["KINDLE_PASSWORD"]
        log(f"Connecting to {cfg['KINDLE_USER']}@{cfg['KINDLE_HOST']} with password …")

    ssh.connect(**connect_kwargs)
    sftp = ssh.open_sftp()

    remote_dir = cfg["KINDLE_DOCS_PATH"].rstrip("/")
    remote_path = f"{remote_dir}/{filename}"

    log(f"Uploading {filename} ({len(mobi_bytes)/1024:.1f} KB) → {remote_path}")
    with sftp.open(remote_path, "wb") as f:
        f.write(mobi_bytes)

    # Trigger Kindle library refresh
    log("Triggering KUAL library update …")
    try:
        ssh.exec_command("dbus-send --system /default com.lab126.powerd.resuming int32:1 2>/dev/null || true")
    except Exception:
        pass

    sftp.close()
    ssh.close()
    return remote_path


# ── SSE job runner ────────────────────────────────────────────────────────────

def run_job(recipe_id: int, cfg: dict, q: queue.Queue):
    def log(msg: str):
        q.put({"type": "log", "msg": msg})

    try:
        log(f"Connecting to Tandoor at {cfg['TANDOOR_URL']} …")
        recipe = tandoor_get(f"/api/recipe/{recipe_id}/",
                             cfg["TANDOOR_URL"], cfg["TANDOOR_TOKEN"])
        name = recipe.get("name", f"recipe-{recipe_id}")
        log(f"Got recipe: {name}")

        log("Building EPUB …")
        epub_bytes = build_epub(recipe, cfg["TANDOOR_URL"], cfg["TANDOOR_TOKEN"])
        log(f"EPUB built ({len(epub_bytes)//1024} KB)")

        log("Converting to MOBI …")
        mobi_bytes = epub_to_mobi(epub_bytes, log)
        log(f"MOBI ready ({len(mobi_bytes)//1024} KB)")

        safe_name = re.sub(r"[^\w\s-]", "", name).strip().replace(" ", "_")
        filename = f"{safe_name}.mobi"

        log(f"Uploading to Kindle via SSH …")
        remote_path = upload_via_ssh(mobi_bytes, filename, cfg, log)

        q.put({"type": "done", "msg": f"✓ Sent to Kindle: {remote_path}",
               "recipe_name": name, "filename": filename})

    except Exception as e:
        q.put({"type": "error", "msg": str(e)})


# ── Routes ─────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    recipes = []
    error = None
    if CFG.get("TANDOOR_URL") and CFG.get("TANDOOR_TOKEN"):
        try:
            recipes = list_recipes(CFG["TANDOOR_URL"], CFG["TANDOOR_TOKEN"])
        except Exception as e:
            error = f"Could not fetch recipes from Tandoor: {e}"
    else:
        error = "Tandoor URL or token not configured."
    return render_template(
        "index.html",
        recipes=recipes,
        error=error,
        tandoor_url=CFG.get("TANDOOR_URL", ""),
    )


@app.route("/config", methods=["POST"])
def save_config():
    data = request.get_json()
    for key in CFG:
        if key in data:
            CFG[key] = data[key]
            if key == "KINDLE_PORT":
                CFG[key] = int(data[key] or 22)
    return jsonify({"ok": True})


@app.route("/send", methods=["GET"])
def send():
    recipe_id = request.args.get("recipe_id", "").strip()
    if not recipe_id or not recipe_id.isdigit():
        return Response("data: {\"type\":\"error\",\"msg\":\"Invalid recipe ID\"}\n\n",
                        mimetype="text/event-stream")

    # Snapshot current config
    cfg = dict(CFG)

    q: queue.Queue = queue.Queue()
    t = threading.Thread(target=run_job, args=(int(recipe_id), cfg, q), daemon=True)
    t.start()

    def generate():
        while True:
            try:
                msg = q.get(timeout=60)
                yield f"data: {json.dumps(msg)}\n\n"
                if msg["type"] in ("done", "error"):
                    break
            except queue.Empty:
                yield "data: {\"type\":\"ping\"}\n\n"

    return Response(stream_with_context(generate()), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.route("/preview")
def preview():
    """Fetch recipe metadata for preview without sending."""
    recipe_id = request.args.get("recipe_id", "").strip()
    if not recipe_id or not recipe_id.isdigit():
        return jsonify({"error": "Invalid recipe ID"}), 400
    try:
        recipe = tandoor_get(f"/api/recipe/{int(recipe_id)}/",
                             CFG["TANDOOR_URL"], CFG["TANDOOR_TOKEN"])
        return jsonify({
            "name": recipe.get("name"),
            "description": recipe.get("description"),
            "servings": recipe.get("servings"),
            "working_time": recipe.get("working_time"),
            "waiting_time": recipe.get("waiting_time"),
            "image": recipe.get("image"),
            "step_count": len(recipe.get("steps", [])),
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=CFG["PORT"], debug=False)