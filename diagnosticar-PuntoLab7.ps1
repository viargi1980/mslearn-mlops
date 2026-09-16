# AI-300 - Lab 7 restart diagnostic
# Run this in PowerShell on the godeploy virtual machine.
# It only reads local Git files and public GitHub evidence.
# It does not log in to Azure, create resources, read secrets, or change Git.

$ErrorActionPreference = 'Stop'

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host ('-' * 79) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * 79) -ForegroundColor DarkGray
}

function Write-Result([string]$Label, [string]$Text, [ConsoleColor]$Color = 'White') {
    Write-Host ("{0} {1}" -f $Label, $Text) -ForegroundColor $Color
}

function Test-ContentMatch([string]$Path, [string]$Pattern) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-Content -LiteralPath $Path -Raw) -match $Pattern)
}

function Test-GitRefContentMatch([string]$Repo, [string]$Ref, [string]$RelativePath, [string]$Pattern) {
    $Content = @(& git -C $Repo show "${Ref}:$RelativePath" 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($Content -join "`n") -match $Pattern)
}

function Get-GitHubCoordinates([string]$Remote) {
    if ($Remote -match 'github\.com[:/]([^/]+)/(.+?)(?:\.git)?$') {
        return @($Matches[1], $Matches[2])
    }
    return $null
}

function Get-GitHubData([string]$Uri) {
    return Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'AI300-Lab7-Diagnostic' } -TimeoutSec 12
}

Write-Section 'AI-300 - Lab 7 restart diagnostic'
Write-Host 'Paste the path to YOUR mslearn-mlops clone on this virtual machine.'
Write-Host 'Example: C:\Users\azureuser\mslearn-mlops'
$RepoPath = (Read-Host 'Repository path').Trim('"')

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    Write-Result '[ERROR]' "Path does not exist: $RepoPath" Red
    exit 1
}

try {
    $IsGitRepository = (& git -C $RepoPath rev-parse --is-inside-work-tree 2>$null).Trim()
} catch {
    $IsGitRepository = ''
}
if ($IsGitRepository -ne 'true') {
    Write-Result '[ERROR]' 'The selected path is not a Git repository.' Red
    exit 1
}

$CurrentBranch = (& git -C $RepoPath branch --show-current).Trim()
$Origin = (& git -C $RepoPath remote get-url origin 2>$null).Trim()
$Dirty = @(& git -C $RepoPath status --porcelain)

$ManualWorkflow = Join-Path $RepoPath '.github\workflows\manual-trigger-job.yml'
$DevWorkflow = Join-Path $RepoPath '.github\workflows\train-dev.yml'
$JobFile = Join-Path $RepoPath 'src\job.yml'
$ProdWorkflow = Join-Path $RepoPath '.github\workflows\train-prod.yml'
$DeployWorkflow = Join-Path $RepoPath '.github\workflows\deploy-prod.yml'

Write-Section '1. Local Git evidence'
Write-Result '[INFO]' "Repository: $RepoPath"
Write-Result '[INFO]' "Current branch: $CurrentBranch"
Write-Result '[INFO]' "Origin: $Origin"
if ($Dirty.Count -gt 0) {
    Write-Result '[WARNING]' 'There are uncommitted local changes. Do not discard them; note them before changing branch.' Yellow
} else {
    Write-Result '[OK]' 'Working tree is clean.' Green
}

$MainRef = 'origin/main'
$MainRefExists = (& git -C $RepoPath rev-parse --verify --quiet "${MainRef}^{commit}" 2>$null)
if ($MainRefExists) {
    $C1 = (Test-GitRefContentMatch $RepoPath $MainRef '.github/workflows/manual-trigger-job.yml' '(?m)^\s*workflow_dispatch:') -and -not (Test-GitRefContentMatch $RepoPath $MainRef '.github/workflows/manual-trigger-job.yml' '(?m)^\s*pull_request:')
} else {
    $C1 = (Test-ContentMatch $ManualWorkflow '(?m)^\s*workflow_dispatch:') -and -not (Test-ContentMatch $ManualWorkflow '(?m)^\s*pull_request:')
}
$C2 = (Test-ContentMatch $DevWorkflow '(?m)^\s*pull_request:') -and (Test-ContentMatch $DevWorkflow 'src/train-model-parameters\.py') -and (Test-ContentMatch $DevWorkflow 'src/job\.yml')
$C3 = (Test-ContentMatch $JobFile 'type:\s*uri_folder') -and (Test-ContentMatch $JobFile 'azureml:diabetes-dev-folder@latest') -and (Test-ContentMatch $JobFile 'reg_rate:\s*[0-9]')

