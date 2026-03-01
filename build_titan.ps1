# build_titan.ps1 - Pipeline de build do Titan V3
# Uso: .\build_titan.ps1 [-Release]
param(
    [switch]$Release  # passa -Release para compilar em modo release
)

$ErrorActionPreference = "Stop"

$Root       = $PSScriptRoot
$SnifferDir = Join-Path $Root "TitanUI\sniffer-core"
$Profile    = if ($Release) { "release" } else { "debug" }
$OutProfile = if ($Release) { "Release" } else { "Debug" }
$OutDir     = Join-Path $Root "TitanUI\TitanUI\bin\$OutProfile\net8.0-windows"

# Cargo gera sniffer_core.dll (underscores); C# espera sniffer.dll
$DllSrc = Join-Path $SnifferDir "target\$Profile\sniffer_core.dll"
$DllDst = Join-Path $OutDir     "sniffer.dll"

Write-Host ""
Write-Host "=== Titan V3 - Build Pipeline ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. Verificar diretorio do sniffer-core ────────────────────────────────────
Write-Host "[1/3] Verificando sniffer-core..." -ForegroundColor Yellow

if (-not (Test-Path $SnifferDir)) {
    Write-Host ""
    Write-Host "ERRO: Diretorio nao encontrado:" -ForegroundColor Red
    Write-Host "      $SnifferDir"              -ForegroundColor Red
    Write-Host "      Clone com: git clone --recurse-submodules" -ForegroundColor Red
    exit 1
}

Write-Host "      OK -> $SnifferDir" -ForegroundColor Gray

# ── 1b. Verificar Npcap SDK ──────────────────────────────────────────────────
$NpcapCandidatos = @(
    $env:NPCAP_SDK_DIR,
    (Join-Path $env:USERPROFILE "npcap-sdk\Lib\x64"),
    "C:\Program Files\Npcap\SDK\Lib\x64",
    "C:\npcap-sdk\Lib\x64",
    (Join-Path $SnifferDir "npcap-sdk\Lib\x64")
) | Where-Object { $_ -and (Test-Path (Join-Path $_ "wpcap.lib")) }

if (-not $NpcapCandidatos) {
    Write-Host ""
    Write-Host "ERRO: Npcap SDK nao encontrado (wpcap.lib ausente)." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Solucoes:" -ForegroundColor Yellow
    Write-Host "  1. Baixe o SDK: https://npcap.com/dist/npcap-sdk-1.13.zip"
    Write-Host "     Extraia para: C:\npcap-sdk\"
    Write-Host ""
    Write-Host "  2. Ou defina a variavel de ambiente e execute novamente:"
    Write-Host '     $env:NPCAP_SDK_DIR = "C:\seu\caminho\Lib\x64"' -ForegroundColor Cyan
    Write-Host '     .\build_titan.ps1'                               -ForegroundColor Cyan
    exit 1
}

$NpcapSdkDir = $NpcapCandidatos | Select-Object -First 1
Write-Host "      SDK   -> $NpcapSdkDir" -ForegroundColor Gray

# ── 2. Compilar Rust ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/3] Compilando Rust (perfil: $Profile)..." -ForegroundColor Yellow

$cargoArgs = @("build")
if ($Release) { $cargoArgs += "--release" }

Write-Host "      Executando: cargo $($cargoArgs -join ' ')" -ForegroundColor Gray
Write-Host ""

Push-Location $SnifferDir
try {
    & cargo @cargoArgs
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "FALHA: cargo build retornou codigo $exitCode" -ForegroundColor Red
    Write-Host "       Corrija os erros acima e execute novamente." -ForegroundColor Red
    exit $exitCode
}

Write-Host ""
Write-Host "      Compilacao concluida." -ForegroundColor Gray

# ── 3. Copiar DLL para output do C# ──────────────────────────────────────────
Write-Host ""
Write-Host "[3/3] Copiando DLL para o projeto C#..." -ForegroundColor Yellow

if (-not (Test-Path $DllSrc)) {
    Write-Host ""
    Write-Host "ERRO: DLL nao encontrada apos build:" -ForegroundColor Red
    Write-Host "      $DllSrc"                        -ForegroundColor Red
    Write-Host "      Verifique: crate-type = [""cdylib""] no Cargo.toml" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    Write-Host "      Diretorio criado: $OutDir" -ForegroundColor Gray
}

Copy-Item -Path $DllSrc -Destination $DllDst -Force

Write-Host "      De : $DllSrc" -ForegroundColor Gray
Write-Host "      Para: $DllDst" -ForegroundColor Gray

# ── Sucesso ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Motor pronto para o Visual Studio! ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Perfil : $Profile"  -ForegroundColor White
Write-Host "  DLL    : $DllDst"   -ForegroundColor White
Write-Host ""
Write-Host "  Proximo passo: abra TitanUI.slnx e pressione F5." -ForegroundColor Cyan
Write-Host ""
