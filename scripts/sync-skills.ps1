<#
.SYNOPSIS
    Synchronise skills/ et le manifeste du plugin depuis forcedotcom/sf-skills.

.DESCRIPTION
    Clone forcedotcom/sf-skills dans un dossier temporaire (sur main, sur un
    tag specifique, ou sur le dernier tag semver), remplace le contenu de
    skills/ par celui du repo amont, met a jour version + description dans
    .claude-plugin/plugin.json, et affiche le SHA importe.

.PARAMETER UpstreamUrl
    URL du repo amont. Par defaut : forcedotcom/sf-skills sur GitHub.

.PARAMETER UpstreamRef
    Branche ou tag a synchroniser. Par defaut : "main".

.PARAMETER LatestTag
    Si present, ignore -UpstreamRef et selectionne automatiquement le dernier
    tag semver d'amont.

.PARAMETER ListTags
    Si present, affiche la liste des tags d'amont (tries du plus recent au plus
    ancien) et quitte sans rien synchroniser.

.PARAMETER DryRun
    Si present, clone l'amont et affiche ce qui changerait, mais ne modifie
    NI skills/ NI plugin.json. Utile pour valider la sync avant de l'appliquer.

.EXAMPLE
    # Sync depuis main (par defaut)
    .\scripts\sync-skills.ps1

.EXAMPLE
    # Sync depuis le dernier tag semver
    .\scripts\sync-skills.ps1 -LatestTag

.EXAMPLE
    # Sync depuis un tag precis
    .\scripts\sync-skills.ps1 -UpstreamRef 1.9.0

.EXAMPLE
    # Lister les tags disponibles d'amont
    .\scripts\sync-skills.ps1 -ListTags

.EXAMPLE
    # Simulation : voir ce qui changerait sans rien modifier
    .\scripts\sync-skills.ps1 -DryRun
    .\scripts\sync-skills.ps1 -LatestTag -DryRun

.PARAMETER Commit
    Si present, apres la sync : git add skills/ + plugin.json, git commit avec
    un message standard, puis git tag v<version> sur le commit cree.

.EXAMPLE
    # Sync + commit + tag automatiques
    .\scripts\sync-skills.ps1 -LatestTag -Commit
#>

[CmdletBinding()]
param(
    [string]$UpstreamUrl = "https://github.com/forcedotcom/sf-skills.git",
    [string]$UpstreamRef = "main",
    [switch]$LatestTag,
    [switch]$ListTags,
    [switch]$DryRun,
    [switch]$Commit
)

$ErrorActionPreference = "Stop"

function Get-SkillFrontmatter {
    <# Lit le frontmatter YAML d'un SKILL.md et renvoie un hashtable
       avec les cles trouvees (name, description, ...). Gere les
       valeurs en double-quote, single-quote, et brutes.
    #>
    param([string]$Path)

    $content = Get-Content -Path $Path -Raw -ErrorAction Stop
    $result  = @{}

    if ($content -notmatch '(?s)^---\s*\r?\n(.*?)\r?\n---') {
        return $result
    }
    $frontmatter = $matches[1]

    foreach ($line in ($frontmatter -split "`r?`n")) {
        # On ignore les sous-cles indentees ; on ne lit que les cles racine
        if ($line -match '^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$') {
            $key   = $matches[1]
            $value = $matches[2]

            if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
                # Double-quote : on de-escape \" et \\
                $value = $value.Substring(1, $value.Length - 2) -replace '\\"', '"' -replace '\\\\', '\'
            }
            elseif ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
                # Single-quote YAML : les ''  representent un '
                $value = $value.Substring(1, $value.Length - 2) -replace "''", "'"
            }

            $result[$key] = $value
        }
    }

    return $result
}

