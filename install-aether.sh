#!/usr/bin/env bash
# ============================================================
#  AETHER - instalador/atualizador por link (Termux)
#
#  Instalar ou atualizar (um comando):
#    curl -fsSL https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-aether.sh | bash
#  Com opcoes:
#    curl -fsSL https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main/install-aether.sh | bash -s -- --forcar
#
#  O que faz:
#    - Se o Aether NAO esta instalado: baixa o install.sh e roda a instalacao normal.
#    - Se JA esta instalado: confere se ha versao nova; se nao houver, so informa.
#      Se houver, atualiza o codigo mantendo .env, personalidade e modelo.
#    - Sempre verifica se o modelo do Ollama ja existe (nao baixa de novo).
#  Opcoes: --forcar (reinstala mesmo sem versao nova)   --dir PASTA   --help
# ============================================================
if [ -z "${BASH_VERSION:-}" ]; then echo "[X] Rode com bash:  curl -fsSL <url> | bash"; exit 1; fi
set -u

RAW="${AETHER_RAW:-https://raw.githubusercontent.com/Tedyzetaa/sitenexus/main}"
DIR="$HOME/Aether"
FORCE=0
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --forcar) FORCE=1 ;;
        --dir)    [ $# -ge 2 ] || { echo "[X] --dir precisa de uma pasta."; exit 1; }; DIR="$2"; shift ;;
        -h|--help) sed -n '2,19p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) EXTRA+=("$1") ;;
    esac
    shift
done

say(){ printf '[*] %s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }
die(){ printf '[X] %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || { command -v pkg >/dev/null 2>&1 && pkg install -y curl || die "Instale o curl."; }

TMP_BASE="${TMPDIR:-${PREFIX:-}/tmp}"; [ -d "$TMP_BASE" ] || TMP_BASE="/tmp"
WORK="$TMP_BASE/aether_link.$$"; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
INST="$WORK/install.sh"

say "Baixando o instalador do Aether..."
curl -fsSL "$RAW/install.sh" -o "$INST" || die "Nao consegui baixar $RAW/install.sh"
[ -s "$INST" ] || die "Arquivo baixado esta vazio."
sha256sum "$INST" >/dev/null 2>&1 || die "sha256sum nao encontrado (pkg install coreutils)."
NEW_SHA="$(sha256sum "$INST" | cut -d' ' -f1)"
STAMP="$DIR/.aether-installer.sha"
OLD_SHA=""; [ -f "$STAMP" ] && OLD_SHA="$(cat "$STAMP" 2>/dev/null)"

# ---------- verificacao do modelo do Ollama ----------
check_model() {
    local url="http://localhost:11434" mdl=""
    if [ -f "$DIR/.env" ]; then
        local h m
        h="$(grep -E '^OLLAMA_HOST=' "$DIR/.env" | head -n1 | cut -d= -f2- | tr -d '\r"' )"
        m="$(grep -E '^OLLAMA_MODEL=' "$DIR/.env" | head -n1 | cut -d= -f2- | tr -d '\r"' )"
        [ -n "$h" ] && url="${h%/}"; mdl="$m"
    fi
    if ! curl -sf -m 3 "$url/api/tags" -o "$WORK/tags.json"; then
        warn "Ollama nao esta respondendo em $url (o instalador tenta iniciar/instalar)."; return 1
    fi
    if [ -n "$mdl" ] && grep -qF "\"$mdl" "$WORK/tags.json"; then
        ok "Modelo '$mdl' ja instalado no Ollama - nao precisa baixar de novo."; return 0
    fi
    local lista; lista="$(grep -o '"name":"[^"]*"' "$WORK/tags.json" | cut -d'"' -f4 | tr '\n' ' ')"
    warn "Modelo '${mdl:-?}' nao encontrado. Modelos presentes: ${lista:-nenhum}. O instalador baixa o que faltar."
    return 1
}

INSTALLED=0
[ -f "$DIR/install_info.json" ] && INSTALLED=1

if [ "$INSTALLED" -eq 1 ]; then
    ok "Aether ja instalado em $DIR."
    check_model || true
    if [ "$FORCE" -eq 0 ] && [ -n "$OLD_SHA" ] && [ "$OLD_SHA" = "$NEW_SHA" ]; then
        ok "Ja esta na ultima versao. Nada a atualizar (use --forcar para reinstalar)."
        exit 0
    fi
    say "Atualizando (config, .env e modelo sao mantidos)..."
    bash "$INST" --yes --dir "$DIR" ${EXTRA[@]+"${EXTRA[@]}"}
else
    say "Primeira instalacao do Aether."
    check_model || true
    bash "$INST" --dir "$DIR" ${EXTRA[@]+"${EXTRA[@]}"}
fi
RC=$?

if [ "$RC" -eq 0 ] && [ -d "$DIR" ]; then
    printf '%s' "$NEW_SHA" > "$STAMP" 2>/dev/null || true
    ok "Pronto. Iniciar:  cd $DIR && bash start.sh"
fi
exit "$RC"
