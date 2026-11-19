#!/usr/bin/env bash
# ==============================================================================
#  ECOSSISTEMA NEXUS + AETHER — Instalador e Atualizador Automático (Produção)
#
#  Uso direto (um comando):
#    curl -fsSL https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/instalar-ecossistema.sh | bash
#
#  Ou baixado:
#    bash instalar-ecossistema.sh [opcoes]
#
#  Opcoes:
#    --atualizar       Atualiza Nexus e Aether existentes (mantem .env, venv, persona)
#    --forcar          Reinstala mesmo se ja estiver na ultima versao
#    --so-nexus        Instala/atualiza apenas o Nexus-Bridge
#    --so-aether       Instala/atualiza apenas o bot Aether
#    --rede            Abre o Nexus para a rede local (0.0.0.0) com token gerado
#    --ollama-host URL Usa Ollama remoto (ex.: http://192.168.0.10:11434)
#    --sem-ollama      Pula instalacao/configuracao do Ollama
#    --boot            Ativa inicio automatico no Termux:Boot
#    -y, --yes         Modo nao-interativo (aceita padroes automaticamente)
#    -h, --help        Mostra esta ajuda
# ==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "[X] Bash nao encontrado. No Termux rode: pkg update && pkg install -y bash"
        exit 1
    fi
fi
set -u

# ---------------- Configuracoes do Repositorio ----------------
RAW="${NEXUS_RAW:-https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main}"
NEXUS_DIR="${NEXUS_DIR:-$HOME/nexus-bridge}"
AETHER_DIR="${AETHER_DIR:-$HOME/Aether}"
NEXUS_PORT="${NEXUS_PORT:-1666}"

TMP_BASE="${TMPDIR:-${PREFIX:-}/tmp}"
[ -d "$TMP_BASE" ] || TMP_BASE="/tmp"
WORK_DIR="$TMP_BASE/eco_setup.$$"

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1

# ---------------- Flags de Execucao ----------------
MODE="auto"        # auto | update | install
FORCE=0
DO_NEXUS=1
DO_AETHER=1
NET_OPEN=0
OLLAMA_HOST_ARG=""
SKIP_OLLAMA=0
WITH_BOOT=0
YES=0

# ---------------- Interface e Logs ----------------
C_RESET='\033[0m'; C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_MAG='\033[1;35m'
[ -t 1 ] || { C_RESET=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_MAG=''; }

info() { printf "${C_CYAN}[*]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*"; }
die()  { printf "${C_RED}[X]${C_RESET} %s\n" "$*" >&2; exit 1; }
banner() {
    printf "\n${C_MAG}============================================================${C_RESET}\n"
    printf "${C_MAG}  %s${C_RESET}\n" "$1"
    printf "${C_MAG}============================================================${C_RESET}\n\n"
}

cleanup() { rm -rf "$WORK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------- Entrada Interativa Segura (funciona com curl | bash) ----------------
TTY_IN=""
if [ -t 0 ]; then TTY_IN="/dev/stdin"
elif [ -r /dev/tty ] && : </dev/tty 2>/dev/null; then TTY_IN="/dev/tty"; fi

ask_yn() {
    local q="$1" def="$2" ans hint="[s/N]"
    [ "$def" = "s" ] && hint="[S/n]"
    if [ "$YES" -eq 1 ] || [ -z "$TTY_IN" ]; then
        [ "$def" = "s" ]
        return
    fi
    read -r -p "$q $hint " ans <"$TTY_IN" || ans=""
    ans="${ans:-$def}"
    case "$ans" in s|S|y|Y|sim|SIM|Sim) return 0 ;; *) return 1 ;; esac
}

# ---------------- Parse de Argumentos ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|ajuda) usage; exit 0 ;;
        --atualizar)     MODE="update" ;;
        --forcar)        FORCE=1 ;;
        --so-nexus)      DO_NEXUS=1; DO_AETHER=0 ;;
        --so-aether)     DO_NEXUS=0; DO_AETHER=1 ;;
        --rede)          NET_OPEN=1 ;;
        --ollama-host)   [ $# -ge 2 ] || die "--ollama-host exige uma URL."; OLLAMA_HOST_ARG="$2"; shift ;;
        --sem-ollama)    SKIP_OLLAMA=1 ;;
        --boot)          WITH_BOOT=1 ;;
        -y|--yes)        YES=1 ;;
        *)               die "Opcao desconhecida: $1 (use --help)" ;;
    esac
    shift
