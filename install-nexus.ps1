# ============================================================
#  NEXUS-BRIDGE - instalador/atualizador para Windows (PowerShell 5.1+)
#
#  Instalar ou atualizar (PowerShell):
#    irm https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-nexus.ps1 | iex
#  Instalar ou atualizar (CMD):
#    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-nexus.ps1 | iex"
#
#  Com opcoes (PowerShell):
#    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-nexus.ps1))) -Porta 1666 -Rede
#
#  Opcoes:
#    -Dir PASTA        pasta de instalacao (padrao: %USERPROFILE%\nexus-bridge)
#    -Porta N          porta do servidor (padrao 1666)
#    -Rede             abre para a rede (0.0.0.0) - gera token e exige X-Nexus-Token
#    -Forcar           atualiza mesmo que ja esteja na ultima versao
#    -Completo         instala tambem torch CPU, whisper e coqui-tts (dublagem local; ~3 GB)
#    -SemOllama        nao mexe no Ollama
#    -OllamaHost URL   usa o Ollama de outro PC (ex.: http://192.168.0.10:11434)
#    -Modelo TAG       modelo do Ollama na 1a instalacao (padrao qwen2.5:3b-instruct-q4_K_M)
#    -Desinstalar      para o servidor e apaga a pasta
#
#  Se ja existe instalacao na pasta, so atualiza o codigo (mantem .env, venv, logs) e confere
#  se o modelo do Ollama ja esta instalado - so baixa se faltar.
# ============================================================
[CmdletBinding()]
param(
    [string]$Dir = '',
    [int]$Porta = 1666,
    [switch]$Rede,
    [switch]$Forcar,
    [switch]$Completo,
    [switch]$SemOllama,
    [string]$OllamaHost = '',
    [string]$Modelo = 'qwen2.5:3b-instruct-q4_K_M',
    [switch]$Desinstalar
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$env:PYTHONUTF8 = '1'

$Raw = if ($env:NEXUS_RAW) { $env:NEXUS_RAW.TrimEnd('/') } else { 'https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main' }
if (-not $Dir) { $Dir = Join-Path $env:USERPROFILE 'nexus-bridge' }
$Dir = [IO.Path]::GetFullPath($Dir)
$PyVer = '3.12'
$HostBind = if ($Rede) { '0.0.0.0' } else { '127.0.0.1' }

function Say($m)  { Write-Host $m }
function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Step($n, $m) { Write-Host ""; Write-Host "== [$n] $m" -ForegroundColor White }
function Die($m)  { throw $m }

function Write-Utf8($path, $text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

# ---------------- .env ----------------
function Get-EnvKey($path, $key) {
    if (-not (Test-Path $path)) { return '' }
    foreach ($ln in [IO.File]::ReadAllLines($path)) {
        if ($ln -match ('^' + [regex]::Escape($key) + '=(.*)$')) { return $Matches[1].Trim().Trim('"') }
    }
    return ''
}
function Set-EnvKey($path, $key, $val) {
    $lines = @()
    if (Test-Path $path) { $lines = @([IO.File]::ReadAllLines($path)) }
    $done = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
        if (-not $done -and $ln -match ('^' + [regex]::Escape($key) + '=')) { $out.Add("$key=$val"); $done = $true }
        else { $out.Add($ln) }
    }
    if (-not $done) { $out.Add("$key=$val") }
    Write-Utf8 $path (($out -join "`n") + "`n")
}

# ---------------- Python ----------------
function Test-Py([string]$exe, [string[]]$pre) {
    try {
        & $exe @pre -c "import sys,ssl,venv;sys.exit(0 if (3,10)<=sys.version_info[:2]<=(3,13) else 1)" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
function Find-Python {
    $cands = @(
        @{ e = 'py'; a = @('-3.12') }, @{ e = 'py'; a = @('-3.13') },
        @{ e = 'py'; a = @('-3.11') }, @{ e = 'py'; a = @('-3.10') },
        @{ e = 'python'; a = @() }, @{ e = 'python3'; a = @() }
    )
    foreach ($c in $cands) {
        if (-not (Get-Command $c.e -ErrorAction SilentlyContinue)) { continue }
        if (Test-Py $c.e $c.a) {
            $p = & $c.e @($c.a) -c "import sys;print(sys.executable)" 2>$null
            if ($p) { return ($p | Select-Object -First 1).Trim() }
        }
    }
    foreach ($v in '312', '313', '311', '310') {
        $p = Join-Path $env:LOCALAPPDATA "Programs\Python\Python$v\python.exe"
        if ((Test-Path $p) -and (Test-Py $p @())) { return $p }
    }
    return $null
}
function Install-Python {
    Info 'Python 3.10-3.13 nao encontrado. Instalando o Python 3.12 (so para o seu usuario, sem administrador)...'
    $setup = Join-Path $env:TEMP 'python-setup.exe'
    foreach ($u in 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe', 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe') {
        try {
            Info "Baixando $u"
            Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $setup
            Start-Process -FilePath $setup -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_launcher=1', 'Include_pip=1', 'Include_test=0', 'Shortcuts=0' -Wait
            break
        } catch { Warn "Falhou: $($_.Exception.Message)" }
    }
    $p = Find-Python
    if ($p) { return $p }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info 'Tentando pelo winget...'
        & winget install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements | Out-Null
        $p = Find-Python
    }
    return $p
}

# ---------------- servidor ----------------
function Stop-Nexus {
    $pidFile = Join-Path $Dir '.run\nexus.pid'
    $was = $false
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $cl = [string]$_.CommandLine
        $ex = [string]$_.ExecutablePath
        ($cl -like '*uvicorn*app.main:app*') -and (($cl -like "*$Dir*") -or ($ex -like "$Dir*"))
    } | ForEach-Object { $was = $true; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $pidFile) {
        $id = 0
        if ([int]::TryParse((Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$id) -and $id -gt 0) {
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $was = $true; Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    return $was
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
    if ($null -eq $names) { return $false }
    $norm = { param($t) $x = $t.Trim().ToLower(); if ($x.EndsWith(':latest')) { $x.Substring(0, $x.Length - 7) } else { $x } }
    $want = & $norm $tag
    foreach ($n in $names) { if ((& $norm $n) -eq $want) { return $true } }
    return $false
}
function Install-OllamaWin {
    Info 'Instalando o Ollama...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget install -e --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements | Out-Null
        $e = Find-Ollama; if ($e) { return $e }
    }
    try {
        $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup
        Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/NORESTART' -Wait
    } catch { Warn "Download do Ollama falhou: $($_.Exception.Message)" }
    return (Find-Ollama)
}
function Ensure-Ollama($envPath, $model, $installing) {
    $host_ = Get-EnvKey $envPath 'OLLAMA_HOST'
    if (-not $host_) { $host_ = 'http://localhost:11434' }
    $isLocal = $host_ -match 'localhost|127\.0\.0\.1'
    if (-not $isLocal) {
        $names = Get-OllamaModels $host_
        if ($null -eq $names) { Warn "Ollama remoto ($host_) nao respondeu agora." }
        elseif (Test-ModelPresent $names $model) { Ok "Modelo '$model' ja existe no Ollama remoto." }
        else { Warn "Modelo '$model' nao esta no Ollama remoto. Rode la:  ollama pull $model" }
        return
    }
    $exe = Find-Ollama
    if (-not $exe) {
        if ($installing) { $exe = Install-OllamaWin }
        if (-not $exe) { Warn 'Ollama nao encontrado. Instale em https://ollama.com/download e rode este comando de novo.'; return }
        Ok 'Ollama instalado.'
    }
    $names = Get-OllamaModels $host_
    if ($null -eq $names) {
        Info 'Iniciando o servidor do Ollama...'
        Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden
        for ($i = 0; $i -lt 40 -and $null -eq $names; $i++) { Start-Sleep -Seconds 1; $names = Get-OllamaModels $host_ }
    }
    if ($null -eq $names) { Warn 'O Ollama nao respondeu em 40 s. Abra o app do Ollama e rode de novo.'; return }
    if (Test-ModelPresent $names $model) { Ok "Modelo '$model' ja instalado - nada a baixar."; return }
    Info "Baixando o modelo $model (so este passo usa muita internet)..."
    & $exe pull $model
    if ($LASTEXITCODE -ne 0) { Warn "Falhou. Depois rode:  ollama pull $model" }
    else { Ok "Modelo $model pronto." }
}

# ---------------- launcher nexus.cmd ----------------
function Write-Launcher($hostBind, $port) {
    $t = @'
@echo off
setlocal
set "NEXUS_HOME=@@DIR@@"
set "NEXUS_HOST=@@HOST@@"
set "NEXUS_PORT=@@PORT@@"
set "PYTHONUTF8=1"
set "PYTHONUNBUFFERED=1"
cd /d "%NEXUS_HOME%"
set "PY=%NEXUS_HOME%\venv\Scripts\python.exe"
set "C=%~1"
if "%C%"=="" set "C=iniciar"
if /i "%C%"=="iniciar" goto :iniciar
if /i "%C%"=="bg" goto :bg
if /i "%C%"=="parar" goto :parar
if /i "%C%"=="status" goto :status
if /i "%C%"=="atualizar" goto :atualizar
echo Uso: nexus [iniciar ^| bg ^| parar ^| status ^| atualizar [-Forcar]]
exit /b 1

:iniciar
echo [*] Nexus-Bridge em http://%NEXUS_HOST%:%NEXUS_PORT%  -  Ctrl+C para parar
"%PY%" -m uvicorn app.main:app --host %NEXUS_HOST% --port %NEXUS_PORT% --no-access-log
exit /b %errorlevel%

:bg
if not exist logs mkdir logs
if not exist .run mkdir .run
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Start-Process -FilePath '%PY%' -ArgumentList '-m','uvicorn','app.main:app','--host','%NEXUS_HOST%','--port','%NEXUS_PORT%','--no-access-log' -WorkingDirectory '%NEXUS_HOME%' -WindowStyle Hidden -RedirectStandardOutput '%NEXUS_HOME%\logs\nexus.out.log' -RedirectStandardError '%NEXUS_HOME%\logs\nexus.err.log' -PassThru; Set-Content -Path '%NEXUS_HOME%\.run\nexus.pid' -Value $p.Id; Write-Host ('[OK] Nexus-Bridge em segundo plano, PID ' + $p.Id)"
exit /b 0

:parar
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*uvicorn*app.main:app*--port %NEXUS_PORT%*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Remove-Item '%NEXUS_HOME%\.run\nexus.pid' -Force -ErrorAction SilentlyContinue; Write-Host '[OK] Parado.'"
exit /b 0

:status
curl.exe -s -m 3 http://127.0.0.1:%NEXUS_PORT%/api/health
if errorlevel 1 (echo [!] Nexus-Bridge nao respondeu na porta %NEXUS_PORT%.) else echo.
exit /b 0

:atualizar
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-RestMethod '@@RAW@@/install-nexus.ps1'))) -Dir '%NEXUS_HOME%' %2"
exit /b %errorlevel%
'@
    $t = $t.Replace('@@DIR@@', $Dir).Replace('@@HOST@@', $hostBind).Replace('@@PORT@@', [string]$port).Replace('@@RAW@@', $Raw)
    $t = ($t -replace "`r?`n", "`r`n")
    [IO.File]::WriteAllText((Join-Path $Dir 'nexus.cmd'), $t, [Text.Encoding]::ASCII)
}

