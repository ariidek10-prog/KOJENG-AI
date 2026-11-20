#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KOJENG AI v2.0 - Multi-Agent Coding Squad (Gemini + OpenRouter + Groq)
Jalan di Termux (tanpa Termux:API pun bisa). Dependensi: requests
  pkg install python -y && pip install requests
  python kojeng_ai.py
"""
import os, sys, json, time, re, ast, shutil, subprocess, threading, itertools
import tempfile, math, importlib.util

try:
    import readline  # panah atas/bawah = riwayat input
except Exception:
    readline = None
try:
    import requests
except ImportError:
    sys.exit("Install dulu: pip install requests")

VERSION = "2.0"
CFG_PATH = os.path.expanduser("~/.kojeng_ai.json")
OLD_CFG_PATH = os.path.expanduser("~/.cyberai.json")
OUT_DIR = os.path.expanduser("~/cyberai_out")
G, C, Y, R, M = "\033[92m", "\033[96m", "\033[93m", "\033[91m", "\033[95m"
D, B, X = "\033[2m", "\033[1m", "\033[0m"

DEFAULT = {
    "keys": {"gemini": "", "openrouter": "", "groq": ""},
    "models": {
        "gemini": "gemini-2.5-flash",
        "openrouter": "meta-llama/llama-3.3-70b-instruct:free",
        "groq": "llama-3.3-70b-versatile",
    },
    "speed": 0.006,     # detik per huruf (efek ngetik); 0 = instan
    "rounds": 3,        # maksimal putaran review -> bug hunt -> fix
    "max_tokens": 8000, # batas panjang balasan AI
    "autorun": None,    # izin menjalankan kode hasil AI untuk tes (None = tanya)
    "order": {},        # override urutan provider per agen
}

SAFE = ("Fokus pada software legal, defensif, edukasi, dan tooling developer. "
        "Tolak membuat malware, ransomware, atau exploit untuk menyerang pihak lain. ")

ROLES = {
    "ARCHITECT": (["gemini", "openrouter", "groq"],
        SAFE + "Kamu ARSITEK. Buat rencana desain ringkas: tujuan, struktur file/modul, "
        "alur data, edge case, dan langkah implementasi. Jangan tulis kode penuh. Jawab Bahasa Indonesia."),
    "CODER": (["groq", "gemini", "openrouter"],
        SAFE + "Kamu CODER senior. Tulis kode LENGKAP, bersih, siap jalan di Termux/Android "
        "(Python 3 bila tidak diminta lain). Tanpa placeholder '...'. Beri kode di blok ```bahasa. "
        "Penjelasan singkat dalam Bahasa Indonesia."),
    "REVIEWER": (["openrouter", "gemini", "groq"],
        SAFE + "Kamu REVIEWER ketat. Periksa logika, error handling, keamanan, performa, "
        "kompatibilitas Termux. Beri daftar masalah bernomor (atau tulis 'Tidak ada masalah'). "
        "Baris TERAKHIR wajib: 'VERDICT: PASS' atau 'VERDICT: FAIL'. Jawab Bahasa Indonesia."),
    "BUGHUNTER": (["gemini", "groq", "openrouter"],
        SAFE + "Kamu BUG HUNTER. Simulasikan eksekusi kode di kepala: cari bug runtime, input aneh, "
        "race condition, resource leak, import yang hilang. Daftar bug bernomor + cara reproduksi "
        "singkat (atau 'Tidak ada bug'). Baris TERAKHIR wajib: 'VERDICT: PASS' atau 'VERDICT: FAIL'. "
        "Jawab Bahasa Indonesia."),
    "FIXER": (["groq", "openrouter", "gemini"],
        SAFE + "Kamu FIXER. Perbaiki SEMUA masalah dari cek lokal, review, dan bug report. Keluarkan "
        "kode FINAL lengkap (bukan diff, tanpa '...') dalam blok ```bahasa, lalu daftar singkat "
        "perubahan dalam Bahasa Indonesia."),
    "CHAT": (["gemini", "groq", "openrouter"],
        SAFE + "Kamu asisten coding yang handal dan ringkas. Jawab Bahasa Indonesia."),
}
COLORS = {"ARCHITECT": C, "CODER": G, "REVIEWER": Y, "BUGHUNTER": R, "FIXER": M, "CHAT": G}


# ------------------------------------------------------------------ config
def load_cfg():
    cfg = json.loads(json.dumps(DEFAULT))
    for path in (OLD_CFG_PATH, CFG_PATH):  # file baru menimpa yang lama
        try:
            with open(path) as f:
                saved = json.load(f)
        except Exception:
            continue
        for k in ("keys", "models"):
            if isinstance(saved.get(k), dict):
                cfg[k].update({a: b for a, b in saved[k].items() if a in cfg[k]})
        for k in ("speed", "rounds", "max_tokens", "autorun", "order"):
            if k in saved:
                cfg[k] = saved[k]
    env = {"gemini": "GEMINI_API_KEY", "openrouter": "OPENROUTER_API_KEY", "groq": "GROQ_API_KEY"}
    for p, e in env.items():
        if os.environ.get(e):
            cfg["keys"][p] = os.environ[e]
    for p in cfg["keys"]:
        cfg["keys"][p] = (cfg["keys"][p] or "").strip()
    return cfg


def save_cfg(cfg):
    try:
        with open(CFG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
        os.chmod(CFG_PATH, 0o600)
    except Exception as e:
        print(f"{Y}! gagal menyimpan config: {e}{X}")


CFG = load_cfg()
DEAD = {}    # provider yang key-nya ditolak (dilewati sampai /keys atau /test)
NOTES = []   # catatan fallback/continue untuk ditampilkan setelah spinner
LOG = []     # seluruh log sesi
STAMP = time.strftime("%Y%m%d_%H%M%S")


class AuthError(RuntimeError):
    pass


# ------------------------------------------------------------------ http / providers
def post(url, headers, payload, tries=3):
    last = "gagal"
    for t in range(tries):
        try:
            r = requests.post(url, headers=headers, json=payload, timeout=(10, 180))
        except requests.RequestException as e:
            last = f"jaringan: {str(e)[:80]}"
            time.sleep(2 * (t + 1))
            continue
        if r.status_code == 200:
            try:
                data = r.json()
            except ValueError:
                last = "respon bukan JSON"
                time.sleep(2)
                continue
            if (isinstance(data, dict) and data.get("error")
                    and not data.get("choices") and not data.get("candidates")):
                last = f"API: {str(data['error'])[:120]}"
                time.sleep(2)
                continue
            return data
        if r.status_code in (401, 403):
            raise AuthError(f"HTTP {r.status_code}: {r.text[:100]}")
        if r.status_code in (408, 429, 500, 502, 503, 504):
            ra = r.headers.get("Retry-After", "")
            try:
                wait = min(float(ra), 20)
            except ValueError:
                wait = 2 * (t + 1)
            last = f"HTTP {r.status_code}"
            time.sleep(wait)
            continue
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:140]}")
    raise RuntimeError(last)


def call_gemini(model, key, system, messages):
    contents = [{"role": "model" if m["role"] == "assistant" else "user",
                 "parts": [{"text": m["content"]}]} for m in messages]
    data = post(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        {"x-goog-api-key": key, "Content-Type": "application/json"},
        {"system_instruction": {"parts": [{"text": system}]}, "contents": contents,
         "generationConfig": {"maxOutputTokens": int(CFG["max_tokens"])}})
    cands = data.get("candidates") or []
    if not cands:
        why = (data.get("promptFeedback") or {}).get("blockReason", "kosong")
        raise RuntimeError(f"Gemini tanpa jawaban ({why})")
    cand = cands[0]
    parts = (cand.get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in parts)
    fin = cand.get("finishReason")
    if not text.strip():
        raise RuntimeError(f"Gemini balasan kosong ({fin})")
    return text, fin == "MAX_TOKENS"


def call_openai_style(url, key, model, system, messages, extra=None, cap=None):
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    headers.update(extra or {})
    mt = min(int(CFG["max_tokens"]), cap) if cap else int(CFG["max_tokens"])
    data = post(url, headers, {"model": model, "max_tokens": mt,
                               "messages": [{"role": "system", "content": system}] + messages})
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("balasan tanpa choices")
    ch = choices[0]
    text = (ch.get("message") or {}).get("content") or ""
    if not text.strip():
        raise RuntimeError("balasan kosong")
    return text, ch.get("finish_reason") == "length"


def call_provider(p, system, messages):
    key, model = CFG["keys"][p], CFG["models"][p]
    if p == "gemini":
        return call_gemini(model, key, system, messages)
    if p == "groq":
        return call_openai_style("https://api.groq.com/openai/v1/chat/completions",
                                 key, model, system, messages, cap=4096)  # aman untuk limit TPM gratis
    return call_openai_style("https://openrouter.ai/api/v1/chat/completions", key, model,
                             system, messages, {"X-Title": "KOJENG AI"})


def ask(role, messages):
    """Kirim ke provider prioritas agen; otomatis fallback, auto-lanjut jika terpotong."""
    order, system = ROLES[role]
    order = CFG["order"].get(role) or order
    fails = []
    for p in order:
        if p not in CFG["keys"] or not CFG["keys"][p]:
            continue
        if p in DEAD:
            fails.append(f"{p}: nonaktif ({DEAD[p]})")
            continue
        try:
            text, trunc = call_provider(p, system, messages)
            n = 0
            while trunc and n < 2:
                n += 1
                NOTES.append(f"{p}: balasan terpotong, melanjutkan ({n}/2)")
                more, trunc = call_provider(p, system, messages + [
                    {"role": "assistant", "content": text},
                    {"role": "user", "content": "Lanjutkan PERSIS dari titik terpotong, "
                                                 "jangan mengulang bagian sebelumnya."}])
                text += more
            if text.count("```") % 2:
                text += "\n```"
            if fails:
                NOTES.append(f"fallback ke {p} ({'; '.join(fails)})")
            return text, p
        except AuthError as e:
            DEAD[p] = str(e)[:60]
            fails.append(f"{p}: key ditolak")
        except Exception as e:
            fails.append(f"{p}: {str(e)[:100]}")
    if not fails:
        raise RuntimeError("Tidak ada API key aktif. Isi lewat /keys")
    raise RuntimeError("Semua provider gagal -> " + " | ".join(fails))


# ------------------------------------------------------------------ UI
def typewrite(text, color=""):
    """Efek ngetik 1 huruf demi 1 huruf. Ctrl+C = skip. Teks panjang otomatis dipercepat."""
    out = sys.stdout
    out.write(color)
    n = len(text)
    if CFG["speed"] <= 0 or n == 0 or not out.isatty():
        out.write(text)
    else:
        delay = min(n * CFG["speed"], 10.0) / n
        step = max(1, math.ceil(0.004 / delay))
        delay *= step
        i = 0
        try:
            while i < n:
                out.write(text[i:i + step])
                out.flush()
                i += step
                time.sleep(delay)
        except KeyboardInterrupt:
            out.write(text[i:])
    out.write(X + "\n")
    out.flush()


class Spin:
    def __init__(self, label):
        self.label, self.on, self.t = label, False, None

    def __enter__(self):
        if sys.stdout.isatty():
            self.on = True
            self.t = threading.Thread(target=self.run, daemon=True)
            self.t.start()
        return self

    def run(self):
        for f in itertools.cycle("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"):
            if not self.on:
                break
            sys.stdout.write(f"\r{D}{f} {self.label}{X}   ")
            sys.stdout.flush()
            time.sleep(0.08)

    def __exit__(self, *a):
        if self.t:
            self.on = False
            self.t.join()
            sys.stdout.write("\r" + " " * (len(self.label) + 8) + "\r")
            sys.stdout.flush()


def banner():
    art = r"""
 _  __   ___       _   _____  _   _   ____ 
