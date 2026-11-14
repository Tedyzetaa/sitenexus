#!/usr/bin/env bash
# ============================================================
#  NEXUS-BRIDGE - instalador para Termux (Android) - Python 3.11
#
#  Instalar direto do GitHub (um comando):
#    curl -fsSL https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-nexus.sh | bash
#  Com opcoes:
#    curl -fsSL https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-nexus.sh | bash -s -- --boot --porta 1666
#
#  Ou baixado:   bash install-nexus.sh [opcoes]      (bash install-nexus.sh --help)
#
#  O codigo NAO vai embutido: o instalador baixa nexus-termux.tar.gz do repositorio,
#  confere o SHA-256 e instala. E o mesmo caminho usado para atualizar depois.
# ============================================================
if [ -z "${BASH_VERSION:-}" ]; then
    echo "[X] Rode com bash:  curl -fsSL <url> | bash   (no Termux: pkg install bash)"; exit 1
fi
set -u

RAW="${NEXUS_RAW:-https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main}"
PKG_NAME="nexus-termux.tar.gz"
VER_NAME="nexus-termux.version"
TMP_BASE="${TMPDIR:-${PREFIX:-}/tmp}"
[ -d "$TMP_BASE" ] || TMP_BASE="/tmp"
SETUP="$TMP_BASE/nexus_setup.$$"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8 DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
# indice de wheels prontas para Termux (TUR); vazio/ja definido pelo usuario = respeitado
export PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL-https://termux-user-repository.github.io/pypi/}"

# ---------------- padroes (mude por opcao) ----------------
PYVER="3.11"
DIR="$HOME/nexus-bridge"
PORT=1666              # Android nao deixa o Termux abrir portas < 1024
HOST="127.0.0.1"       # --rede = 0.0.0.0 (exige token)
OLLAMA_MODE=""         # local | remoto | pular  (vazio = pergunta)
OLLAMA_URL=""
OLLAMA_MODEL_LOCAL="qwen2.5:1.5b-instruct-q4_0"
WITH_FFMPEG=1
WITH_BOOT=0
YES=0
ONLY_CODE=0
FORCE=0
ONLY_CHECK=0
UNINSTALL=0
PYEXE=""
VPY=""
GENERATED_TOKEN=""
TOOLCHAIN_DONE=0
REMOTE_VERSION=""
REMOTE_SHA=""

# ---------------- mensagens ----------------
say()  { printf '%s\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[X] %s\n' "$*" >&2; exit 1; }
step() { printf '\n== [%s] %s\n' "$1" "$2"; }

usage() {
    cat <<'TXT'
Nexus-Bridge - instalador Termux (Python 3.11)

  install-nexus.sh [opcoes]

  --dir PASTA         onde instalar (padrao: ~/nexus-bridge)
  --porta N           porta do servidor (padrao: 1666; portas < 1024 nao funcionam no Android)
  --python X.Y        versao do Python (padrao: 3.11; o Termux tem 3.10, 3.11 e 3.12 via tur-repo)
  --rede              escuta em 0.0.0.0 (outros aparelhos da rede acessam) e liga API_REQUIRE_TOKEN
  --ollama            instala o Ollama no proprio Termux e baixa um modelo pequeno
  --ollama-host URL   usa o Ollama de outro PC/servidor (ex.: http://192.168.0.10:11434)
  --sem-ollama        nao mexe no Ollama
  --sem-ffmpeg        nao instala o ffmpeg
  --boot              cria o script do Termux:Boot (inicia o Nexus quando o celular liga)
  --verificar         so confere se ha versao nova no GitHub (codigo de saida 10 = ha)
  --atualizar         baixa e instala so a versao nova do codigo (mantem .env, venv, logs)
  --forcar            com --atualizar: reinstala mesmo que ja esteja na ultima versao
  --desinstalar       remove a instalacao (pergunta antes)
  -y, --yes           nao pergunta nada (usa os padroes)
  -h, --help          esta ajuda

Variaveis: NEXUS_RAW (URL base dos arquivos no GitHub), KAGGLE_USERNAME, KAGGLE_KEY, NGROK_AUTHTOKEN
TXT
}

# ---------------- entrada interativa (funciona ate com 'curl | bash') ----------------
TTY_IN=""
if [ -t 0 ]; then TTY_IN="/dev/stdin"
elif [ -r /dev/tty ] && : </dev/tty 2>/dev/null; then TTY_IN="/dev/tty"; fi

tty_ok() { [ "$YES" -eq 0 ] && [ -n "$TTY_IN" ]; }

ask_yn() { # ask_yn "pergunta" s|n   -> 0 = sim
    local q="$1" d="$2" a hint="[s/N]"
    [ "$d" = "s" ] && hint="[S/n]"
    if ! tty_ok; then [ "$d" = "s" ]; return; fi
    read -r -p "$q $hint " a <"$TTY_IN" || a=""
    a="${a:-$d}"
    case "$a" in s|S|y|Y|sim|SIM|Sim) return 0 ;; *) return 1 ;; esac
}