# ============================================================
#  principal
# ============================================================
function Main {
    Say ''
    Say ' ============================================================'
    Say '   NEXUS-BRIDGE - instalador para Windows'
    Say ' ============================================================'

    if ($Desinstalar) {
        if (-not (Test-Path (Join-Path $Dir '.nexus-install'))) { Die "Nao achei uma instalacao em $Dir." }
        $r = Read-Host "Apagar $Dir (inclui .env e logs)? [s/N]"
        if ($r -notmatch '^(s|S|y|Y)') { Say 'Cancelado.'; return }
        Stop-Nexus | Out-Null
        Remove-Item -Recurse -Force $Dir
        Ok 'Nexus-Bridge removido. (Python e Ollama ficaram instalados.)'
        return
    }

    $envPath = Join-Path $Dir '.env'
    $installed = Test-Path (Join-Path $Dir '.nexus-install')
    $oldHost = $HostBind; $oldPort = $Porta
    if ($installed) {
        # reaproveita host/porta da instalacao anterior, a menos que o usuario tenha passado de novo
        $meta = Join-Path $Dir '.nexus-install'
        $h = Get-EnvKey $meta 'INSTALL_HOST'; $p = Get-EnvKey $meta 'INSTALL_PORT'
        if (-not $PSBoundParameters.ContainsKey('Rede') -and $h) { $oldHost = $h }
        if (-not $PSBoundParameters.ContainsKey('Porta') -and $p) { $oldPort = [int]$p }
    }

    # ---- versao ----
    Step '1/6' 'Conferindo a versao no GitHub'
    $vtxt = ''
    try { $vtxt = [string](Invoke-RestMethod -Uri "$Raw/nexus-termux.version" -TimeoutSec 30) } catch { Die "Nao consegui baixar $Raw/nexus-termux.version (sem internet?)." }
    $remVer = ''; $remSha = ''
    if ($vtxt -match '(?m)^VERSION=(.+)$') { $remVer = $Matches[1].Trim() }
    if ($vtxt -match '(?m)^SHA256=([0-9a-fA-F]{64})') { $remSha = $Matches[1].ToLower() }
    if (-not $remSha) { Die 'Arquivo nexus-termux.version invalido (SHA256 ausente).' }
    $locVerFile = Join-Path $Dir '.nexus-version'
    $locVer = Get-EnvKey $locVerFile 'VERSION'; $locSha = (Get-EnvKey $locVerFile 'SHA256').ToLower()

    if ($installed) {
        Ok "Nexus-Bridge ja instalado em $Dir (versao $locVer)."
        if (-not $Forcar -and $locSha -eq $remSha -and (Test-Path (Join-Path $Dir 'venv\Scripts\python.exe'))) {
            Ok "Ja esta na ultima versao ($remVer). Nada a atualizar."
            if (-not $SemOllama) {
                Step '-' 'Conferindo o modelo do Ollama'
                $m = Get-EnvKey $envPath 'OLLAMA_MODEL'; if (-not $m) { $m = $Modelo }
                Ensure-Ollama $envPath $m $false
            }
            Say "Iniciar:  $Dir\nexus.cmd bg   (ou nexus.cmd para primeiro plano)"
            return
        }
        Info "Versao instalada: $locVer  ->  nova: $remVer"
    } else {
        Info "Primeira instalacao (versao $remVer) em $Dir"
    }

    # ---- python ----
    Step '2/6' 'Python'
    $py = Find-Python
    if (-not $py) { $py = Install-Python }
    if (-not $py) { Die 'Nao consegui preparar o Python 3.10-3.13. Instale em https://www.python.org/downloads/ (marque Add to PATH) e rode de novo.' }
    Ok "Python: $py"

    # ---- download ----
    Step '3/6' 'Baixando e verificando o pacote'
    $work = Join-Path $env:TEMP ('nexus_setup_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $tgz = Join-Path $work 'pkg.tgz'
        Info "Baixando nexus-termux.tar.gz ($remVer)..."
        Invoke-WebRequest -UseBasicParsing -Uri "$Raw/nexus-termux.tar.gz" -OutFile $tgz -TimeoutSec 900
        $got = (Get-FileHash -Algorithm SHA256 $tgz).Hash.ToLower()
        if ($got -ne $remSha) { Die 'SHA-256 nao confere (cache do GitHub?). Espere ~5 min e rode de novo.' }
        $src = Join-Path $work 'src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { Die 'tar.exe nao encontrado (precisa do Windows 10 1803 ou mais novo).' }
        & tar -xzf $tgz -C $src
        if ($LASTEXITCODE -ne 0) { Die 'Falha ao extrair o pacote.' }
        if (-not ((Test-Path (Join-Path $src 'app\main.py')) -and (Test-Path (Join-Path $src 'requirements.termux.txt')))) { Die 'Pacote incompleto.' }
        Ok 'Pacote baixado e verificado.'

        # ---- copiar codigo ----
        Step '4/6' "Copiando o codigo para $Dir"
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $wasRunning = Stop-Nexus
        if ($wasRunning) { Info 'Servidor parado para atualizar.' }
        foreach ($item in Get-ChildItem -LiteralPath $src -Force) {
            $dest = Join-Path $Dir $item.Name
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            Copy-Item -Recurse -Force -LiteralPath $item.FullName -Destination $dest
        }
        foreach ($d in 'logs', 'workspace', '.run') { New-Item -ItemType Directory -Force -Path (Join-Path $Dir $d) | Out-Null }
        Ok 'Codigo atualizado (.env, venv, logs e arquivos gerados foram mantidos).'

        # ---- venv + bibliotecas ----
        Step '5/6' 'Ambiente Python e bibliotecas'
        $vpy = Join-Path $Dir 'venv\Scripts\python.exe'
        $cur = ''
        if (Test-Path $vpy) { try { $cur = (& $vpy -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null | Select-Object -First 1) } catch { $cur = '' } }
        $pyMM = (& $py -c "import sys;print('%d.%d' % sys.version_info[:2])" | Select-Object -First 1).Trim()
        if ($cur -and $cur -ne $pyMM) {
            Warn "A venv usa Python $cur e o atual e $pyMM - recriando a venv."
            Remove-Item -Recurse -Force (Join-Path $Dir 'venv'); $cur = ''
        }
        if (-not (Test-Path $vpy)) {
            Info 'Criando o ambiente virtual...'
            & $py -m venv (Join-Path $Dir 'venv')
            if ($LASTEXITCODE -ne 0) { Die 'Falha ao criar a venv.' }
        }
        & $vpy -m pip install --upgrade pip --disable-pip-version-check -q
        Info 'Instalando bibliotecas (pode demorar na primeira vez)...'
        & $vpy -m pip install --disable-pip-version-check -q -r (Join-Path $Dir 'requirements.termux.txt')
        if ($LASTEXITCODE -ne 0) { Die 'pip falhou nas bibliotecas basicas.' }
        # no Android o Termux fornece estas via pkg; no PC vem do pip
        & $vpy -m pip install --disable-pip-version-check -q 'numpy>=1.26' 'pillow>=10.2' 'scipy>=1.12' 'matplotlib>=3.8'
        if ($LASTEXITCODE -ne 0) { Warn 'Nao consegui instalar numpy/pillow/scipy/matplotlib - algumas rotas podem falhar.' }
        if ($Completo) {
            Info 'Perfil completo: torch CPU + whisper + coqui-tts (grande, aguarde)...'
            & $vpy -m pip install --disable-pip-version-check -q torch==2.5.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cpu
            if ($LASTEXITCODE -eq 0) {
                & $vpy -m pip install --disable-pip-version-check -q faster-whisper==1.2.1 ctranslate2==4.8.2 coqui-tts==0.27.5 transformers==4.57.6
            }
            if ($LASTEXITCODE -ne 0) { Warn 'O perfil completo falhou em algum pacote; o basico segue funcionando.' }
        }
        & $vpy -c "import fastapi,uvicorn,pydantic_settings,httpx" 2>$null
        if ($LASTEXITCODE -ne 0) { Die 'Teste das bibliotecas falhou.' }
        Ok 'Bibliotecas prontas.'

        # ---- .env ----
        if (-not (Test-Path $envPath)) {
            Copy-Item (Join-Path $Dir '.env.example') $envPath
            Ok '.env criado a partir do .env.example.'
        }
        if ($oldHost -eq '0.0.0.0') {
            Set-EnvKey $envPath 'API_REQUIRE_TOKEN' 'true'
            if (-not (Get-EnvKey $envPath 'TOOLS_API_TOKEN')) {
                $b = New-Object byte[] 32
                $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider; $rng.GetBytes($b)
                $tok = [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                Set-EnvKey $envPath 'TOOLS_API_TOKEN' $tok
                Warn "Token gerado (guarde): $tok"
            }
        }
        if (-not $installed) {
            if ($OllamaHost) { Set-EnvKey $envPath 'OLLAMA_HOST' $OllamaHost }
            elseif (-not $SemOllama) {
                Set-EnvKey $envPath 'OLLAMA_HOST' 'http://localhost:11434'
                Set-EnvKey $envPath 'OLLAMA_MODEL' $Modelo
                Set-EnvKey $envPath 'CALL_OLLAMA_MODEL' $Modelo
                Set-EnvKey $envPath 'AD_OLLAMA_MODEL' $Modelo
            }
        }

        Write-Utf8 (Join-Path $Dir '.nexus-install') ("INSTALL_DIR=`"$Dir`"`nINSTALL_HOST=`"$oldHost`"`nINSTALL_PORT=`"$oldPort`"`nINSTALL_PYVER=`"$pyMM`"`nINSTALL_RAW=`"$Raw`"`n")
        Write-Utf8 $locVerFile ("VERSION=$remVer`nSHA256=$remSha`n")
        Write-Launcher $oldHost $oldPort

        # ---- ollama ----
        Step '6/6' 'Ollama e modelo'
        if ($SemOllama) { Info 'Ollama: nada a fazer (-SemOllama).' }
        else {
            $m = Get-EnvKey $envPath 'OLLAMA_MODEL'; if (-not $m) { $m = $Modelo }
            Ensure-Ollama $envPath $m (-not $installed)
        }

        if ($wasRunning) {
            Info 'Reiniciando o servidor...'
            & (Join-Path $Dir 'nexus.cmd') bg
        }
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }

    Say ''
    Ok "Pronto! Nexus-Bridge $remVer em $Dir"
    Say "   Iniciar:      $Dir\nexus.cmd            (primeiro plano)"
    Say "   Em 2o plano:  $Dir\nexus.cmd bg"
    Say "   Parar:        $Dir\nexus.cmd parar"
    Say "   Atualizar:    $Dir\nexus.cmd atualizar"
    Say "   Endereco:     http://${oldHost}:${oldPort}   (docs em /docs)"
    Say "   Config:       $envPath"
}

try { Main } catch { if ($_.Exception.Message) { Write-Host "[X] $($_.Exception.Message)" -ForegroundColor Red } }
