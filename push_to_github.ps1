param(
    [Parameter(Mandatory=$true, HelpMessage="Dan link repo GitHub cua ban (VD: https://github.com/tenban/pin-ts.git)")]
    [string]$RepoUrl
)

Set-Location -Path $PSScriptRoot
git branch -M main
if (git remote | Select-String "origin") {
    git remote set-url origin $RepoUrl
} else {
    git remote add origin $RepoUrl
}
git push -u origin main --force
Write-Host ""
Write-Host "[OK] Da day code len GitHub! Hay mo tab Actions / Releases tren repo cua ban sau ~90 giay de tai PinNhietDo_TS.tipa" -ForegroundColor Green
