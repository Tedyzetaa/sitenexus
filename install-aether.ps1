# ============================================================
#  AETHER - instalador/atualizador para Windows (PowerShell 5.1+)
#
#  Instalar ou atualizar (PowerShell):
#    irm https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-aether.ps1 | iex
#  Instalar ou atualizar (CMD):
#    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-aether.ps1 | iex"
#
#  Com opcoes (PowerShell):
#    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-aether.ps1))) -Forcar
#
#  Opcoes:
#    -Dir PASTA        pasta de instalacao (padrao: %USERPROFILE%\Aether)
#    -Forcar           atualiza mesmo que ja esteja na ultima versao
#    -OllamaHost URL   usa o Ollama de outro PC (ex.: http://192.168.0.10:11434)
#    -SemOllama        nao instala nem mexe no Ollama
#    -Extra "..."      argumentos extras repassados ao instalador (ex.: -Extra "--model qwen2.5:3b")
#
#  Primeira vez: instalacao normal (menu interativo).
#  Ja instalado: confere se ha versao nova; se nao houver, so informa. Se houver, atualiza
#  mantendo .env, personalidade e modelo. Sempre confere se o modelo ja esta no Ollama.
# ============================================================
[CmdletBinding()]
param(
    [string]$Dir = '',
    [switch]$Forcar,
    [string]$OllamaHost = '',
    [switch]$SemOllama,
    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Raw = if ($env:AETHER_RAW) { $env:AETHER_RAW.TrimEnd('/') } else { 'https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main' }
if (-not $Dir) { $Dir = Join-Path $env:USERPROFILE 'Aether' }
$Dir = [IO.Path]::GetFullPath($Dir)

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { throw $m }

function Get-EnvKey($path, $key) {
    if (-not (Test-Path $path)) { return '' }
    foreach ($ln in [IO.File]::ReadAllLines($path)) {
        if ($ln -match ('^' + [regex]::Escape($key) + '=(.*)$')) { return $Matches[1].Trim().Trim('"') }
    }
    return ''
}

# ---------------- Ollama ----------------
function Find-Ollama {
    $c = Get-Command ollama -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'), (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
function Get-OllamaModels($url) {
    try {
        $r = Invoke-RestMethod -Uri ($url.TrimEnd('/') + '/api/tags') -TimeoutSec 4
        return @($r.models | ForEach-Object { $_.name })
    } catch { return $null }
}
function Test-ModelPresent($names, $tag) {
    if ($null -eq $names -or -not $tag) { return $false }
    $norm = { param($t) $x = $t.Trim().ToLower(); if ($x.EndsWith(':latest')) { $x.Substring(0, $x.Length - 7) } else { $x } }
    $want = & $norm $tag
    foreach ($n in $names) { if ((& $norm $n) -eq $want) { return $true } }
    return $false
}
function Check-Model {
    $envPath = Join-Path $Dir '.env'
    $url = Get-EnvKey $envPath 'OLLAMA_HOST'
    if ($OllamaHost) { $url = $OllamaHost }
    if (-not $url) { $url = 'http://localhost:11434' }
    $mdl = Get-EnvKey $envPath 'OLLAMA_MODEL'
    $names = Get-OllamaModels $url
    if ($null -eq $names) { Warn "Ollama nao esta respondendo em $url (o instalador tenta iniciar)."; return }
    if (Test-ModelPresent $names $mdl) { Ok "Modelo '$mdl' ja instalado no Ollama - nao precisa baixar de novo."; return }
    $lista = if ($names.Count) { $names -join ', ' } else { 'nenhum' }
    Warn "Modelo '$mdl' nao encontrado. Presentes: $lista. O instalador baixa o que faltar."
}

function Main {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue) -and -not (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) { Die 'Sem ferramenta de download.' }

    $work = Join-Path $env:TEMP ('aether_link_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        Info 'Baixando o instalador do Aether...'
        $bat = Join-Path $work 'Instalar_Aether.bat'
        try { Invoke-WebRequest -UseBasicParsing -Uri "$Raw/Instalar_Aether.bat" -OutFile $bat -TimeoutSec 300 }
        catch { Die "Nao consegui baixar $Raw/Instalar_Aether.bat" }
        if ((Get-Item $bat).Length -lt 1000) { Die 'Arquivo baixado esta vazio ou invalido.' }
        $newSha = (Get-FileHash -Algorithm SHA256 $bat).Hash.ToLower()

        $stampFile = Join-Path $Dir '.aether-installer.sha'
        $oldSha = ''
        if (Test-Path $stampFile) { $oldSha = ([IO.File]::ReadAllText($stampFile)).Trim().ToLower() }
        $installed = Test-Path (Join-Path $Dir 'install_info.json')

        $args2 = New-Object System.Collections.Generic.List[string]
        if ($OllamaHost) { $args2.Add('--ollama-url'); $args2.Add($OllamaHost) }
        if ($SemOllama)  { $args2.Add('--skip-ollama') }
        foreach ($x in $Extra) { foreach ($t in ($x -split '\s+')) { if ($t) { $args2.Add($t) } } }
        $args2.Add('--dir'); $args2.Add($Dir)

        if ($installed) {
            Ok "Aether ja instalado em $Dir."
            Check-Model
            if (-not $Forcar -and $oldSha -and $oldSha -eq $newSha) {
                Ok 'Ja esta na ultima versao. Nada a atualizar (use -Forcar para reinstalar).'
                return
            }
            Info 'Atualizando (config, .env e modelo sao mantidos)...'
            $args2.Insert(0, '--yes')
        } else {
            Info 'Primeira instalacao do Aether.'
            Check-Model
        }

        # remove o "pause" final do .bat (sem alterar o resto do arquivo, que carrega o pacote embutido)
        $enc = [Text.Encoding]::GetEncoding(28591)
        $txt = $enc.GetString([IO.File]::ReadAllBytes($bat))
        $txt = [regex]::Replace($txt, "(\r?\n)pause(\r?\n)", '$1rem$2', 1)
        [IO.File]::WriteAllBytes($bat, $enc.GetBytes($txt))

        $quoted = ($args2 | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        & cmd.exe /c "`"$bat`" $quoted"
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { Die "O instalador terminou com codigo $rc." }

        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        [IO.File]::WriteAllText($stampFile, $newSha)
        Ok "Pronto. Iniciar: icone do Aether na area de trabalho, ou  $Dir\start.bat  (silencioso: start.bat silent)"
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}

try { Main } catch { if ($_.Exception.Message) { Write-Host "[X] $($_.Exception.Message)" -ForegroundColor Red } }