ask_val() { # ask_val "pergunta" [secret]  -> imprime o valor
    local a=""
    tty_ok || { echo ""; return; }
    if [ "${2:-}" = "secret" ]; then
        read -rs -p "$1" a <"$TTY_IN" || a=""; echo >&2
    else
        read -r -p "$1" a <"$TTY_IN" || a=""
    fi
    echo "$a"
}

# ---------------- utilidades ----------------
pkg_install() { # instala pacotes do Termux; se falhar, atualiza o sistema e tenta de novo
    command -v pkg >/dev/null 2>&1 || return 1
    if pkg install -y -o Dpkg::Options::=--force-confold "$@"; then return 0; fi
    warn "Falhou. Atualizando os pacotes do Termux e tentando de novo..."
    pkg upgrade -y -o Dpkg::Options::=--force-confold && pkg install -y -o Dpkg::Options::=--force-confold "$@"
}

bin_dir() {
    if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ]; then echo "$PREFIX/bin"; else echo "$HOME/.local/bin"; fi
}

fetch() { # fetch URL SEGUNDOS DESTINO
    curl -fsSL --retry 3 --connect-timeout 15 -m "$2" "$1" -o "$3"
}

find_python() { # exige exatamente python$PYVER (com ssl e venv)
    PYEXE=""
    local c="python$PYVER" maj="${PYVER%%.*}" min="${PYVER#*.}"
    if command -v "$c" >/dev/null 2>&1 &&
       "$c" -c "import sys,ssl,venv;sys.exit(0 if sys.version_info[:2]==($maj,$min) else 1)" >/dev/null 2>&1; then
        PYEXE="$(command -v "$c")"; return 0
    fi
    return 1
}

install_python() {
    command -v pkg >/dev/null 2>&1 || return 1
    # o python 3.11 nao esta no repositorio principal do Termux: vem do tur-repo
    info "Ativando o tur-repo (repositorio com o Python $PYVER)..."
    pkg_install tur-repo || warn "Nao consegui instalar o tur-repo."
    pkg update -y -o Dpkg::Options::=--force-confold >/dev/null 2>&1 || true
    if pkg_install "python$PYVER"; then return 0; fi
    warn "Tentando de novo permitindo sobrescrever arquivos (conflito com o 'python' padrao)..."
    apt-get install -y -o Dpkg::Options::=--force-overwrite -o Dpkg::Options::=--force-confold "python$PYVER"
}

ensure_toolchain() { # compiladores/libs para quando nao existe wheel pronta
    [ "$TOOLCHAIN_DONE" -eq 1 ] && return 0
    TOOLCHAIN_DONE=1
    info "Instalando ferramentas de compilacao (Rust, clang...)..."
    pkg_install rust binutils clang make cmake ninja pkg-config patchelf libffi openssl \
        libjpeg-turbo libpng freetype libopenblas || warn "Algumas ferramentas falharam."
    [ -d /system/lib64 ] && export LDFLAGS="-L/system/lib64 ${LDFLAGS:-}"
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
    info "Compilar pode levar de 10 a 40 minutos no celular - deixe a tela ligada."
}

pip_with_fallback() { # 1o so wheels prontas; se faltar, instala o toolchain e deixa o pip compilar
    if "$VPY" -m pip install --only-binary=:all: "$@"; then return 0; fi
    warn "Sem wheel pronta para alguma biblioteca - vou compilar."
    ensure_toolchain
    "$VPY" -m pip install --prefer-binary "$@"
}

envget() { # envget CHAVE -> valor atual do .env ("" se nao existe)
    [ -f "$DIR/.env" ] || { echo ""; return; }
    grep -E "^$1=" "$DIR/.env" | tail -n1 | cut -d= -f2- | sed -e 's/\r$//' -e 's/^"//' -e 's/"$//'
}

