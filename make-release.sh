#!/usr/bin/env bash
# ============================================================
#  Gera nexus-termux.tar.gz + nexus-termux.version a partir da pasta do codigo.
#  Rode sempre que mudar o codigo; depois envie os 2 arquivos para o GitHub (branch main).
#
#  Uso:  bash make-release.sh PASTA_DO_CODIGO [pasta-de-saida]
#  A pasta precisa ter app/main.py, requirements.termux.txt, termux/nexus.sh, iniciar.sh e atualizar.sh.
# ============================================================
set -eu
SRC="${1:-}"; OUT="${2:-.}"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "Uso: bash make-release.sh PASTA_DO_CODIGO [pasta-de-saida]"; exit 1; }
for f in app/main.py requirements.termux.txt termux/nexus.sh iniciar.sh atualizar.sh .env.example; do
    [ -e "$SRC/$f" ] || { echo "[X] Faltando em $SRC: $f"; exit 1; }
done
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
chmod +x "$SRC/termux/nexus.sh" "$SRC/iniciar.sh" "$SRC/atualizar.sh"

TGZ="$OUT/nexus-termux.tar.gz"
( cd "$SRC" && tar --sort=name --owner=0 --group=0 --numeric-owner \
    --exclude='__pycache__' --exclude='*.pyc' --exclude='./venv' --exclude='./logs' --exclude='./.run' \
    --exclude='./.env' --exclude='./.kaggle_state.json' --exclude='./workspace' --exclude='./generated_*' \
    --exclude='./.git' -cf - . ) | gzip -n -9 > "$TGZ"

SHA="$(sha256sum "$TGZ" | cut -d' ' -f1)"
VERSION="${NEXUS_VERSION:-$(date -u +%Y.%m.%d.%H%M)}"
printf 'VERSION=%s\nSHA256=%s\n' "$VERSION" "$SHA" > "$OUT/nexus-termux.version"
echo "[OK] $TGZ ($(du -h "$TGZ" | cut -f1))"
echo "[OK] versao $VERSION  sha256 $SHA"
echo "Envie para o GitHub: nexus-termux.tar.gz e nexus-termux.version (e install-nexus.sh se mudou)."
