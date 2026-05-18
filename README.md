# sf-skills — Claude Code plugin

Plugin [Claude Code](https://claude.com/claude-code) qui expose les **57 skills Salesforce officiels** maintenus dans [`forcedotcom/sf-skills`](https://github.com/forcedotcom/sf-skills).

## Structure

```
sf-skills/
├── .claude-plugin/
│   └── plugin.json         # manifeste du plugin
├── skills/                 # skills vendores depuis forcedotcom/sf-skills/skills/
├── scripts/
│   ├── sync-skills.ps1     # script de sync (Windows)
│   └── sync-skills.sh      # script de sync (Linux/macOS)
├── README.md
└── .gitignore
```

## Installation (côté utilisateur)

En local pour test :

```bash
claude --plugin-dir ./sf-skills
```

Via un marketplace pointant sur ce repo :

```text
/plugin marketplace add <ton-marketplace>
/plugin install sf-skills@<ton-marketplace>
```

Les skills sont disponibles sous le namespace `sf-skills:`, par exemple :

- `/sf-skills:generating-apex`
- `/sf-skills:generating-flow`
- `/sf-skills:querying-soql`

## Synchronisation depuis le repo amont

Les skills sont **vendorés** dans ce repo (copiés depuis `forcedotcom/sf-skills/skills/`). Pour les mettre à jour, utilise le script de sync correspondant à ton OS. Le script :

1. clone `forcedotcom/sf-skills` (sur la ref demandée),
2. remplace le contenu de `skills/`,
3. met à jour `version` et `description` dans `.claude-plugin/plugin.json` à partir du `package.json` amont.

### Windows (PowerShell)

```powershell
# Sync depuis main (par défaut)
.\scripts\sync-skills.ps1

# Sync depuis le dernier tag semver
.\scripts\sync-skills.ps1 -LatestTag

# Sync depuis un tag précis
.\scripts\sync-skills.ps1 -UpstreamRef 1.9.0

# Lister les tags disponibles d'amont
.\scripts\sync-skills.ps1 -ListTags

# Simulation : voir ce qui changerait sans rien modifier
.\scripts\sync-skills.ps1 -DryRun
.\scripts\sync-skills.ps1 -LatestTag -DryRun
```

### Linux / macOS (bash)

```bash
# Sync depuis main (par défaut)
./scripts/sync-skills.sh

# Sync depuis le dernier tag semver
./scripts/sync-skills.sh --latest-tag

# Sync depuis un tag précis
./scripts/sync-skills.sh --ref 1.9.0

# Lister les tags disponibles d'amont
./scripts/sync-skills.sh --list-tags

# Simulation : voir ce qui changerait sans rien modifier
./scripts/sync-skills.sh --dry-run
./scripts/sync-skills.sh --latest-tag --dry-run
```

## Attribution & licence

Les skills sont la propriété de **Salesforce (forcedotcom)** et sont distribués sous licence **[Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/)**.

- Source originale : <https://github.com/forcedotcom/sf-skills>
- Usage commercial **interdit** par la licence amont
- Toute redistribution doit maintenir l'attribution à Salesforce

Ce dépôt est fourni tel quel, sans affiliation avec Salesforce.