function Build-AgentSkillsManifest {
    <# Construit un objet manifest.json conforme a la spec Agent Skills
       a partir du contenu reel de skills/. Champs disponibles seulement :
       name, path, folderPath, files, description.
    #>
    param(
        [string]$SkillsDir,
        [string]$Branch,
        [string]$Sha
    )

    $skillEntries = @()
    foreach ($skillDir in (Get-ChildItem -Path $SkillsDir -Directory | Sort-Object Name)) {
        $skillFile = Join-Path $skillDir.FullName "SKILL.md"
        if (-not (Test-Path $skillFile)) { continue }

        $fm          = Get-SkillFrontmatter -Path $skillFile
        $skillName   = if ($fm.ContainsKey('name'))        { $fm['name'] }        else { $skillDir.Name }
        $description = if ($fm.ContainsKey('description')) { $fm['description'] } else { "" }

        # Liste de fichiers relative au dossier du skill, separateurs /
        $files = @()
        foreach ($f in (Get-ChildItem -Path $skillDir.FullName -Recurse -File | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($skillDir.FullName.Length + 1) -replace '\\', '/'
            $files += $rel
        }

        $skillEntries += [ordered]@{
            name        = $skillName
            path        = "skills/$($skillDir.Name)/SKILL.md"
            folderPath  = "skills/$($skillDir.Name)"
            files       = $files
            description = $description
        }
    }

    return [ordered]@{
        version     = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        branch      = $Branch
        upstreamSha = $Sha
        skills      = $skillEntries
    }
}

function Get-UpstreamTags {
    param([string]$Url)

    $output = git ls-remote --tags --refs $Url 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        throw "Impossible de lister les tags depuis $Url"
    }
    $tags = @()
    foreach ($line in $output) {
        if ($line -match '^\s*([0-9a-f]+)\s+refs/tags/(.+)$') {
            $tags += [pscustomobject]@{
                Sha = $matches[1]
                Tag = $matches[2]
            }
        }
    }
    # Tri semver decroissant via [System.Version] (compatible PS 5.1).
    # Les tags non parsables finissent en bas (version 0.0).
    return $tags | Sort-Object -Property @{
        Expression = {
            $clean = ($_.Tag -replace '^v', '')
            # [version] exige au moins X.Y et n'accepte pas les suffixes "-alpha".
            # On retombe sur 0.0 si parsing impossible.
            $parsed = $null
            if ([System.Version]::TryParse($clean, [ref]$parsed)) { $parsed }
            else { [System.Version]'0.0' }
        }
        Descending = $true
    }
}

# ---- Mode 1 : lister les tags et sortir ----
if ($ListTags) {
    Write-Host "Tags disponibles sur $UpstreamUrl (recents en premier) :" -ForegroundColor Cyan
    $tags = Get-UpstreamTags -Url $UpstreamUrl
    if (-not $tags) {
        Write-Host "  (aucun tag trouve)" -ForegroundColor Yellow
        return
    }
    foreach ($t in $tags) {
        "{0,-15} {1}" -f $t.Tag, $t.Sha
    }
    return
}

# ---- Mode 2 : auto-selection du dernier tag ----
if ($LatestTag) {
    $tags = Get-UpstreamTags -Url $UpstreamUrl
    if (-not $tags) { throw "Aucun tag trouve sur $UpstreamUrl" }
    $UpstreamRef = $tags[0].Tag
    Write-Host "Dernier tag detecte : $UpstreamRef" -ForegroundColor Cyan
}

$repoRoot       = Split-Path -Parent $PSScriptRoot
$skillsDir      = Join-Path $repoRoot "skills"
$pluginJsonPath = Join-Path $repoRoot ".claude-plugin\plugin.json"
$manifestPath   = Join-Path $repoRoot "manifest.json"
$tempDir        = Join-Path ([System.IO.Path]::GetTempPath()) ("sf-skills-upstream-" + [System.Guid]::NewGuid().ToString("N"))

Write-Host "Repo plugin       : $repoRoot"
Write-Host "Source amont      : $UpstreamUrl ($UpstreamRef)"
Write-Host "Clone temporaire  : $tempDir"
if ($DryRun) {
    Write-Host "Mode              : DRY-RUN (aucune modification ne sera appliquee)" -ForegroundColor Yellow
}
Write-Host ""