done

# ---------------- Deteccao de Ambiente ----------------
IS_TERMUX=0
if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ] || [[ "${PREFIX:-}" == *com.termux* ]]; then
    IS_TERMUX=1
fi

bin_dir() {
    if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ]; then
        echo "$PREFIX/bin"
    else
        mkdir -p "$HOME/.local/bin"
        echo "$HOME/.local/bin"
    fi
}

fetch() {
    curl -fsSL --retry 3 --connect-timeout 15 -m "${2:-120}" "$1" -o "$3"
}

env_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || { echo ""; return; }
    grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- | sed -e 's/\r$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

env_set() {
    local file="$1" key="$2" val="$3"
    touch "$file"
    if grep -qE "^${key}=" "$file"; then
        # Escapa barras e & para sed
        local esc_val
        esc_val="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
        sed -i "s|^${key}=.*|${key}=${esc_val}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$val" >> "$file"
    fi
}

# ---------------- 1. Preparacao do Sistema ----------------
bootstrap_system() {
    banner "1/4 - VERIFICANDO AMBIENTE E DEPENDENCIAS"
    mkdir -p "$WORK_DIR"

    if [ "$IS_TERMUX" -eq 1 ]; then
        info "Ambiente detectado: Termux (Android)"
        command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true

        local need_pkgs=""
        for cmd in curl tar sed grep sha256sum base64; do
            command -v "$cmd" >/dev/null 2>&1 || need_pkgs="$need_pkgs $cmd"
        done
        if [ -n "$need_pkgs" ]; then
            info "Instalando utilitarios basicos:$need_pkgs"
            pkg update -y -o Dpkg::Options::=--force-confold >/dev/null 2>&1 || true
            # shellcheck disable=SC2086
            pkg install -y -o Dpkg::Options::=--force-confold $need_pkgs coreutils || die "Falha ao instalar utilitarios basicos."
        fi
    else
        info "Ambiente detectado: Linux / WSL"
        for cmd in curl tar sed grep sha256sum base64 python3; do
            command -v "$cmd" >/dev/null 2>&1 || die "Comando obrigatorio ausente: '$cmd'. Instale-o antes de continuar."
        done
    fi

    # Detecta instalacoes ja existentes para auto-decisao
    NEXUS_EXISTS=0
    AETHER_EXISTS=0
    [ -f "$NEXUS_DIR/.nexus-install" ] || [ -f "$NEXUS_DIR/app/main.py" ] && NEXUS_EXISTS=1
    [ -d "$AETHER_DIR/aether" ] || [ -f "$AETHER_DIR/install_info.json" ] && AETHER_EXISTS=1

    if [ "$MODE" = "auto" ]; then
        if [ "$NEXUS_EXISTS" -eq 1 ] || [ "$AETHER_EXISTS" -eq 1 ]; then
            info "Instalacao existente detectada (Nexus: $NEXUS_EXISTS | Aether: $AETHER_EXISTS)."
            if [ "$YES" -eq 1 ]; then
                MODE="update"
            elif ask_yn "Deseja apenas ATUALIZAR o que ja esta instalado (mantendo .env e dados)?" s; then
                MODE="update"
            else
                MODE="install"
            fi
        else
            MODE="install"
        fi
    fi
    ok "Modo definido: ${MODE^^}"
}

# ---------------- 2. Instalar / Atualizar Nexus-Bridge ----------------
run_nexus() {
    [ "$DO_NEXUS" -eq 1 ] || return 0
    banner "2/4 - NEXUS-BRIDGE (Servidor de Ferramentas & IA)"

    local nx_script="$WORK_DIR/install-nexus.sh"
    info "Baixando instalador oficial do Nexus-Bridge..."
    fetch "$RAW/install-nexus.sh" 60 "$nx_script" || die "Nao foi possivel baixar install-nexus.sh de $RAW"
    chmod +x "$nx_script"

    local nx_args=(--dir "$NEXUS_DIR" --porta "$NEXUS_PORT")
    [ "$FORCE" -eq 1 ] && nx_args+=(--forcar)
    [ "$YES" -eq 1 ] && nx_args+=(--yes)
    [ "$NET_OPEN" -eq 1 ] && nx_args+=(--rede)
    [ "$WITH_BOOT" -eq 1 ] && nx_args+=(--boot)

    if [ "$SKIP_OLLAMA" -eq 1 ]; then
        nx_args+=(--sem-ollama)
    elif [ -n "$OLLAMA_HOST_ARG" ]; then
        nx_args+=(--ollama-host "$OLLAMA_HOST_ARG")
    fi

    if [ "$MODE" = "update" ] && [ "$NEXUS_EXISTS" -eq 1 ]; then
        info "Atualizando codigo e dependencias do Nexus-Bridge em $NEXUS_DIR..."
        NEXUS_RAW="$RAW" bash "$nx_script" "${nx_args[@]}" --atualizar || warn "Atualizacao do Nexus retornou aviso."
    else
        info "Executando instalacao completa do Nexus-Bridge em $NEXUS_DIR..."
        NEXUS_RAW="$RAW" bash "$nx_script" "${nx_args[@]}" || die "Falha na instalacao do Nexus-Bridge."
    fi

    ok "Nexus-Bridge concluido."
}