if ($C1) { Write-Result '[OK]' 'C1 (main/local branch). Manual workflow only uses workflow_dispatch.' Green }
else { Write-Result '[ERROR]' 'C1 (main/local branch). STOP: merge a correction PR that removes pull_request from manual-trigger-job.yml.' Red }
if ($C2) { Write-Result '[OK]' 'C2 (local branch). train-dev.yml has a pull_request trigger for training changes.' Green }
else { Write-Result '[WARNING]' 'C2 (local branch). This branch does not yet contain the dev PR trigger.' Yellow }
if ($C3) { Write-Result '[OK]' 'C3 (local branch). job.yml uses uri_folder, diabetes-dev-folder@latest, and numeric reg_rate.' Green }
else { Write-Result '[WARNING]' 'C3 (local branch). This branch does not yet contain the dev job contract.' Yellow }
if (Test-ContentMatch $ProdWorkflow '/train-prod') { Write-Result '[OK]' 'Production workflow accepts /train-prod.' Green }
else { Write-Result '[ERROR]' 'train-prod.yml is missing or does not accept /train-prod.' Red }
if (Test-ContentMatch $DeployWorkflow '/deploy-prod') { Write-Result '[OK]' 'Deployment workflow accepts /deploy-prod.' Green }
else { Write-Result '[ERROR]' 'deploy-prod.yml is missing or does not accept /deploy-prod.' Red }

$DevDone = $false
$ProdDone = $false
$DeployDone = $false
$EffectiveC1 = $C1
$EffectiveC2 = $C2
$EffectiveC3 = $C3
$Coordinates = Get-GitHubCoordinates $Origin

