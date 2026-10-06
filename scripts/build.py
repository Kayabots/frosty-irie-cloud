#!/usr/bin/env python3
"""Assemble deployable bundles.

  web   -> dist/web     static site + menu.json + generated config.js
  aws   -> dist/aws     handler.py + pricing.py + menu.json   (Terraform zips this)
  azure -> dist/azure   function_app.py + pricing.py + menu.json + host.json + requirements.txt

Usage:
  python scripts/build_web.py web --api https://abc.execute-api.us-east-1.amazonaws.com \
                                  --api https://fi-func-dr.azurewebsites.net/api --served-by "AWS us-east-1"
  python scripts/build_web.py aws
  python scripts/build_web.py azure
"""
import argparse
import json
import re
import shutil
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
MENU = ROOT / "app" / "menu" / "menu.json"
DIST = ROOT / "dist"


def fresh(target: Path) -> Path:
    shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True)
    return target


def build_web(apis: list[str], served_by: str) -> Path:
    out = DIST / "web"
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(ROOT / "app" / "web", out)
    shutil.copy(MENU, out / "menu.json")
    for a in apis:
        if urlparse(a).scheme != "https":
            raise SystemExit(f"API URL must be https: {a}")
    cfg = {"apis": apis, "servedBy": served_by, "whatsapp": json.loads(MENU.read_text())["store"]["whatsapp"],
           "requestTimeoutMs": 8000}
    (out / "config.js").write_text(f"window.FROSTY_CONFIG = {json.dumps(cfg, indent=2)};\n", encoding="utf-8")
    # Pin CSP connect-src to the exact API origins instead of the wildcard dev defaults.
    if apis:
        origins = " ".join(sorted({f"https://{urlparse(a).netloc}" for a in apis}))
        idx = out / "index.html"
        html = re.sub(r"connect-src [^;]+;", f"connect-src 'self' {origins};", idx.read_text(encoding="utf-8"))
        idx.write_text(html, encoding="utf-8")
    return out


def build_api(cloud: str) -> Path:
    out = fresh(DIST / cloud)
    shutil.copy(ROOT / "app" / "api" / "common" / "pricing.py", out)
    shutil.copy(MENU, out)
    for f in (ROOT / "app" / "api" / cloud).iterdir():
        if f.is_file():
            shutil.copy(f, out)
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("target", choices=["web", "aws", "azure"])
    p.add_argument("--api", action="append", default=[], help="API base URL, in failover order")
    p.add_argument("--served-by", default="the cloud")
    a = p.parse_args()
    out = build_web(a.api, a.served_by) if a.target == "web" else build_api(a.target)
    print(out)


if __name__ == "__main__":
    main()