# ---------------- 3. Instalar / Atualizar Aether ----------------
run_aether() {
    [ "$DO_AETHER" -eq 1 ] || return 0
    banner "3/4 - AETHER (Bot Telegram + IA Local)"

    local ae_script="$WORK_DIR/install-aether.sh"
    info "Baixando pacote instalador do Aether..."
    fetch "$RAW/install-aether.sh" 180 "$ae_script" || die "Nao foi possivel baixar install-aether.sh de $RAW"
    chmod +x "$ae_script"

    # Se for apenas atualizacao e o Aether ja existe, atualiza o codigo + requirements sem refazer perguntas
    if [ "$MODE" = "update" ] && [ "$AETHER_EXISTS" -eq 1 ]; then
        info "Atualizando codigo do bot Aether em $AETHER_DIR (mantendo .env e persona.json)..."
        local was_running=0
        if [ -f "$AETHER_DIR/.bot.pid" ] && kill -0 "$(cat "$AETHER_DIR/.bot.pid" 2>/dev/null)" 2>/dev/null; then
            was_running=1
            bash "$AETHER_DIR/start.sh" stop >/dev/null 2>&1 || true
        fi

        local extract_dir="$WORK_DIR/aether_pkg"
        mkdir -p "$extract_dir"
        sed -n '/^#PAYLOAD_BEGIN$/,/^#PAYLOAD_END$/p' "$ae_script" | sed '1d;$d' | base64 -d 2>/dev/null | tar -xz -C "$extract_dir" 2>/dev/null

        if [ -d "$extract_dir/bot/aether" ]; then
            rm -rf "${AETHER_DIR:?}/aether"
            cp -a "$extract_dir/bot/aether" "$AETHER_DIR/aether"
            cp -f "$extract_dir/bot/requirements.txt" "$AETHER_DIR/requirements.txt"
            cp -f "$extract_dir/bot/.env.example" "$AETHER_DIR/.env.example"

            if [ -x "$AETHER_DIR/venv/bin/python" ]; then
                info "Atualizando dependencias Python do Aether..."
                "$AETHER_DIR/venv/bin/python" -m pip install -q --upgrade -r "$AETHER_DIR/requirements.txt" || warn "Aviso ao atualizar libs do Aether."
            fi
            ok "Codigo do Aether atualizado com sucesso!"
            if [ "$was_running" -eq 1 ]; then
                info "Reiniciando o bot Aether em segundo plano..."
                bash "$AETHER_DIR/start.sh" silent
            fi
            return 0
        else
            warn "Payload embutido nao encontrado; seguindo pelo instalador padrao..."
        fi
    fi

    # Instalacao completa ou reparo interativo
    local ae_args=(--dir "$AETHER_DIR")
    [ "$YES" -eq 1 ] && ae_args+=(--yes)
    [ "$SKIP_OLLAMA" -eq 1 ] && ae_args+=(--skip-ollama)
    [ -n "$OLLAMA_HOST_ARG" ] && ae_args+=(--ollama-url "$OLLAMA_HOST_ARG")

    # Se o Nexus esta instalado localmente, ja repassa o aviso
    if [ -n "$TTY_IN" ] && [ "$YES" -eq 0 ]; then
        bash "$ae_script" "${ae_args[@]}" <"$TTY_IN" || die "Falha na instalacao do Aether."
    else
        bash "$ae_script" "${ae_args[@]}" || die "Falha na instalacao do Aether."
    fi

    ok "Aether concluido."
}