Write-Section '2. Persistent GitHub evidence'
if ($null -eq $Coordinates) {
    Write-Result '[WARNING]' 'Origin is not a recognized GitHub URL. PR and Actions cannot be checked automatically.' Yellow
} else {
    $Owner = $Coordinates[0]
    $Repository = $Coordinates[1]
    try {
        # Force enumeration: Invoke-RestMethod can otherwise return a JSON array as one object.
        $Pulls = @((Get-GitHubData "https://api.github.com/repos/$Owner/$Repository/pulls?state=open&per_page=100") | ForEach-Object { $_ })
        $MatchingPrs = @($Pulls | Where-Object { $_.head.ref -eq $CurrentBranch })
        if ($MatchingPrs.Count -gt 0) { $Pr = $MatchingPrs[0] }
        elseif ($Pulls.Count -eq 1) { $Pr = $Pulls[0] }
        else {
            # With several open PRs, select the only branch that has already
            # completed the dev workflow. This is the furthest verified PR.
            $DevValidatedPrs = @()
            foreach ($Candidate in $Pulls) {
                $CandidateRuns = Get-GitHubData "https://api.github.com/repos/$Owner/$Repository/actions/runs?branch=$($Candidate.head.ref)&per_page=100"
                $HasDevSuccess = @($CandidateRuns.workflow_runs | Where-Object { $_.name -eq 'Train model in dev' -and $_.conclusion -eq 'success' }).Count -gt 0
                if ($HasDevSuccess) { $DevValidatedPrs += $Candidate }
            }
            if ($DevValidatedPrs.Count -eq 1) {
                $Pr = $DevValidatedPrs[0]
                Write-Result '[INFO]' "Several open PRs found. Selected PR #$($Pr.number), the only one with successful dev training."
            } else {
                $Pr = $null
            }
        }

        if ($null -eq $Pr) {
            Write-Result '[WARNING]' "No single open PR can be selected for branch $CurrentBranch." Yellow
            Write-Result '[INFO]' 'Use the branch for the PR being resumed, or close unrelated PRs, and run the diagnostic again.'
        } else {
            $PrNumber = $Pr.number
            $PrBranch = $Pr.head.ref
            Write-Result '[OK]' "Open PR #$PrNumber found for branch $PrBranch." Green

            # The learner may be on main. Inspect the PR head through origin/<branch>
            # without switching branches or changing the local clone.
            $PrRef = "origin/$PrBranch"
            $PrRefExists = (& git -C $RepoPath rev-parse --verify --quiet "${PrRef}^{commit}" 2>$null)
            if ($PrRefExists) {
                $PrC1 = (Test-GitRefContentMatch $RepoPath $PrRef '.github/workflows/manual-trigger-job.yml' '(?m)^\s*workflow_dispatch:') -and -not (Test-GitRefContentMatch $RepoPath $PrRef '.github/workflows/manual-trigger-job.yml' '(?m)^\s*pull_request:')
                $EffectiveC2 = (Test-GitRefContentMatch $RepoPath $PrRef '.github/workflows/train-dev.yml' '(?m)^\s*pull_request:') -and (Test-GitRefContentMatch $RepoPath $PrRef '.github/workflows/train-dev.yml' 'src/train-model-parameters\.py') -and (Test-GitRefContentMatch $RepoPath $PrRef '.github/workflows/train-dev.yml' 'src/job\.yml')
                $EffectiveC3 = (Test-GitRefContentMatch $RepoPath $PrRef 'src/job.yml' 'type:\s*uri_folder') -and (Test-GitRefContentMatch $RepoPath $PrRef 'src/job.yml' 'azureml:diabetes-dev-folder@latest') -and (Test-GitRefContentMatch $RepoPath $PrRef 'src/job.yml' 'reg_rate:\s*[0-9]')

                if ($CurrentBranch -ne $PrBranch) { Write-Result '[INFO]' "The local branch is $CurrentBranch. The following is the relevant PR #$PrNumber branch state:" }
                if ($PrC1) { Write-Result '[INFO]' 'C1 (PR branch). The correction exists in this PR, but C1 only completes when it is merged into main.' } else { Write-Result '[INFO]' 'C1 (PR branch). The manual workflow correction is not in this PR.' }
                if ($EffectiveC2) { Write-Result '[OK]' 'C2 (PR branch). Dev PR validation is configured.' Green } else { Write-Result '[ERROR]' 'C2 (PR branch). Dev PR validation is not configured.' Red }
                if ($EffectiveC3) { Write-Result '[OK]' 'C3 (PR branch). Dev job contract is configured.' Green } else { Write-Result '[ERROR]' 'C3 (PR branch). Dev job contract is not configured.' Red }
            } else {
                Write-Result '[WARNING]' "The local clone does not contain $PrRef. Run git fetch, then run this diagnostic again." Yellow
            }

            $Comments = @((Get-GitHubData "https://api.github.com/repos/$Owner/$Repository/issues/$PrNumber/comments?per_page=100") | ForEach-Object { $_ })
            $RunsResponse = Get-GitHubData "https://api.github.com/repos/$Owner/$Repository/actions/runs?branch=$PrBranch&per_page=100"
            $Runs = @($RunsResponse.workflow_runs)
            $CommentText = ($Comments | ForEach-Object { $_.body }) -join "`n"

            $DevDone = (@($Runs | Where-Object { $_.name -eq 'Train model in dev' -and $_.conclusion -eq 'success' }).Count -gt 0) -and ($CommentText -match 'Dev evaluation metrics')
            $ProdDone = (@($Runs | Where-Object { $_.name -eq 'Train model in prod (PR comment)' -and $_.conclusion -eq 'success' }).Count -gt 0) -and ($CommentText -match 'Prod evaluation metrics')
            $DeployDone = (@($Runs | Where-Object { $_.name -eq 'Deploy model to online endpoint (PR comment)' -and $_.conclusion -eq 'success' }).Count -gt 0) -and ($CommentText -match 'Deployment workflow completed')

            if ($DevDone) { Write-Result '[OK]' 'C4. Successful dev run and dev metrics comment found.' Green }
            else { Write-Result '[WARNING]' 'C4. No successful dev run with dev metrics comment found.' Yellow }
            if ($ProdDone) { Write-Result '[OK]' 'C5. Successful prod run and prod metrics comment found.' Green }
            else { Write-Result '[WARNING]' 'C5. Prod training is not verified. A Skipped run does not count.' Yellow }
            if ($DeployDone) { Write-Result '[OK]' 'C6. Successful deployment run and deployment comment found.' Green }
            else { Write-Result '[WARNING]' 'C6. Deployment is not verified from the PR.' Yellow }

            foreach ($Run in $Runs | Where-Object { $_.name -in @('Train model in dev', 'Train model in prod (PR comment)', 'Deploy model to online endpoint (PR comment)') }) {
                $State = if ($Run.conclusion) { $Run.conclusion } else { $Run.status }
                Write-Host ("    {0} -> {1}" -f $Run.name, $State) -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Result '[WARNING]' 'GitHub did not respond. The network may be unavailable, the repo may be private, or API access may be denied.' Yellow
        Write-Result '[INFO]' "Check manually: https://github.com/$Owner/$Repository/pulls"
    }
}

Write-Section '3. Where to resume'
$ActiveSession = Read-Host 'Is the godeploy session that created Azure resources still active now? [y/N]'
if ($ActiveSession -notmatch '^[yYsS]$') {
    Write-Result '[INFO]' 'Azure state is treated as expired. Do not reuse endpoints, secrets, service principals, resource groups, or workspaces.'
    if (-not $EffectiveC1) {
        Write-Result '[ERROR]' 'Resume C1 only: create a correction branch, remove pull_request from manual-trigger-job.yml, and merge that correction PR into main.' Red
        Write-Host 'Run this diagnostic again after the merge. Azure is also expired, but do not continue to C2-C9 before C1 is complete.'
    } elseif (-not $EffectiveC2 -or -not $EffectiveC3) {
        if (-not $EffectiveC2) { Write-Host 'Resume C2: add the restricted pull_request trigger to train-dev.yml.' }
        if (-not $EffectiveC3) { Write-Host 'Resume C3: set uri_folder, diabetes-dev-folder@latest, and a numeric reg_rate in src/job.yml.' }
        Write-Host 'Then create or update the training PR and wait for Train model in dev with metrics.'
    } else {
        Write-Host 'Azure restart point: infrastructure and data assets, before Lab step 1.'
        Write-Host '1) In a new godeploy session, run and validate infra/setup.sh.'
        Write-Host '2) Confirm aml-cluster and diabetes-training, diabetes-data, diabetes-dev-folder, diabetes-prod-folder.'
        Write-Host '3) Create a new service principal limited to the new resource group. Update AZURE_CREDENTIALS in dev and prod.'
        if ($DevDone) { Write-Host '4) Git evidence reaches C4. When new secrets work, comment /train-prod on the open PR.' }
        else { Write-Host '4) Create or update the training PR, then wait for Train model in dev with metrics.' }
    }
} elseif (-not $DevDone) {
    Write-Host 'Resume C1-C4. Fix the contract, create or update the PR, and wait for Train model in dev with metrics.'
} elseif (-not $ProdDone) {
    Write-Host 'Resume C5. Review dev metrics and comment /train-prod on its own line in the same PR.'
} elseif (-not $DeployDone) {
    Write-Host 'Resume C6. Review prod metrics and comment /deploy-prod on its own line in the same PR.'
} else {
    Write-Host 'Resume C7. Test the endpoint, then configure and review the monitor (C8) before simulating drift (C9).'
}

Write-Host ''
Write-Host 'Rule: do not use /deploy-prod without a successful Train model in prod run with metrics. Skipped is not training evidence.' -ForegroundColor Yellow
