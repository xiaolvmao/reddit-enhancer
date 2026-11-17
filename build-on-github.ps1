# One-click: login -> create repo -> push -> trigger build -> download dylib
$ErrorActionPreference = "Stop"
$proj = "C:\Users\desir\WorkBuddy\2026-11-17-18-06-07\RedditEnhancerTweak"
Set-Location $proj

function Test-Login {
    gh auth status 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "== Step 1: GitHub login ==" -ForegroundColor Cyan
if (-not (Test-Login)) {
    Write-Host "Not logged in. Opening browser for GitHub login..." -ForegroundColor Yellow
    gh auth login --git-protocol https --web
    if (-not (Test-Login)) {
        Write-Host "LOGIN FAILED. Please run 'gh auth login' manually and retry." -ForegroundColor Red
        exit 1
    }
}
Write-Host "Logged in." -ForegroundColor Green

$user = (gh api user --jq .login).Trim()
if (-not $user) { Write-Host "Cannot get username." -ForegroundColor Red; exit 1 }
$repo = "reddit-enhancer"
Write-Host ("GitHub user: {0}, repo: {1}" -f $user, $repo) -ForegroundColor Cyan

Write-Host "== Step 2: create repo and push ==" -ForegroundColor Cyan
gh repo create $repo --public --source=. --remote=origin --push
if ($LASTEXITCODE -ne 0) {
    Write-Host "Repo may already exist. Trying normal push..." -ForegroundColor Yellow
    git push -u origin HEAD
}

Write-Host "== Step 3: trigger build ==" -ForegroundColor Cyan
gh workflow run build.yml
if ($LASTEXITCODE -ne 0) { Write-Host "workflow run failed via dispatch; push should have triggered it." -ForegroundColor Yellow }
Start-Sleep -Seconds 8

Write-Host "== Step 4: watch build ==" -ForegroundColor Cyan
$runId = (gh run list --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId').Trim()
if (-not $runId) { Write-Host "No run found. Check GitHub Actions page." -ForegroundColor Red; exit 1 }
gh run watch $runId --exit-status
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed or watch error. Check Actions log." -ForegroundColor Red; exit 1 }

Write-Host "== Step 5: download dylib ==" -ForegroundColor Cyan
gh run download $runId -Dir "$proj\artifacts"
Write-Host ("DONE. Artifacts in: {0}\artifacts" -f $proj) -ForegroundColor Green
