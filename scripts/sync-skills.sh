#!/usr/bin/env bash
# Synchronise skills/ et le manifeste du plugin depuis forcedotcom/sf-skills.
#
# Usage:
#   ./scripts/sync-skills.sh                 # sync depuis main
#   ./scripts/sync-skills.sh --latest-tag    # sync depuis le dernier tag semver
#   ./scripts/sync-skills.sh --ref 1.9.0     # sync depuis un tag/branche precis
#   ./scripts/sync-skills.sh --list-tags     # liste les tags d'amont et quitte
#   ./scripts/sync-skills.sh --dry-run       # simule sans rien modifier
#   ./scripts/sync-skills.sh --url <git-url> # override URL amont
#
# Tout argument positionnel restant sera traite comme l'URL amont (pour
# retro-compatibilite : `./sync-skills.sh https://... 1.9.0`).

set -euo pipefail

UPSTREAM_URL="https://github.com/forcedotcom/sf-skills.git"
UPSTREAM_REF="main"
LIST_TAGS=0
LATEST_TAG=0
DRY_RUN=0

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-tags)   LIST_TAGS=1; shift ;;
    --latest-tag)  LATEST_TAG=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --ref)         UPSTREAM_REF="$2"; shift 2 ;;
    --url)         UPSTREAM_URL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    --)            shift; POSITIONAL+=("$@"); break ;;
    -*)
      echo "Option inconnue : $1" >&2; exit 2 ;;
    *)             POSITIONAL+=("$1"); shift ;;
  esac
done

# Retro-compat positionnelle : URL puis REF
if [[ ${#POSITIONAL[@]} -ge 1 ]]; then UPSTREAM_URL="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then UPSTREAM_REF="${POSITIONAL[1]}"; fi

# Trie semver decroissant ; non-semver finit en bas (via sort -V inverse)
list_tags_sorted() {
  git ls-remote --tags --refs "$UPSTREAM_URL" \
    | awk '{ sub("refs/tags/", "", $2); printf "%s\t%s\n", $2, $1 }' \
    | sort -t$'\t' -k1,1 -rV
}

if [[ "$LIST_TAGS" -eq 1 ]]; then
  echo "Tags disponibles sur $UPSTREAM_URL (recents en premier) :"
  list_tags_sorted | awk -F'\t' '{ printf "  %-15s %s\n", $1, $2 }'
  exit 0
fi

if [[ "$LATEST_TAG" -eq 1 ]]; then
  UPSTREAM_REF="$(list_tags_sorted | head -1 | cut -f1)"
  if [[ -z "$UPSTREAM_REF" ]]; then
    echo "ERREUR : aucun tag trouve sur $UPSTREAM_URL" >&2
    exit 1
  fi
  echo "Dernier tag detecte : $UPSTREAM_REF"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_dir="$repo_root/skills"
plugin_json="$repo_root/.claude-plugin/plugin.json"
temp_dir="$(mktemp -d -t sf-skills-upstream-XXXXXX)"

cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

echo "Repo plugin       : $repo_root"
echo "Source amont      : $UPSTREAM_URL ($UPSTREAM_REF)"
echo "Clone temporaire  : $temp_dir"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Mode              : DRY-RUN (aucune modification ne sera appliquee)"
fi
echo

echo "Clonage de $UPSTREAM_URL..."
git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$temp_dir"

[[ -d "$temp_dir/skills" ]]       || { echo "ERREUR : skills/ introuvable dans le clone amont" >&2; exit 1; }
[[ -f "$temp_dir/package.json" ]] || { echo "ERREUR : package.json introuvable dans le clone amont" >&2; exit 1; }
[[ -f "$plugin_json" ]]           || { echo "ERREUR : $plugin_json introuvable" >&2; exit 1; }

# Lit version + description d'amont depuis package.json (sans dependance jq)
upstream_version="$(
  grep -E '"version"[[:space:]]*:' "$temp_dir/package.json" \
  | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
)"
upstream_description="$(
  grep -E '"description"[[:space:]]*:' "$temp_dir/package.json" \
  | head -1 \
  | sed -E 's/.*"description"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/'
)"
[[ -n "$upstream_version" ]]     || { echo "ERREUR : impossible d'extraire la version depuis package.json amont" >&2; exit 1; }
[[ -n "$upstream_description" ]] || { echo "ERREUR : impossible d'extraire la description depuis package.json amont" >&2; exit 1; }

# Lit l'etat local courant pour diff
if ! grep -qE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$plugin_json"; then
  echo "ERREUR : champ \"version\" introuvable dans plugin.json" >&2; exit 1
fi
if ! grep -qE '"description"[[:space:]]*:[[:space:]]*"' "$plugin_json"; then
  echo "ERREUR : champ \"description\" introuvable dans plugin.json" >&2; exit 1
fi
current_version="$(
  grep -E '"version"[[:space:]]*:' "$plugin_json" \
  | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
)"
current_description="$(
  grep -E '"description"[[:space:]]*:' "$plugin_json" \
  | head -1 \
  | sed -E 's/.*"description"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/'
)"