# ---------------- 4. Integracao Automatica Nexus <-> Aether & Atalhos ----------------
integrate_ecosystem() {
    banner "4/4 - INTEGRACAO E ATALHOS DO SISTEMA"

    local bin
    bin="$(bin_dir)"

    # Cria comando global 'aether' se o bot estiver instalado
    if [ -f "$AETHER_DIR/start.sh" ]; then
        cat > "$bin/aether" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    iniciar|start) exec bash "$AETHER_DIR/start.sh" ;;
    bg|silent)     exec bash "$AETHER_DIR/start.sh" silent ;;
    parar|stop)    exec bash "$AETHER_DIR/start.sh" stop ;;
    status)        exec bash "$AETHER_DIR/start.sh" status ;;
    logs)          exec tail -f "$AETHER_DIR/logs/bot.log" ;;
    env)           exec "\${EDITOR:-nano}" "$AETHER_DIR/.env" ;;
    atualizar)     exec bash -c 'curl -fsSL "$RAW/instalar-ecossistema.sh" | bash -s -- --atualizar --so-aether' ;;
    *)             echo "Uso: aether {iniciar|bg|parar|status|logs|env|atualizar}" ;;
esac
EOF
        chmod +x "$bin/aether"
        ok "Comando global criado: 'aether'"
    fi

    # Vincula automaticamente o Nexus ao .env do Aether se ambos existirem
    if [ -f "$NEXUS_DIR/.env" ] && [ -f "$AETHER_DIR/.env" ]; then
        local nx_token nx_port
        nx_token="$(env_get "$NEXUS_DIR/.env" "TOOLS_API_TOKEN")"
        nx_port="$(env_get "$NEXUS_DIR/.nexus-install" "INSTALL_PORT")"
        nx_port="${nx_port:-$NEXUS_PORT}"

        env_set "$AETHER_DIR/.env" "NEXUS_ENABLED" "true"
        env_set "$AETHER_DIR/.env" "NEXUS_URL" "http://127.0.0.1:${nx_port}"
        if [ -n "$nx_token" ]; then
            env_set "$AETHER_DIR/.env" "NEXUS_TOKEN" "$nx_token"
        fi
        ok "Integracao automatica aplicada: Aether -> Nexus (http://127.0.0.1:${nx_port})"
    fi

    # Script de inicializacao conjunta no Termux:Boot se solicitado
    if [ "$WITH_BOOT" -eq 1 ] && [ "$IS_TERMUX" -eq 1 ]; then
        mkdir -p "$HOME/.termux/boot"
        cat > "$HOME/.termux/boot/ecossistema-ia.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
[ -x "$bin/nexus" ] && "$bin/nexus" bg
sleep 3
[ -x "$bin/aether" ] && "$bin/aether" bg
EOF
        chmod +x "$HOME/.termux/boot/ecossistema-ia.sh"
        rm -f "$HOME/.termux/boot/nexus-bridge.sh" 2>/dev/null || true
        ok "Auto-start no boot configurado (~/.termux/boot/ecossistema-ia.sh)"
    fi

    # Verifica se o Nexus precisa ser iniciado agora
    if [ -f "$NEXUS_DIR/termux/nexus.sh" ]; then
        if [ ! -f "$NEXUS_DIR/.run/nexus.pid" ] || ! kill -0 "$(cat "$NEXUS_DIR/.run/nexus.pid" 2>/dev/null)" 2>/dev/null; then
            if ask_yn "Deseja iniciar o servidor Nexus-Bridge em segundo plano agora?" s; then
                NEXUS_HOME="$NEXUS_DIR" bash "$NEXUS_DIR/termux/nexus.sh" bg
            fi
        fi
    fi

    banner "TUDO PRONTO!"
    echo "  Comandos rapidos disponiveis no terminal:"
    [ -x "$bin/nexus" ]  && echo "   • nexus bg | status | logs | env | atualizar"
    [ -x "$bin/aether" ] && echo "   • aether bg | status | logs | env | atualizar"
    echo
    echo "  Para atualizar todo o sistema no futuro com 1 comando:"
    echo "   curl -fsSL $RAW/instalar-ecossistema.sh | bash -s -- --atualizar"
    echo
}

# ---------------- Execucao Principal ----------------
bootstrap_system
run_nexus
run_aether
integrate_ecosystem