try {
    Write-Host "Clonage de $UpstreamUrl..." -ForegroundColor Cyan
    git clone --depth 1 --branch $UpstreamRef $UpstreamUrl $tempDir
    if ($LASTEXITCODE -ne 0) { throw "git clone a echoue (code $LASTEXITCODE)" }

    $upstreamSkills      = Join-Path $tempDir "skills"
    $upstreamPackageJson = Join-Path $tempDir "package.json"
    if (-not (Test-Path $upstreamSkills))      { throw "skills/ introuvable dans le clone amont" }
    if (-not (Test-Path $upstreamPackageJson)) { throw "package.json introuvable dans le clone amont" }

    $upstreamPackage     = Get-Content $upstreamPackageJson -Raw | ConvertFrom-Json
    $upstreamVersion     = $upstreamPackage.version
    $upstreamDescription = $upstreamPackage.description
    if ([string]::IsNullOrWhiteSpace($upstreamVersion))     { throw "Version introuvable dans le package.json amont" }
    if ([string]::IsNullOrWhiteSpace($upstreamDescription)) { throw "Description introuvable dans le package.json amont" }
    Write-Host "Version amont     : $upstreamVersion" -ForegroundColor Cyan
    Write-Host "Description amont : $upstreamDescription" -ForegroundColor Cyan

    # ---- Lit l'etat local courant (pour diff et dry-run) ----
    if (-not (Test-Path $pluginJsonPath)) { throw "plugin.json introuvable : $pluginJsonPath" }
    $pluginContent = Get-Content $pluginJsonPath -Raw

    $versionPattern     = '("version"\s*:\s*")[^"]*(")'
    $descriptionPattern = '("description"\s*:\s*")(?:[^"\\]|\\.)*(")'

    if ($pluginContent -notmatch $versionPattern) {
        throw "Champ `"version`" introuvable dans plugin.json - ajoute-le manuellement avant de relancer le script"
    }
    if ($pluginContent -notmatch $descriptionPattern) {
        throw "Champ `"description`" introuvable dans plugin.json - ajoute-le manuellement avant de relancer le script"
    }

    $currentPackage = Get-Content $pluginJsonPath -Raw | ConvertFrom-Json
    $currentVersion     = $currentPackage.version
    $currentDescription = $currentPackage.description

    $localSkills    = if (Test-Path $skillsDir) {
        @(Get-ChildItem -Path $skillsDir -Directory | Select-Object -ExpandProperty Name)
    } else { @() }
    $upstreamSkillsList = @(Get-ChildItem -Path $upstreamSkills -Directory | Select-Object -ExpandProperty Name)

    $added   = @($upstreamSkillsList | Where-Object { $_ -notin $localSkills })
    $removed = @($localSkills        | Where-Object { $_ -notin $upstreamSkillsList })

    Push-Location $tempDir
    $upstreamSha = (git rev-parse HEAD).Trim()
    Pop-Location

    # ---- Diff resume ----
    Write-Host ""
    Write-Host "Changements detectes :" -ForegroundColor Cyan
    Write-Host ("  Ref amont           : {0} ({1})" -f $UpstreamRef, $upstreamSha.Substring(0,7))
    Write-Host ("  version             : {0} -> {1}" -f $currentVersion,     $upstreamVersion)
    Write-Host ("  description         : {0} -> {1}" -f $currentDescription, $upstreamDescription)
    Write-Host ("  skills (local|amont): {0} | {1}" -f $localSkills.Count, $upstreamSkillsList.Count)
    if ($added)   { Write-Host ("  + ajoutes  ({0}) : {1}" -f $added.Count,   ($added   -join ', ')) -ForegroundColor Green }
    if ($removed) { Write-Host ("  - retires  ({0}) : {1}" -f $removed.Count, ($removed -join ', ')) -ForegroundColor Yellow }
    if (-not $added -and -not $removed) {
        Write-Host "  (aucun skill ajoute ou retire ; le contenu individuel peut neanmoins differer)"
    }
    Write-Host ""

    if ($DryRun) {
        Write-Host "DRY-RUN : aucune modification appliquee." -ForegroundColor Yellow
        Write-Host "Pour appliquer, relance sans -DryRun."
        return
    }

    # ---- Application reelle ----
    Write-Host "Suppression de l'ancien contenu de skills/..." -ForegroundColor Cyan
    if (Test-Path $skillsDir) {
        Get-ChildItem -Path $skillsDir -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $skillsDir | Out-Null
    }

    Write-Host "Copie de upstream/skills/ vers skills/..." -ForegroundColor Cyan
    Copy-Item -Path (Join-Path $upstreamSkills "*") -Destination $skillsDir -Recurse -Force

    Write-Host "Mise a jour de version et description dans plugin.json..." -ForegroundColor Cyan
    # Echappe pour replacement regex (le replacement traite '$' specialement)
    $escapedDescription = $upstreamDescription -replace '\\', '\\\\' -replace '"', '\"'
    $escapedDescriptionForRegex = $escapedDescription -replace '\$', '$$$$'

    $pluginContent = [System.Text.RegularExpressions.Regex]::Replace(
        $pluginContent, $versionPattern,
        ('${1}' + $upstreamVersion + '${2}')
    )
    $pluginContent = [System.Text.RegularExpressions.Regex]::Replace(
        $pluginContent, $descriptionPattern,
        ('${1}' + $escapedDescriptionForRegex + '${2}')
    )
    # Conserve l'encodage UTF-8 sans BOM
    [System.IO.File]::WriteAllText($pluginJsonPath, $pluginContent, (New-Object System.Text.UTF8Encoding $false))

    Write-Host "Generation de manifest.json (Agent Skills) depuis skills/..." -ForegroundColor Cyan
    $manifest     = Build-AgentSkillsManifest -SkillsDir $skillsDir -Branch $UpstreamRef -Sha $upstreamSha
    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding $false))

    $count = (Get-ChildItem -Path $skillsDir -Directory).Count
    $tagName       = "v$upstreamVersion"
    $commitMessage = "chore: sync skills $tagName from forcedotcom/sf-skills@$($upstreamSha.Substring(0,7))"

    Write-Host ""
    Write-Host "Sync terminee." -ForegroundColor Green
    Write-Host "  Skills synchronises : $count"

    if ($Commit) {
        Write-Host ""
        Write-Host "Commit + tag automatiques..." -ForegroundColor Cyan

        # Verifie qu'on est bien dans un repo git
        Push-Location $repoRoot
        try {
            git rev-parse --is-inside-work-tree | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Pas dans un repo git : $repoRoot" }

            # Refuse de re-taguer si le tag existe deja
            $existingTag = git tag --list $tagName
            if ($existingTag) {
                throw "Le tag '$tagName' existe deja. Supprime-le (git tag -d $tagName) ou choisis un autre ref."
            }

            git add "skills/" ".claude-plugin/plugin.json" "manifest.json"
            if ($LASTEXITCODE -ne 0) { throw "git add a echoue" }

            # Si rien n'a change, on ne commit pas mais on continue (le tag peut quand meme etre pose sur HEAD)
            $staged = git diff --cached --name-only
            if ($staged) {
                git commit -m $commitMessage
                if ($LASTEXITCODE -ne 0) { throw "git commit a echoue" }
                Write-Host "  Commit cree : $commitMessage" -ForegroundColor Green
            } else {
                Write-Host "  Aucun changement a commiter (HEAD est deja synchro)." -ForegroundColor Yellow
            }

            git tag -a $tagName -m "Sync from forcedotcom/sf-skills@$upstreamSha"
            if ($LASTEXITCODE -ne 0) { throw "git tag a echoue" }
            Write-Host "  Tag cree    : $tagName" -ForegroundColor Green

            Write-Host ""
            Write-Host "Pour publier : git push --follow-tags origin main"
        }
        finally { Pop-Location }
    }
    else {
        Write-Host ""
        Write-Host "Pense a committer + taguer :"
        Write-Host "  git add skills/ .claude-plugin/plugin.json manifest.json"
        Write-Host "  git commit -m `"$commitMessage`""
        Write-Host "  git tag -a $tagName -m `"Sync from forcedotcom/sf-skills@$upstreamSha`""
        Write-Host ""
        Write-Host "Ou relance le script avec -Commit pour tout faire d'un coup."
    }
}
finally {
    if (Test-Path $tempDir) {
        Write-Host "Nettoyage du clone temporaire..." -ForegroundColor DarkGray
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