upstream_sha="$(git -C "$temp_dir" rev-parse HEAD)"

# Listes de skills (local vs amont) pour diff
list_local()    { [[ -d "$skills_dir" ]] && find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true; }
list_upstream() { find "$temp_dir/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }
local_skills="$(list_local)"
upstream_skills_list="$(list_upstream)"
local_count="$(printf '%s\n' "$local_skills"    | grep -c . || true)"
upstream_count="$(printf '%s\n' "$upstream_skills_list" | grep -c . || true)"
added="$(  comm -13 <(printf '%s\n' "$local_skills") <(printf '%s\n' "$upstream_skills_list"))"
removed="$(comm -23 <(printf '%s\n' "$local_skills") <(printf '%s\n' "$upstream_skills_list"))"

echo
echo "Changements detectes :"
echo "  Ref amont           : $UPSTREAM_REF (${upstream_sha:0:7})"
echo "  version             : $current_version -> $upstream_version"
echo "  description         : $current_description -> $upstream_description"
echo "  skills (local|amont): $local_count | $upstream_count"
if [[ -n "$added" ]];   then echo "  + ajoutes  ($(printf '%s\n' "$added"   | grep -c .)) : $(printf '%s\n' "$added"   | paste -sd', ' -)"; fi
if [[ -n "$removed" ]]; then echo "  - retires  ($(printf '%s\n' "$removed" | grep -c .)) : $(printf '%s\n' "$removed" | paste -sd', ' -)"; fi
if [[ -z "$added" && -z "$removed" ]]; then
  echo "  (aucun skill ajoute ou retire ; le contenu individuel peut neanmoins differer)"
fi
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY-RUN : aucune modification appliquee."
  echo "Pour appliquer, relance sans --dry-run."
  exit 0
fi

# ---- Application reelle ----
echo "Suppression de l'ancien contenu de skills/..."
mkdir -p "$skills_dir"
find "$skills_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "Copie de upstream/skills/ vers skills/..."
cp -R "$temp_dir/skills/." "$skills_dir/"

echo "Mise a jour de version et description dans plugin.json..."
escaped_version="$(printf '%s' "$upstream_version" | sed -E 's/[\/&\\]/\\&/g')"
escaped_description="$(printf '%s' "$upstream_description" | sed -E 's/[\/&\\]/\\&/g')"

if sed --version >/dev/null 2>&1; then
  sed_inplace=(sed -i -E)
else
  sed_inplace=(sed -i '' -E)
fi
"${sed_inplace[@]}" "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\\1${escaped_version}\\2/" "$plugin_json"
"${sed_inplace[@]}" "s/(\"description\"[[:space:]]*:[[:space:]]*\")([^\"\\\\]|\\\\.)*(\")/\\1${escaped_description}\\3/" "$plugin_json"

count="$(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

echo
echo "Sync terminee."
echo "  Skills synchronises : $count"
echo
echo "Pense a committer les changements :"
echo "  git add skills/ .claude-plugin/plugin.json"
echo "  git commit -m \"chore: sync skills v${upstream_version} from forcedotcom/sf-skills@${upstream_sha:0:7}\""
