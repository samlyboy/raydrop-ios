#!/usr/bin/env python3
# wait_raydrop_ipa.py — 等 samlyboy/raydrop-ios 指定 commit 的 Actions run 完成，并下载 raydrop-ipa artifact 解出 IPA
import sys, os, time, json, zipfile, urllib.request

TOK_FILE = os.path.expanduser("~/.workbuddy/tokens/github_pat.txt")
REPO = "samlyboy/raydrop-ios"
OUT_DIR = os.path.dirname(os.path.abspath(__file__)) + "/dist"

def api(url):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + open(TOK_FILE).read().strip(),
                                               "Accept": "application/vnd.github+json",
                                               "User-Agent": "raydrop-build"})
    return json.load(urllib.request.urlopen(req, timeout=60))

def download(url, dest):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + open(TOK_FILE).read().strip(),
                                               "User-Agent": "raydrop-build"})
    with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk: break
            f.write(chunk)

def main(sha):
    deadline = time.time() + 40 * 60
    run_id = None
    while time.time() < deadline:
        runs = api(f"https://api.github.com/repos/{REPO}/actions/runs?head_sha={sha}&per_page=5")
        if runs.get("workflow_runs"):
            run = runs["workflow_runs"][0]
            run_id = run["id"]
            if run["status"] == "completed":
                if run["conclusion"] != "success":
                    print("BUILD_FAILED:", run["conclusion"]); return 2
                break
            print(f"run {run_id}: {run['status']}")
        else:
            print("waiting for run to appear...")
        time.sleep(20)
    if not run_id:
        print("TIMEOUT_NO_RUN"); return 3
    arts = api(f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/artifacts")
    art = next(a for a in arts["artifacts"] if "ipa" in a["name"].lower())
    os.makedirs(OUT_DIR, exist_ok=True)
    zpath = os.path.join(OUT_DIR, art["name"] + ".zip")
    print("downloading artifact", art["name"])
    # ⚠️ 302 跳到 objects 下载时不能带 Authorization，urllib 会自动跟随并去掉头？不会——需手动处理
    try:
        download(art["archive_download_url"], zpath)
    except Exception as e:
        print("direct download failed:", e)
        import subprocess
        subprocess.run(["curl", "-sL", "-o", zpath, "--max-time", "600",
                        "-H", "Authorization: Bearer " + open(TOK_FILE).read().strip(),
                        art["archive_download_url"]], check=True)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(OUT_DIR)
    ipas = [f for f in os.listdir(OUT_DIR) if f.endswith(".ipa")]
    for f in list(ipas):  # 把 IPA 移到 dist 根，统一命名
        src = os.path.join(OUT_DIR, f)
        dst = os.path.join(OUT_DIR, "raydrop-v20.ipa")
        if src != dst: os.replace(src, dst)
    print("IPA_READY:", os.path.join(OUT_DIR, "raydrop-v20.ipa"))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