| |/ /  / _ \     | | | ____|| \ | | / ___|
| ' /  | | | | _  | | |  _|  |  \| || |  _ 
| . \  | |_| || |_| | | |___ | |\  || |_| |
|_|\_\  \___/  \___/ |_____||_| \_| \____|
          A I   S Q U A D
"""
    print(G + art + X)
    typewrite(f">> KOJENG AI v{VERSION} ONLINE | Gemini + OpenRouter + Groq", G)
    typewrite(">> ketik /help untuk daftar perintah", D)


def box(rows, head=("No", "Salin", "Isi")):
    data = [head] + rows
    ws = [max(len(r[i]) for r in data) + 2 for i in range(len(head))]
    ln = lambda l, m, r: l + m.join("─" * w for w in ws) + r
    cell = lambda r: "│" + "│".join(" " + r[i].ljust(ws[i] - 1) for i in range(len(head))) + "│"
    print(G + ln("┌", "┬", "┐"))
    print(B + cell(head) + X + G)
    print(ln("├", "┼", "┤"))
    for r in rows:
        print(cell(r))
    print(ln("└", "┴", "┘") + X)


def prompt_str(text):
    # \001 \002 supaya readline menghitung lebar prompt dengan benar
    return re.sub(r"(\033\[[0-9;]*m)", "\001\\1\002", text)


# ------------------------------------------------------------------ helpers
FENCE = re.compile(r"```([\w+-]*)[^\n]*\n(.*?)```", re.S)
EXT = {"python": "py", "py": "py", "bash": "sh", "sh": "sh", "javascript": "js", "js": "js",
       "json": "json", "html": "html", "c": "c", "cpp": "cpp", "java": "java", "go": "go",
       "rust": "rs", "php": "php"}
LANG_BY_EXT = {v: k for k, v in EXT.items() if k not in ("py", "sh", "js")}
LANG_BY_EXT.update({"py": "python", "sh": "bash", "js": "javascript"})


def code_blocks(text):
    return [(l.lower(), c) for l, c in FENCE.findall(text)]


def current_code(text):
    blocks = code_blocks(text)
    return "\n\n".join(f"```{l}\n{c}```" for l, c in blocks) if blocks else text


def clip_text(s, n=24000):
    if len(s) <= n:
        return s
    h = n // 2
    return s[:h] + "\n...[dipotong biar muat]...\n" + s[-h:]


def local_check(text):
    """Cek nyata di perangkat: syntax Python/JSON/Bash/JS. Return (errors, warnings)."""
    errs, warns = [], []
    blocks = code_blocks(text)
    if not blocks:
        warns.append("tidak ada blok kode ```")
    for i, (lang, code) in enumerate(blocks, 1):
        try:
            if lang in ("python", "py"):
                tree = ast.parse(code)
                std = getattr(sys, "stdlib_module_names", set())
                mods = set()
                for node in ast.walk(tree):
                    if isinstance(node, ast.Import):
                        mods |= {a.name.split(".")[0] for a in node.names}
                    elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
                        mods.add(node.module.split(".")[0])
                for m in sorted(mods):
                    if m in std:
                        continue
                    try:
                        found = importlib.util.find_spec(m)
                    except Exception:
                        found = None
                    if found is None:
                        warns.append(f"modul '{m}' belum terinstal (pip install {m})")
            elif lang == "json":
                json.loads(code)
            elif lang in ("bash", "sh") and shutil.which("bash"):
                r = subprocess.run(["bash", "-n"], input=code.encode(), capture_output=True, timeout=10)
                if r.returncode:
                    errs.append(f"blok {i} (bash): {r.stderr.decode(errors='ignore')[:150].strip()}")
            elif lang in ("javascript", "js") and shutil.which("node"):
                with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
                    f.write(code)
                try:
                    r = subprocess.run(["node", "--check", f.name], capture_output=True, timeout=15)
                    if r.returncode:
                        errs.append(f"blok {i} (js): {r.stderr.decode(errors='ignore')[:200].strip()}")
                finally:
                    os.unlink(f.name)
        except SyntaxError as e:
            errs.append(f"blok {i} (python): baris {e.lineno}: {e.msg}")
        except Exception as e:
            errs.append(f"blok {i} ({lang}): {str(e)[:150]}")
    return errs, warns


DANGER = re.compile(r"rm\s+-rf|rmtree|os\.remove|os\.unlink|os\.rmdir|os\.system|subprocess|"
                    r"shutil\.move|os\.rename|format\(\s*['\"]/|mkfs|dd\s+if=", re.I)


def can_autorun():
    if CFG["autorun"] is None:
        try:
            a = input(f"{Y}Izinkan KOJENG AI menjalankan kode hasil AI untuk TES (di folder sementara, "
                      f"timeout 8 dtk)? [y/N] > {X}").strip().lower()
        except (EOFError, KeyboardInterrupt):
            a = ""
        CFG["autorun"] = a in ("y", "ya", "yes")
        save_cfg(CFG)
    return bool(CFG["autorun"])


def runtime_check(text):
    """Jalankan blok Python terpanjang. Return (status, detail): ok | fail | skip."""
    py = [c for l, c in code_blocks(text) if l in ("python", "py")]
    if not py:
        return "skip", "tidak ada kode Python"
    code = max(py, key=len)
    if DANGER.search(code):
        return "skip", "kode mengandung operasi sensitif (hapus/subprocess), tes otomatis dilewati"
    if not can_autorun():
        return "skip", "tes jalan dimatikan (/run on untuk mengaktifkan)"
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "main.py")
        with open(path, "w") as f:
            f.write(code)
        try:
            r = subprocess.run([sys.executable, path], cwd=td, stdin=subprocess.DEVNULL,
                               capture_output=True, timeout=8,
                               env=dict(os.environ, PYTHONIOENCODING="utf-8"))
        except subprocess.TimeoutExpired:
            return "ok", "timeout 8 dtk (dianggap jalan / interaktif)"
        except Exception as e:
            return "skip", f"gagal menjalankan: {e}"
        err = r.stderr.decode(errors="ignore")
        if r.returncode == 0:
            return "ok", "exit code 0"
        if "ModuleNotFoundError" in err or "ImportError" in err:
            return "skip", "modul belum terinstal: " + err.strip().splitlines()[-1][:120]
        if "EOFError" in err or "KeyboardInterrupt" in err:
            return "ok", "butuh input interaktif (dianggap jalan)"
        return "fail", err.strip()[-800:]


def verdict_pass(t):
    m = re.findall(r"VERDICT:\W*(PASS|FAIL)", t, re.I)
    if m:
        return m[-1].upper() == "PASS"
    return not re.search(r"^\s*(\d+[.)]|[-*])\s+\S", t, re.M)  # tanpa vonis: lolos jika tak ada daftar masalah


CLIPBOARD_CMDS = [["termux-clipboard-set"], ["wl-copy"], ["xclip", "-selection", "clipboard"], ["pbcopy"]]


def clip(text):
    for cmd in CLIPBOARD_CMDS:
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=text.encode(), check=True, timeout=5)
                return True
            except Exception:  # termux-api tanpa aplikasinya bisa hang -> timeout
                continue
    return False


def save_file(text, name=None):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name or f"out_{int(time.time())}.txt")
    with open(path, "w") as f:
        f.write(text)
    return path


def autosave():
    try:
        save_file("\n".join(LOG), f"session_{STAMP}.txt")
    except Exception:
        pass


def copy_menu(answer, session):
    code = "\n\n".join(c for _, c in code_blocks(answer))
    box([("1", "Semua teks", "balasan lengkap"),
         ("2", "Kode saja", "isi blok kode"),
         ("3", "Seluruh sesi", "log semua agen"),
         ("4", "Simpan file", "~/cyberai_out"),
         ("5", "Tampil polos", "mudah di-seleksi")])
    while True:
        try:
            c = input(prompt_str(f"{G}Salin [1-5] / Enter lewati > {X}")).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not c:
            return
        if c == "4":
            blocks = code_blocks(answer)
            ext = EXT.get(blocks[0][0], "txt") if blocks else "txt"
            print(f"{G}✔ tersimpan: {save_file(code or answer, f'code_{int(time.time())}.{ext}')}{X}")
        elif c == "5":
            print("\n" + (answer or "(kosong)") + "\n")
        elif c in ("1", "2", "3"):
            pick = {"1": answer, "2": code or answer, "3": session}[c]
            if clip(pick):
                print(f"{G}✔ tersalin ke clipboard ({len(pick)} karakter){X}")
            else:
                print(f"{Y}! clipboard tidak tersedia, disimpan ke: {save_file(pick)}{X}")
        else:
            print(f"{D}pilih 1-5{X}")


# ------------------------------------------------------------------ agents
def run_agent(role, prompt):
    col = COLORS.get(role, G)
    NOTES.clear()
    try:
        with Spin(f"{role} sedang bekerja..."):
            text, prov = ask(role, [{"role": "user", "content": clip_text(prompt)}])
    finally:
        for n in NOTES:
            print(f"{Y}! {n}{X}")
        NOTES.clear()
    print(f"{col}{B}┌─[{role}]{X}{D} via {prov}{X}")
    typewrite(text, col)
    LOG.append(f"===== [{role} via {prov}] =====\n{text}\n")
    return text


def verify_loop(task, result):
    """Putaran: cek lokal -> tes jalan -> review -> bug hunt -> fix, sampai lolos."""
    rounds = CFG["rounds"]
    for rd in range(1, rounds + 1):
        print(f"{D}── putaran verifikasi {rd}/{rounds} ──{X}")
        errs, warns = local_check(result)
        for w in warns:
            print(f"{Y}⚠ {w}{X}")
        problems = list(errs)
        if errs:
            print(f"{R}✘ cek syntax: {'; '.join(errs)}{X}")
        else:
            print(f"{G}✔ cek syntax lolos{X}")
            st, detail = runtime_check(result)
            tag = {"ok": f"{G}✔", "fail": f"{R}✘", "skip": f"{D}–"}[st]
            print(f"{tag} tes jalan: {detail[:300]}{X}")
            if st == "fail":
                problems.append("runtime error: " + detail)
        code = current_code(result)
        if problems:  # tidak perlu review kode yang jelas rusak: langsung fix
            review = bugs = "(dilewati: sudah ada error nyata dari cek lokal)"
        else:
            review = run_agent("REVIEWER", f"Tugas: {task}\n\nKode:\n{code}")
            bugs = run_agent("BUGHUNTER", f"Tugas: {task}\n\nKode:\n{code}")
            if verdict_pass(review) and verdict_pass(bugs):
                print(f"{G}{B}★ Cek lokal, Reviewer, dan Bug Hunter: PASS{X}")
                return result, True
        result = run_agent("FIXER",
            f"Tugas: {task}\n\nKode saat ini:\n{code}\n\nError nyata: {problems or 'tidak ada'}\n\n"
            f"Review:\n{review}\n\nBug report:\n{bugs}")
    errs, _ = local_check(result)
    st, detail = runtime_check(result) if not errs else ("skip", "")
    ok = not errs and st != "fail"
    msg = "syntax & tes jalan lolos" if ok else "MASIH ada masalah: " + "; ".join(errs + ([detail] if st == "fail" else []))
    print(f"{(G if ok else Y)}! batas putaran tercapai. Hasil akhir: {msg[:300]}{X}")
    return result, ok


def pipeline(task, prev=""):
    ctx = f"\n\nKonteks kode sebelumnya:\n{prev}" if prev else ""
    plan = run_agent("ARCHITECT", f"Tugas: {task}{ctx}")
    result = run_agent("CODER", f"Tugas: {task}{ctx}\n\nRencana arsitek:\n{plan}")
    result, _ = verify_loop(task, result)
    return result


def fix_file(path, instruction=""):
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        raise RuntimeError(f"file tidak ditemukan: {path}")
    if os.path.getsize(path) > 80000:
        raise RuntimeError("file terlalu besar (>80KB)")
    with open(path, errors="replace") as f:
        content = f.read()
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    lang = LANG_BY_EXT.get(ext, "")
    result = f"```{lang}\n{content.rstrip()}\n```"
    task = f"Cari semua bug lalu perbaiki file '{os.path.basename(path)}'. {instruction}".strip()
    final, ok = verify_loop(task, result)
    blocks = code_blocks(final)
    if blocks and blocks[0][1].strip() != content.strip():
        try:
            a = input(f"{Y}Timpa {path} dengan versi perbaikan (backup .bak dibuat)? [y/N] > {X}").strip().lower()
        except (EOFError, KeyboardInterrupt):
            a = ""
        if a in ("y", "ya", "yes"):
            shutil.copy(path, path + ".bak")
            with open(path, "w") as f:
                f.write(blocks[0][1])
            print(f"{G}✔ ditimpa. backup: {path}.bak{X}")
    elif ok:
        print(f"{G}Tidak ada yang perlu diubah.{X}")
    return final


# ------------------------------------------------------------------ commands
HELP = """Perintah:
  <teks>            squad: desain>kode>cek>review>bug>fix (ulang sampai lolos)
  /fix <file> [msg] cari bug & perbaiki file yang sudah ada
  /chat <teks>      tanya cepat 1 AI (ada memori obrolan)
  /test             tes semua key & model sekarang juga
  /keys             atur API key & model
  /agents           lihat pembagian tugas agen
  /assign R P       ubah provider utama agen (contoh: /assign CODER gemini)
  /rounds <n>       maksimal putaran verifikasi
  /speed <detik>    kecepatan ngetik (0 = instan)
  /run on|off       izin tes jalan kode otomatis
  /copy             buka menu salin lagi
  /new              reset memori
  /status           cek key & model
  /exit             keluar
