#!/usr/bin/env bash
# ==============================================================================
#  PUBLICAR RELEASE — Empacota Nexus-Bridge e/ou Aether para o GitHub (main)
#
#  Uso:
#    bash publicar-release.sh --nexus /caminho/nexus-bridge --aether /caminho/aether --out ./sitenexus
#    bash publicar-release.sh --nexus ./nexus-bridge --out .
#    bash publicar-release.sh --aether ./aether --out .
# ==============================================================================
set -euo pipefail

NEXUS_SRC=""
AETHER_SRC=""
OUT_DIR="."
VERSION="${RELEASE_VERSION:-$(date -u +%Y.%m.%d.%H%M)}"

info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
die()  { printf '[X] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --nexus)   [ $# -ge 2 ] || die "--nexus exige caminho"; NEXUS_SRC="$2"; shift ;;
        --aether)  [ $# -ge 2 ] || die "--aether exige caminho"; AETHER_SRC="$2"; shift ;;
        --out)     [ $# -ge 2 ] || die "--out exige caminho"; OUT_DIR="$2"; shift ;;
        --version) [ $# -ge 2 ] || die "--version exige valor"; VERSION="$2"; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Opcao desconhecida: $1" ;;
    esac
    shift
done

[ -n "$NEXUS_SRC" ] || [ -n "$AETHER_SRC" ] || die "Informe ao menos --nexus PASTA ou --aether PASTA."
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# ---------------- Empacotar Nexus-Bridge ----------------
if [ -n "$NEXUS_SRC" ]; then
    [ -d "$NEXUS_SRC" ] || die "Pasta do Nexus nao encontrada: $NEXUS_SRC"
    NEXUS_SRC="$(cd "$NEXUS_SRC" && pwd)"

    for f in app/main.py requirements.termux.txt termux/nexus.sh iniciar.sh atualizar.sh .env.example; do
        [ -e "$NEXUS_SRC/$f" ] || die "Arquivo obrigatorio ausente no Nexus: $f"
    done

    chmod +x "$NEXUS_SRC/termux/nexus.sh" "$NEXUS_SRC/iniciar.sh" "$NEXUS_SRC/atualizar.sh"

    TGZ_NX="$OUT_DIR/nexus-termux.tar.gz"
    info "Empacotando Nexus-Bridge ($VERSION)..."
    (
        cd "$NEXUS_SRC" && tar --sort=name --owner=0 --group=0 --numeric-owner \
            --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' \
            --exclude='./venv' --exclude='./.venv' --exclude='./logs' --exclude='./.run' \
            --exclude='./.env' --exclude='./.kaggle_state.json' --exclude='./.nexus-install' \
            --exclude='./.nexus-version' --exclude='./workspace' \
            --exclude='./generated_*' --exclude='./app/generated_*' \
            --exclude='./.git' -cf - .
    ) | gzip -n -9 > "$TGZ_NX"

    SHA_NX="$(sha256sum "$TGZ_NX" | cut -d' ' -f1)"
    printf 'VERSION=%s\nSHA256=%s\n' "$VERSION" "$SHA_NX" > "$OUT_DIR/nexus-termux.version"
    ok "Nexus gerado: $TGZ_NX ($(du -h "$TGZ_NX" | cut -f1)) | SHA256: ${SHA_NX:0:12}..."
fi

# ---------------- Empacotar Aether (Atualiza Payload em install-aether.sh) ----------------
if [ -n "$AETHER_SRC" ]; then
    [ -d "$AETHER_SRC" ] || die "Pasta do Aether nao encontrada: $AETHER_SRC"
    AETHER_SRC="$(cd "$AETHER_SRC" && pwd)"

    [ -f "$AETHER_SRC/installer.py" ] || die "Faltando installer.py em $AETHER_SRC"
    [ -d "$AETHER_SRC/bot/aether" ]   || die "Faltando bot/aether em $AETHER_SRC"
    [ -f "$OUT_DIR/install-aether.sh" ] || die "Coloque o template install-aether.sh em $OUT_DIR antes de empacotar."

    TMP_PAYLOAD="$(mktemp)"
    info "Empacotando Aether ($VERSION) e injetando payload em install-aether.sh..."
    (
        cd "$AETHER_SRC" && tar --sort=name --owner=0 --group=0 --numeric-owner \
            --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' \
            --exclude='*/venv' --exclude='*/logs' --exclude='*/data' \
            --exclude='*/.env' --exclude='*/persona.json' --exclude='*/runtime.json' \
            --exclude='.git' -cf - installer.py bot
    ) | gzip -n -9 | base64 -w 76 > "$TMP_PAYLOAD"

    # Reconstroi install-aether.sh substituindo o bloco entre #PAYLOAD_BEGIN e #PAYLOAD_END
    python3 - "$OUT_DIR/install-aether.sh" "$TMP_PAYLOAD" <<'PY'
import sys
sh_path, pay_path = sys.argv[1], sys.argv[2]
sh_text = open(sh_path, encoding="utf-8").read()
payload = open(pay_path, encoding="utf-8").read().strip()
marker = "#PAYLOAD_BEGIN\n"
idx = sh_text.find(marker)
if idx == -1:
    sys.exit("[X] Marcador #PAYLOAD_BEGIN nao encontrado em install-aether.sh")
header = sh_text[:idx + len(marker)]
open(sh_path, "w", encoding="utf-8", newline="\n").write(f"{header}{payload}\n#PAYLOAD_END\n")
PY
    rm -f "$TMP_PAYLOAD"
    cp -f "$OUT_DIR/install-aether.sh" "$OUT_DIR/install.sh"
    chmod +x "$OUT_DIR/install-aether.sh" "$OUT_DIR/install.sh"

    SHA_AE="$(sha256sum "$OUT_DIR/install-aether.sh" | cut -d' ' -f1)"
    printf 'VERSION=%s\nSHA256=%s\n' "$VERSION" "$SHA_AE" > "$OUT_DIR/aether-termux.version"
    ok "Aether atualizado em: $OUT_DIR/install-aether.sh (e install.sh)"
fi

echo
ok "Pronto para git add / git commit / git push na branch main!"