envset() { # envset CHAVE VALOR -> troca a linha CHAVE= do .env (ou acrescenta no fim)
    "$PYEXE" - "$DIR/.env" "$1" "$2" <<'PY'
import os, re, sys
path, key, val = sys.argv[1:4]
if re.search(r'[\s#"\']', val):
    val = '"' + val.replace('\\', '\\\\').replace('"', '\\"') + '"'
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
out, done = [], False
for ln in lines:
    if not done and re.match(r'^%s=' % re.escape(key), ln):
        out.append('%s=%s' % (key, val)); done = True
    else:
        out.append(ln)
if not done:
    out.append('%s=%s' % (key, val))
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
PY
}

cleanup() { rm -rf "$SETUP" 2>/dev/null; }

# le o arquivo de versao baixado (preenche REMOTE_VERSION / REMOTE_SHA)
read_remote_version() {
    mkdir -p "$SETUP"
    fetch "$RAW/$VER_NAME" 30 "$SETUP/version" ||
        die "Nao consegui baixar $RAW/$VER_NAME (sem internet, ou o arquivo nao esta no repositorio)."
    REMOTE_VERSION="$(grep -E '^VERSION=' "$SETUP/version" | head -n1 | cut -d= -f2- | tr -d '\r')"
    REMOTE_SHA="$(grep -E '^SHA256=' "$SETUP/version" | head -n1 | cut -d= -f2- | tr -d '\r ')"
    [ "${#REMOTE_SHA}" -eq 64 ] || die "Arquivo $VER_NAME invalido (SHA256 ausente)."
}