Tips: Ctrl+C saat AI mengetik = lewati animasi. Akhiri baris dengan \\ untuk multi-baris."""


def mask(k):
    return (k[:4] + "…" + k[-3:]) if len(k) > 8 else ("***" if k else "")


def setup_keys():
    for p in ("gemini", "openrouter", "groq"):
        k = input(f"{p} API key [{mask(CFG['keys'][p]) or 'kosong'}] (Enter = tetap): ").strip()
        if k:
            CFG["keys"][p] = k
            DEAD.pop(p, None)
        m = input(f"  model {p} [{CFG['models'][p]}]: ").strip()
        if m:
            CFG["models"][p] = m
    save_cfg(CFG)
    print(f"{G}✔ tersimpan di {CFG_PATH}. Coba /test untuk cek koneksi.{X}")


def status():
    for p in CFG["keys"]:
        if p in DEAD:
            ok = f"{R}DITOLAK{X}"
        else:
            ok = f"{G}ON{X}" if CFG["keys"][p] else f"{R}OFF{X}"
        print(f" {p:<11} {ok}  {D}{CFG['models'][p]}{X}")
    print(f" {D}putaran={CFG['rounds']} ngetik={CFG['speed']} autorun={CFG['autorun']}{X}")


def ping_all():
    rows = []
    for p in CFG["keys"]:
        if not CFG["keys"][p]:
            rows.append((p, "OFF", "key kosong"))
            continue
        t0 = time.time()
        try:
            with Spin(f"tes {p}..."):
                text, _ = call_provider(p, "Balas hanya: OK", [{"role": "user", "content": "ping"}])
            DEAD.pop(p, None)
            rows.append((p, "OK", f"{time.time() - t0:.1f}s"))
        except AuthError:
            DEAD[p] = "key ditolak"
            rows.append((p, "GAGAL", "key ditolak"))
        except Exception as e:
            rows.append((p, "GAGAL", str(e)[:22]))
    box(rows, ("Provider", "Hasil", "Info"))


def show_agents():
    rows = []
    for role, (order, _) in ROLES.items():
        o = CFG["order"].get(role) or order
        rows.append((role, " > ".join(o)))
    box(rows, ("Agen", "Urutan provider"))


def main():
    banner()
    if not any(CFG["keys"].values()):
        print(f"{Y}Belum ada API key. Isi dulu:{X}")
        setup_keys()
    chat_hist, last_answer = [], ""
    while True:
        try:
            line = input(prompt_str(f"\n{G}{B}kojeng@ai{X}{G}:~$ {X}")).strip()
            while line.endswith("\\"):
                line = line[:-1] + "\n" + input(prompt_str(f"{D}... {X}")).strip()
        except EOFError:
            print()
            break
        except KeyboardInterrupt:
            print(f"\n{D}(Ctrl+C lagi / ketik /exit untuk keluar){X}")
            try:
                time.sleep(0.8)
            except KeyboardInterrupt:
                break
            continue
        if not line:
            continue
        try:
            cmd, _, arg = line.partition(" ")
            arg = arg.strip()
            if cmd in ("/exit", "/quit"):
                break
            elif cmd == "/help":
                print(HELP)
            elif cmd == "/keys":
                setup_keys()
            elif cmd == "/status":
                status()
            elif cmd == "/test":
                ping_all()
            elif cmd == "/agents":
                show_agents()
            elif cmd == "/assign":
                parts = arg.split()
                if len(parts) != 2 or parts[0].upper() not in ROLES or parts[1].lower() not in CFG["keys"]:
                    print(f"{Y}format: /assign CODER gemini  (agen: {', '.join(ROLES)}){X}")
                else:
                    role, prov = parts[0].upper(), parts[1].lower()
                    base = CFG["order"].get(role) or ROLES[role][0]
                    CFG["order"][role] = [prov] + [x for x in base if x != prov]
                    save_cfg(CFG)
                    print(f"{G}✔ {role}: {' > '.join(CFG['order'][role])}{X}")
            elif cmd == "/new":
                chat_hist, last_answer = [], ""
                LOG.clear()
                print(f"{G}✔ memori direset{X}")
            elif cmd == "/rounds":
                CFG["rounds"] = max(1, min(10, int(arg)))
                save_cfg(CFG)
                print(f"{G}✔ putaran maksimal: {CFG['rounds']}{X}")
            elif cmd == "/speed":
                CFG["speed"] = max(0.0, float(arg))
                save_cfg(CFG)
                print(f"{G}✔ kecepatan ngetik: {CFG['speed']} dtk/huruf{X}")
            elif cmd == "/run":
                if arg.lower() not in ("on", "off"):
                    print(f"{Y}format: /run on | /run off{X}")
                else:
                    CFG["autorun"] = arg.lower() == "on"
                    save_cfg(CFG)
                    print(f"{G}✔ tes jalan: {arg.lower()}{X}")
            elif cmd == "/copy":
                copy_menu(last_answer, "\n".join(LOG))
            elif cmd == "/fix":
                if not arg:
                    print(f"{Y}format: /fix namafile.py [instruksi tambahan]{X}")
                else:
                    path, _, extra = arg.partition(" ")
                    last_answer = fix_file(path, extra.strip())
                    autosave()
                    copy_menu(last_answer, "\n".join(LOG))
            elif cmd == "/chat":
                if not arg:
                    print(f"{Y}format: /chat pertanyaan{X}")
                    continue
                chat_hist.append({"role": "user", "content": arg})
                try:
                    with Spin("berpikir..."):
                        text, prov = ask("CHAT", chat_hist[-20:])
                except BaseException:
                    chat_hist.pop()  # jangan tinggalkan pesan user menggantung
                    raise
                chat_hist.append({"role": "assistant", "content": text})
                print(f"{G}{B}┌─[AI]{X}{D} via {prov}{X}")
                typewrite(text, G)
                last_answer = text
                LOG.append(f"===== [CHAT via {prov}] =====\n{text}\n")
                autosave()
                copy_menu(last_answer, "\n".join(LOG))
            elif cmd.startswith("/"):
                print(f"{Y}perintah tidak dikenal. Ketik /help{X}")
            else:
                last_answer = pipeline(line, current_code(last_answer) if last_answer else "")
                print(f"\n{G}{B}══ HASIL AKHIR ══{X}")
                autosave()
                copy_menu(last_answer, "\n".join(LOG))
        except KeyboardInterrupt:
            print(f"\n{Y}dibatalkan{X}")
        except ValueError:
            print(f"{Y}argumen tidak valid. Ketik /help{X}")
        except Exception as e:
            print(f"{R}✘ {e}{X}")
    autosave()
    print(f"{D}bye. sesi tersimpan di {OUT_DIR}/session_{STAMP}.txt{X}")


if __name__ == "__main__":
    main()
