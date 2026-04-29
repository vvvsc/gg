#!/usr/bin/env bash
# sign_and_package.sh — Comprime, firma con GPG y genera manifest.json
# Uso: bash sign_and_package.sh <tag>
# Ejemplo: bash sign_and_package.sh v1.2.0
#
# Requiere: gpg, tar, jq, sha256sum
# La clave GPG debe estar ya importada en el keyring antes de llamar este script.

set -euo pipefail

# ─── Configuración ────────────────────────────────────────────────────────────

TAG="${1:-release}"
STAGING_DIR="_release_staging"
DIST_DIR="_dist"
ARCHIVE_NAME="release-${TAG}.tar.gz"
SIG_NAME="${ARCHIVE_NAME}.sig"
MANIFEST_NAME="manifest.json"
MANIFEST_SIG_NAME="${MANIFEST_NAME}.sig"

# ─── Validaciones ─────────────────────────────────────────────────────────────

if ! command -v gpg &>/dev/null; then
  echo "❌ gpg no está instalado." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "❌ jq no está instalado." >&2
  exit 1
fi

# Verificar que hay al menos una clave secreta disponible
GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null \
  | grep '^sec' | head -1 | awk '{print $2}' | cut -d'/' -f2)

if [ -z "$GPG_KEY_ID" ]; then
  echo "❌ No se encontró ninguna clave GPG secreta importada." >&2
  exit 1
fi

echo "🔑 Usando clave GPG: ${GPG_KEY_ID}"

if [ ! -d "$STAGING_DIR" ]; then
  echo "❌ Directorio de staging '${STAGING_DIR}' no encontrado." >&2
  exit 1
fi

# ─── Preparar directorio de distribución ──────────────────────────────────────

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ─── 1. Comprimir ─────────────────────────────────────────────────────────────

echo "📦 Comprimiendo archivos en ${ARCHIVE_NAME}..."

tar -czf "${DIST_DIR}/${ARCHIVE_NAME}" \
  -C "$(dirname "$STAGING_DIR")" \
  "$(basename "$STAGING_DIR")"

echo "   Tamaño: $(du -sh "${DIST_DIR}/${ARCHIVE_NAME}" | cut -f1)"

# ─── 2. Calcular hashes ───────────────────────────────────────────────────────

echo "🔢 Calculando SHA256..."

ARCHIVE_SHA256=$(sha256sum "${DIST_DIR}/${ARCHIVE_NAME}" | awk '{print $1}')
ARCHIVE_SIZE=$(stat -c%s "${DIST_DIR}/${ARCHIVE_NAME}")

echo "   SHA256: ${ARCHIVE_SHA256}"

# ─── 3. Firmar el archivo comprimido ──────────────────────────────────────────

echo "✍️  Firmando ${ARCHIVE_NAME}..."

gpg --batch --yes \
    --local-user "$GPG_KEY_ID" \
    --detach-sign \
    --armor \
    --output "${DIST_DIR}/${SIG_NAME}" \
    "${DIST_DIR}/${ARCHIVE_NAME}"

SIG_SHA256=$(sha256sum "${DIST_DIR}/${SIG_NAME}" | awk '{print $1}')

echo "   Firma generada: ${SIG_NAME}"

# ─── 4. Generar manifest.json ─────────────────────────────────────────────────

echo "📋 Generando ${MANIFEST_NAME}..."

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Listar los archivos que se incluyen en el tar
FILE_ENTRIES=$(tar -tzf "${DIST_DIR}/${ARCHIVE_NAME}" \
  | grep -v '/$' \
  | sort \
  | jq -R . \
  | jq -s .)

jq -n \
  --arg tag "$TAG" \
  --arg timestamp "$TIMESTAMP" \
  --arg gpg_key_id "$GPG_KEY_ID" \
  --arg archive "$ARCHIVE_NAME" \
  --arg archive_sha256 "$ARCHIVE_SHA256" \
  --argjson archive_size "$ARCHIVE_SIZE" \
  --arg signature "$SIG_NAME" \
  --arg sig_sha256 "$SIG_SHA256" \
  --argjson files "$FILE_ENTRIES" \
  '{
    schema_version: "1.0",
    release: {
      tag: $tag,
      timestamp: $timestamp,
      signed_with: $gpg_key_id
    },
    archive: {
      name: $archive,
      sha256: $archive_sha256,
      size_bytes: $archive_size
    },
    signature: {
      name: $signature,
      sha256: $sig_sha256,
      algorithm: "GPG detached armored (--detach-sign --armor)"
    },
    contents: $files,
    verification: {
      instructions: [
        "1. Importar la clave pública: gpg --import public.asc",
        "2. Verificar la firma: gpg --verify <nombre>.tar.gz.sig <nombre>.tar.gz",
        "3. Si el output dice \"Good signature\", el archivo es auténtico."
      ]
    }
  }' > "${DIST_DIR}/${MANIFEST_NAME}"

echo "   Manifest generado con $(echo "$FILE_ENTRIES" | jq 'length') entradas."

# ─── 5. Firmar el manifest ────────────────────────────────────────────────────

echo "✍️  Firmando ${MANIFEST_NAME}..."

gpg --batch --yes \
    --local-user "$GPG_KEY_ID" \
    --detach-sign \
    --armor \
    --output "${DIST_DIR}/${MANIFEST_SIG_NAME}" \
    "${DIST_DIR}/${MANIFEST_NAME}"

echo "   Firma del manifest: ${MANIFEST_SIG_NAME}"

# ─── Resumen ──────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════"
echo "✅ Paquete listo en '${DIST_DIR}/':"
echo ""
ls -lh "${DIST_DIR}/"
echo ""
echo "Archivos que se subirán al release:"
for f in "${DIST_DIR}"/*; do
  echo "  • $(basename "$f")"
done
echo "═══════════════════════════════════════════════════"