local_sha() { grep -E '^SHA256=' "$DIR/.nexus-version" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r '; }
local_ver() { grep -E '^VERSION=' "$DIR/.nexus-version" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r'; }

download_release() { # baixa, confere o SHA-256 e extrai em $SETUP/src
    info "Baixando $PKG_NAME ($REMOTE_VERSION)..."
    fetch "$RAW/$PKG_NAME" 900 "$SETUP/pkg.tgz" || die "Falha ao baixar $RAW/$PKG_NAME"
    local got; got="$(sha256sum "$SETUP/pkg.tgz" | cut -d' ' -f1)"
    if [ "$got" != "$REMOTE_SHA" ]; then
        die "SHA-256 nao confere (o GitHub pode estar servindo um arquivo em cache). Espere ~5 min e rode de novo."
    fi
    mkdir -p "$SETUP/src"
    tar -xzf "$SETUP/pkg.tgz" -C "$SETUP/src" || die "Falha ao extrair o pacote."
    [ -f "$SETUP/src/app/main.py" ] && [ -f "$SETUP/src/requirements.termux.txt" ] ||
        die "Pacote incompleto (faltam app/main.py ou requirements.termux.txt)."
    ok "Pacote baixado e verificado."
}

main() {
    trap cleanup EXIT

    # ---------------- argumentos ----------------
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help|ajuda) usage; exit 0 ;;
            --dir)         [ $# -ge 2 ] || die "--dir precisa de um valor."; DIR="$2"; shift ;;
            --porta)       [ $# -ge 2 ] || die "--porta precisa de um valor."; PORT="$2"; shift ;;
            --python)      [ $# -ge 2 ] || die "--python precisa de um valor (ex.: 3.11)."; PYVER="$2"; shift ;;
            --rede)        HOST="0.0.0.0" ;;
            --ollama)      OLLAMA_MODE="local" ;;
            --ollama-host) [ $# -ge 2 ] || die "--ollama-host precisa de uma URL."; OLLAMA_MODE="remoto"; OLLAMA_URL="$2"; shift ;;
            --sem-ollama)  OLLAMA_MODE="pular" ;;
            --sem-ffmpeg)  WITH_FFMPEG=0 ;;
            --boot)        WITH_BOOT=1 ;;
            --verificar)   ONLY_CHECK=1 ;;
            --atualizar)   ONLY_CODE=1 ;;
            --forcar)      FORCE=1 ;;
            --desinstalar) UNINSTALL=1 ;;
            -y|--yes)      YES=1 ;;
            *) usage; die "Opcao desconhecida: $1" ;;
        esac
        shift
    done
    case "$PORT" in ''|*[!0-9]*) die "Porta invalida: $PORT" ;; esac
    [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "Use uma porta entre 1024 e 65535 (o Android bloqueia as menores)."
    case "$PYVER" in 3.[0-9]|3.[0-9][0-9]) ;; *) die "Versao do Python invalida: $PYVER (use algo como 3.11)." ;; esac

    IS_TERMUX=0
    if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ]; then IS_TERMUX=1; fi
    case "${PREFIX:-}" in *com.termux*) IS_TERMUX=1 ;; esac

    for t in tar sed grep curl sha256sum; do
        command -v "$t" >/dev/null 2>&1 || die "Comando '$t' nao encontrado. No Termux:  pkg install $t"
    done

    # ---------------- modos rapidos ----------------
    if [ "$ONLY_CHECK" -eq 1 ]; then
        [ -f "$DIR/.nexus-install" ] || die "Nao achei uma instalacao do Nexus em $DIR."
        read_remote_version
        if [ "$(local_sha)" = "$REMOTE_SHA" ]; then
            ok "Nexus-Bridge esta na ultima versao ($(local_ver))."; exit 0
        fi
        warn "Ha versao nova: ${REMOTE_VERSION} (instalada: $(local_ver || true)). Rode:  nexus atualizar"
        exit 10
    fi

    if [ "$UNINSTALL" -eq 1 ]; then
        [ -f "$DIR/.nexus-install" ] || die "Nao achei uma instalacao do Nexus em $DIR."
        warn "Isto apaga $DIR inteira (inclui .env, venv, logs e videos gerados)."
        [ "$YES" -eq 1 ] || ask_yn "Apagar mesmo?" n || { say "Cancelado."; exit 0; }
        NEXUS_HOME="$DIR" bash "$DIR/termux/nexus.sh" parar >/dev/null 2>&1
        rm -rf "$DIR" "$(bin_dir)/nexus" "$HOME/.termux/boot/nexus-bridge.sh"
        ok "Nexus-Bridge removido. (Pacotes do Termux como python/ollama ficaram; remova com 'pkg uninstall' se quiser.)"
        exit 0
    fi

    # ---------------- cabecalho ----------------
    echo
    echo " ============================================================"
    if [ "$ONLY_CODE" -eq 1 ]; then echo "   NEXUS-BRIDGE - atualizacao"; else echo "   NEXUS-BRIDGE - instalador (Termux / Android, Python $PYVER)"; fi
    echo " ============================================================"
    echo

    if [ "$IS_TERMUX" -eq 0 ]; then
        warn "Nao parece ser o Termux. Vou tentar mesmo assim (precisa de python$PYVER com venv/pip)."
    fi

    # ---------------- modo atualizar: confere antes de baixar ----------------
    if [ "$ONLY_CODE" -eq 1 ]; then
        [ -f "$DIR/.nexus-install" ] || die "Nao achei uma instalacao em $DIR. Rode o instalador sem --atualizar."
        # reaproveita o que a instalacao gravou (versao do Python, repositorio)
        # shellcheck disable=SC1091
        . "$DIR/.nexus-install"
        [ -n "${INSTALL_PYVER:-}" ] && PYVER="$INSTALL_PYVER"
        HOST="${INSTALL_HOST:-$HOST}"; PORT="${INSTALL_PORT:-$PORT}"
        # migra as portas antigas (666/8666) para a 1666 fixa
        case "$PORT" in 666|8666)
            info "Porta antiga $PORT -> 1666 (lembre de apontar o bot para http://127.0.0.1:1666)."
            PORT=1666
            sed -i "s/^INSTALL_PORT=.*/INSTALL_PORT=\"1666\"/" "$DIR/.nexus-install" ;;
        esac
        read_remote_version
        if [ "$FORCE" -eq 0 ] && [ "$(local_sha)" = "$REMOTE_SHA" ]; then
            ok "Ja esta na ultima versao ($(local_ver)). Use --forcar para reinstalar mesmo assim."
            exit 0
        fi
        info "Versao instalada: $(local_ver || echo desconhecida)  ->  nova: $REMOTE_VERSION"
    else
        AVAIL_KB="$(df -Pk "$HOME" 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4)"
        case "$AVAIL_KB" in ''|*[!0-9]*) ;; *)
            [ "$AVAIL_KB" -lt 1500000 ] && warn "Pouco espaco livre ($((AVAIL_KB / 1024)) MB). Recomendo >= 1,5 GB." ;;
        esac

        # ---------------- perguntas rapidas (antes da parte demorada) ----------------
        if [ "$HOST" = "127.0.0.1" ] && tty_ok; then
            say "Por padrao so este celular enxerga o Nexus (127.0.0.1)."
            if ask_yn "Liberar acesso para outros aparelhos da rede (ex.: o bot rodando no PC)?" n; then HOST="0.0.0.0"; fi
        fi

        if [ -z "$OLLAMA_MODE" ]; then
            if tty_ok; then
                echo
                echo "Ollama (LLM do chat, roteiros e refinamento dos prompts de video):"
                echo "  1) instalar aqui no Termux (so modelos pequenos; gasta RAM e bateria)"
                echo "  2) usar o Ollama de outro PC/servidor (informar a URL)"
                echo "  3) pular por enquanto (o video via Kaggle com prompt direto funciona sem ele)"
                read -r -p "Escolha [3]: " _c <"$TTY_IN" || _c=""
                case "${_c:-3}" in
                    1) OLLAMA_MODE="local" ;;
                    2) OLLAMA_MODE="remoto"; OLLAMA_URL="$(ask_val 'URL do Ollama (ex.: http://192.168.0.10:11434): ')" ;;
                    *) OLLAMA_MODE="pular" ;;
                esac
            else
                OLLAMA_MODE="pular"
            fi
        fi
        if [ "$OLLAMA_MODE" = "remoto" ] && [ -z "$OLLAMA_URL" ]; then
            warn "URL do Ollama vazia - deixando o padrao do .env.example."; OLLAMA_MODE="pular"
        fi

        EX_KUSER="$(envget KAGGLE_USERNAME)"
        EX_KKEY="$(envget KAGGLE_KEY)"; [ -n "$EX_KKEY" ] || EX_KKEY="$(envget KAGGLE_API_TOKEN)"
        EX_NGROK="$(envget NGROK_AUTHTOKEN)"
        NEW_KUSER="${KAGGLE_USERNAME:-}"
        NEW_KKEY="${KAGGLE_KEY:-${KAGGLE_API_TOKEN:-}}"
        NEW_NGROK="${NGROK_AUTHTOKEN:-}"
        if tty_ok && { [ -z "$NEW_KUSER$EX_KUSER" ] || [ -z "$NEW_KKEY$EX_KKEY" ] || [ -z "$NEW_NGROK$EX_NGROK" ]; }; then
            echo
            echo "Credenciais do video remoto (Enter = deixar em branco e preencher depois com: nexus env)."
            [ -z "$NEW_KUSER$EX_KUSER" ] && NEW_KUSER="$(ask_val 'Usuario do Kaggle: ')"
            [ -z "$NEW_KKEY$EX_KKEY" ]   && NEW_KKEY="$(ask_val 'Chave/token do Kaggle (nao aparece ao digitar): ' secret)"
            [ -z "$NEW_NGROK$EX_NGROK" ] && NEW_NGROK="$(ask_val 'Authtoken do ngrok (nao aparece ao digitar): ' secret)"
        fi
        HAVE_KUSER="${NEW_KUSER:-$EX_KUSER}"; HAVE_KKEY="${NEW_KKEY:-$EX_KKEY}"; HAVE_NGROK="${NEW_NGROK:-$EX_NGROK}"

        read_remote_version
    fi

    # ---------------- 1. baixar o pacote ----------------
    step "1/7" "Baixando o Nexus-Bridge do GitHub"
    download_release

    # ---------------- 2. Python + pacotes do Termux ----------------
    if [ "$ONLY_CODE" -eq 0 ]; then
        step "2/7" "Pacotes do Termux (Python $PYVER, ffmpeg, bibliotecas de imagem...)"
        if command -v pkg >/dev/null 2>&1; then
            info "Atualizando a lista de pacotes..."
            pkg update -y -o Dpkg::Options::=--force-confold >/dev/null 2>&1 || warn "pkg update falhou - seguindo."
            PKGS="curl openssl nano tar libjpeg-turbo libpng freetype libopenblas"
            [ "$WITH_FFMPEG" -eq 1 ] && PKGS="$PKGS ffmpeg"
            info "Instalando: $PKGS"
            # shellcheck disable=SC2086
            pkg_install $PKGS || warn "Alguns pacotes falharam - confira as mensagens acima."
            find_python || install_python || warn "Nao consegui instalar o python$PYVER pelo pkg."
        else
            warn "Comando 'pkg' nao encontrado - pulando. Garanta python$PYVER (venv+pip)."
        fi
        find_python || die "Nao encontrei python$PYVER com venv/ssl. No Termux:  pkg install tur-repo && pkg install python$PYVER"
        ok "Python: $PYEXE ($("$PYEXE" -c 'import sys;print(sys.version.split()[0])'))"
    else
        step "2/7" "Pacotes (pulado: --atualizar)"
        find_python || warn "python$PYVER nao encontrado no PATH (so afeta a conferencia das bibliotecas)."
    fi

    # ---------------- 3. codigo ----------------
    step "3/7" "Copiando o codigo para $DIR"
    mkdir -p "$DIR" || die "Nao consegui criar $DIR."
    WAS_RUNNING=0
    if [ -f "$DIR/.run/nexus.pid" ] && kill -0 "$(cat "$DIR/.run/nexus.pid" 2>/dev/null)" 2>/dev/null; then WAS_RUNNING=1; fi
    # so mexe nas pastas/arquivos do pacote; .env, .kaggle_state.json, venv, logs e generated_* ficam intactos
    while IFS= read -r -d '' e; do
        n="$(basename "$e")"
        rm -rf "${DIR:?}/$n"
        cp -a "$e" "$DIR/$n"
    done < <(find "$SETUP/src" -mindepth 1 -maxdepth 1 -print0)
    chmod +x "$DIR/termux/nexus.sh" "$DIR/iniciar.sh" "$DIR/atualizar.sh" 2>/dev/null
    mkdir -p "$DIR/logs" "$DIR/workspace"
    cp "$SETUP/version" "$DIR/.nexus-version"
    ok "Codigo atualizado ($REMOTE_VERSION)."

    VPY="$DIR/venv/bin/python"

    if [ "$ONLY_CODE" -eq 1 ]; then
        step "4/7" "Conferindo as bibliotecas da versao nova"
        CUR=""
        [ -x "$VPY" ] && CUR="$("$VPY" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
        if [ "$CUR" = "$PYVER" ]; then
            if "$VPY" -m pip install -q --only-binary=:all: -r "$DIR/requirements.termux.txt"; then
                ok "Bibliotecas em dia."
            else
                warn "Nao consegui atualizar as bibliotecas (se o app nao subir, rode o instalador completo de novo)."
            fi
        else
            warn "A venv usa Python ${CUR:-?} e o esperado e $PYVER: rode o instalador completo (sem --atualizar) para recria-la."
        fi
        # as flags de porta/host ficam como estavam
        if [ "$WAS_RUNNING" -eq 1 ]; then
            info "Reiniciando o servidor..."
            NEXUS_HOME="$DIR" bash "$DIR/termux/nexus.sh" reiniciar
        fi
        ok "Atualizado para $REMOTE_VERSION."
        [ "$WAS_RUNNING" -eq 0 ] && echo "    Inicie com:  nexus bg   (ou $DIR/iniciar.sh)"
        exit 0
    fi

    # ---------------- 4. venv + bibliotecas Python ----------------
    step "4/7" "Ambiente Python $PYVER (venv) e bibliotecas"
    if [ -x "$VPY" ]; then
        CUR="$("$VPY" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
        if [ "$CUR" != "$PYVER" ]; then
            info "A venv antiga usa Python ${CUR:-quebrado}; recriando com $PYVER..."
            rm -rf "$DIR/venv"
        fi
    else
        rm -rf "$DIR/venv"
    fi
    if [ -x "$VPY" ]; then
        info "Reaproveitando a venv existente."
    else
        # sem --system-site-packages: as bibliotecas do pkg sao do Python do sistema, nao do $PYVER
        "$PYEXE" -m venv "$DIR/venv" || die "Falha ao criar a venv."
    fi
    if ! "$VPY" -m pip --version >/dev/null 2>&1; then
        info "Instalando o pip na venv..."
        "$VPY" -m ensurepip --upgrade >/dev/null 2>&1 ||
            { curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$VPY" >/dev/null 2>&1; } ||
            die "Nao consegui instalar o pip na venv."
    fi
    "$VPY" -m pip install -q --upgrade pip setuptools wheel >/dev/null 2>&1 || warn "Nao consegui atualizar o pip da venv - seguindo."

    ANDROID_API_LEVEL="$(getprop ro.build.version.sdk 2>/dev/null || true)"
    export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"

    info "Instalando as bibliotecas do servidor (requirements.termux.txt)..."
    pip_with_fallback -r "$DIR/requirements.termux.txt" || die "Falha ao instalar as bibliotecas Python. Veja o erro acima."

    info "Instalando numpy, pillow e matplotlib..."
    pip_with_fallback numpy pillow matplotlib || die "Falha ao instalar numpy/pillow/matplotlib. Veja o erro acima."

    info "Tentando instalar o scipy (opcional)..."
    if ! "$VPY" -m pip install -q --only-binary=:all: scipy; then
        warn "scipy nao instalado (nao ha wheel pronta e compilar exige Fortran). So a dublagem/voz local usa; o resto funciona."
    fi

    MISSING=""
    for m in fastapi uvicorn pydantic pydantic_settings httpx multipart defusedxml numpy PIL matplotlib kaggle; do
        "$VPY" -c "import $m" >/dev/null 2>&1 || MISSING="$MISSING $m"
    done
    if [ -n "$MISSING" ]; then
        die "Nao consegui importar:$MISSING  (rode de novo; se persistir, mande o erro: $VPY -m pip install -r $DIR/requirements.termux.txt numpy pillow matplotlib)"
    fi
    ok "Bibliotecas instaladas."

    # ---------------- 5. configuracao (.env) ----------------
    step "5/7" "Configuracao (.env)"
    FRESH_ENV=0
    if [ ! -f "$DIR/.env" ]; then
        cp "$DIR/.env.example" "$DIR/.env"; FRESH_ENV=1
        info ".env criado a partir do .env.example (perfil lite + video via Kaggle ja vem como padrao)."
    else
        info ".env ja existe - mantendo os seus valores (so ajusto o que foi perguntado agora)."
    fi
    chmod 600 "$DIR/.env"

    [ "$FRESH_ENV" -eq 1 ] && envset OPENHANDS_WORKSPACE "$DIR/workspace"
    [ -n "${NEW_KUSER:-}" ] && envset KAGGLE_USERNAME "$NEW_KUSER"
    if [ -n "${NEW_KKEY:-}" ]; then
        case "$NEW_KKEY" in KGAT_*) envset KAGGLE_API_TOKEN "$NEW_KKEY" ;; *) envset KAGGLE_KEY "$NEW_KKEY" ;; esac
    fi
    [ -n "${NEW_NGROK:-}" ] && envset NGROK_AUTHTOKEN "$NEW_NGROK"

    if [ "$HOST" = "0.0.0.0" ]; then
        envset API_REQUIRE_TOKEN "true"
        if [ -z "$(envget TOOLS_API_TOKEN)" ]; then
            GENERATED_TOKEN="$("$PYEXE" -c 'import secrets;print(secrets.token_urlsafe(32))')"
            envset TOOLS_API_TOKEN "$GENERATED_TOKEN"
        fi
    fi

    case "$OLLAMA_MODE" in
        local)
            envset OLLAMA_HOST "http://localhost:11434"
            envset OLLAMA_MODEL "$OLLAMA_MODEL_LOCAL"
            envset CALL_OLLAMA_MODEL "$OLLAMA_MODEL_LOCAL"
            envset AD_OLLAMA_MODEL "$OLLAMA_MODEL_LOCAL"
            ;;
        remoto)
            envset OLLAMA_HOST "$OLLAMA_URL"
            ;;
    esac

    {
        echo "INSTALL_DIR=\"$DIR\""
        echo "INSTALL_HOST=\"$HOST\""
        echo "INSTALL_PORT=\"$PORT\""
        echo "INSTALL_PYVER=\"$PYVER\""
        echo "INSTALL_RAW=\"$RAW\""
    } >"$DIR/.nexus-install"

    BIN="$(bin_dir)"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexport NEXUS_HOME=%q\nexec bash %q "$@"\n' "$DIR" "$DIR/termux/nexus.sh" >"$BIN/nexus"
    chmod +x "$BIN/nexus"
    case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN nao esta no PATH - rode:  export PATH=\"$BIN:\$PATH\"" ;; esac
    ok "Configuracao salva. Comando 'nexus' criado em $BIN."

    # ---------------- 6. Ollama ----------------
    step "6/7" "Ollama"
    case "$OLLAMA_MODE" in
        local)
            if pkg_install ollama; then
                ok "Ollama instalado."
                if ask_yn "Baixar o modelo $OLLAMA_MODEL_LOCAL agora (~1 GB)?" s; then
                    nohup ollama serve >"$DIR/logs/ollama-install.log" 2>&1 &
                    OPID=$!
                    for _i in $(seq 1 30); do sleep 1; curl -s -f -m 2 -o /dev/null http://127.0.0.1:11434/api/tags && break; done
                    ollama pull "$OLLAMA_MODEL_LOCAL" || warn "Download falhou. Depois rode:  ollama serve &  e  ollama pull $OLLAMA_MODEL_LOCAL"
                    kill "$OPID" 2>/dev/null
                else
                    info "Depois: ollama serve &  e  ollama pull $OLLAMA_MODEL_LOCAL"
                fi
            else
                warn "Nao consegui instalar o Ollama pelo pkg. Use a opcao de Ollama remoto (--ollama-host) ou instale manualmente."
            fi
            ;;
        remoto) ok "Ollama remoto configurado: $OLLAMA_URL" ;;
        *)      info "Ollama: nada a fazer." ;;
    esac

    # ---------------- 7. teste ----------------
    step "7/7" "Teste"
    cd "$DIR" || die "Nao consegui entrar em $DIR."
    if ! NEXUS_PROFILE=lite LOG_TO_FILE=false "$VPY" -c "import app.main" >"$DIR/logs/install-test.log" 2>&1; then
        warn "O app nao importou. Ultimas linhas:"; tail -n 15 "$DIR/logs/install-test.log"
        die "Instalacao incompleta. Log: $DIR/logs/install-test.log"
    fi
    ok "O codigo do Nexus carrega sem erros."

    TEST_PORT=$((PORT + 1))
    "$VPY" -m uvicorn app.main:app --host 127.0.0.1 --port "$TEST_PORT" --no-access-log >>"$DIR/logs/install-test.log" 2>&1 &
    TPID=$!
    CODE=""
    for _i in $(seq 1 45); do
        sleep 1
        CODE="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/health" 2>/dev/null)"
        [ -n "$CODE" ] && [ "$CODE" != "000" ] && break
        CODE=""
        kill -0 "$TPID" 2>/dev/null || break
    done
    kill "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null
    if [ -n "$CODE" ]; then
        ok "Servidor respondeu (HTTP $CODE em /api/health; 503 e normal enquanto Ollama/ComfyUI estiverem offline)."
    else
        warn "O servidor nao respondeu no teste. Veja: $DIR/logs/install-test.log"
    fi

    if [ "$WITH_BOOT" -eq 1 ]; then
        mkdir -p "$HOME/.termux/boot"
        printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\n%s bg\n' "$BIN/nexus" >"$HOME/.termux/boot/nexus-bridge.sh"
        chmod +x "$HOME/.termux/boot/nexus-bridge.sh"
        ok "Script de inicializacao criado (precisa do app Termux:Boot instalado)."
    fi

    # ---------------- final ----------------
    echo
    echo " ============================================================"
    echo "   Instalado em: $DIR   (Python $PYVER, versao $REMOTE_VERSION)"
    echo " ============================================================"
    echo
    echo "  $DIR/iniciar.sh        confere atualizacoes e inicia (aceita 'bg' para segundo plano)"
    echo "  nexus bg               inicia em segundo plano"
    echo "  nexus iniciar          inicia em primeiro plano"
    echo "  nexus verificar        confere se ha versao nova no GitHub"
    echo "  nexus atualizar        baixa e instala a versao nova"
    echo "  nexus status | logs | env | ajuda"
    echo
    echo "  Endereco: http://$HOST:$PORT   (docs em /docs)"
    [ "$HOST" = "127.0.0.1" ] && echo "  Para o bot/Jarvis usar este Nexus, aponte-o para http://127.0.0.1:$PORT (se o bot esta neste celular)."
    if [ -n "$GENERATED_TOKEN" ]; then
        echo
        echo "  Token da API (guarde; o bot precisa mandar no header X-Nexus-Token):"
        echo "  $GENERATED_TOKEN"
    fi
    if [ -z "${HAVE_KUSER:-}" ] || [ -z "${HAVE_KKEY:-}" ] || [ -z "${HAVE_NGROK:-}" ]; then
        echo
        warn "Faltam credenciais do video remoto. Preencha KAGGLE_USERNAME, KAGGLE_KEY e NGROK_AUTHTOKEN com:  nexus env"
    fi
    echo
    echo "  Dica: no Android, desative a otimizacao de bateria do Termux, senao o sistema pode matar o servidor."
    echo
    exit 0
}

main "$@"
