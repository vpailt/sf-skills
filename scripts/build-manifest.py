"""Genere un manifest.json (spec Agent Skills) depuis le contenu de skills/.

Variables d'environnement :
  SKILLS_DIR        chemin du dossier skills/
  MANIFEST_PATH     chemin du fichier manifest.json en sortie
  UPSTREAM_BRANCH   ref amont (main, 1.9.0, ...)
  UPSTREAM_SHA      SHA exact du commit amont synchronise
  UPSTREAM_VERSION  version semver du package.json amont (1.8.0, 1.9.0, ...)
"""

import json
import os
import re
import datetime
import pathlib

skills_dir = pathlib.Path(os.environ["SKILLS_DIR"])
manifest_path = pathlib.Path(os.environ["MANIFEST_PATH"])
branch = os.environ.get("UPSTREAM_BRANCH", "main")
sha = os.environ.get("UPSTREAM_SHA", "")
upstream_version = os.environ.get("UPSTREAM_VERSION", "")

FRONT_RE = re.compile(r"\A---\s*\r?\n(.*?)\r?\n---", re.DOTALL)


def parse_frontmatter(text):
    m = FRONT_RE.search(text)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        km = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$", line)
        if not km:
            continue
        key = km.group(1)
        val = km.group(2)
        if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
            val = val[1:-1].replace(r'\"', '"').replace(r"\\", "\\")
        elif len(val) >= 2 and val[0] == "'" and val[-1] == "'":
            val = val[1:-1].replace("''", "'")
        out[key] = val
    return out


skills = []
for d in sorted(p for p in skills_dir.iterdir() if p.is_dir()):
    skill_md = d / "SKILL.md"
    if not skill_md.exists():
        continue
    fm = parse_frontmatter(skill_md.read_text(encoding="utf-8"))
    files = sorted(
        str(p.relative_to(d)).replace("\\", "/")
        for p in d.rglob("*")
        if p.is_file()
    )
    skills.append({
        "name": fm.get("name", d.name),
        "path": f"skills/{d.name}/SKILL.md",
        "folderPath": f"skills/{d.name}",
        "files": files,
        "description": fm.get("description", ""),
    })

now = datetime.datetime.now(datetime.timezone.utc)
manifest = {
    "version": upstream_version or "0.0.0",
    "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z",
    "branch": branch,
    "upstreamSha": sha,
    "skills": skills,
}

manifest_path.write_text(
    json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
print(f"manifest.json ecrit ({len(skills)} skills) -> {manifest_path}")
