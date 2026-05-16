#!/bin/bash
# QuitLite'ı derler, .app paketini ve tek bir DMG'yi oluşturur.
# Tek binary iki modda çalışır: ayar penceresi (varsayılan) ve "--core" çekirdeği.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="release"

echo "→ Derleniyor ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="QuitLite.app"
echo "→ $APP paketleniyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/QuitLite"      "$APP/Contents/MacOS/QuitLite"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Semboller temizleniyor…"
strip -x "$APP/Contents/MacOS/QuitLite"

# Kalıcı Erişilebilirlik (TCC) izni için kendinden imzalı bir sertifikayla imzala.
# Ad-hoc imza her derlemede cdhash'i değiştirir → TCC izni sıfırlanır ve her
# derlemede izni yeniden vermek gerekir. Kendinden imzalı sabit bir sertifika
# değişmez bir "designated requirement" üretir → izin bir kez verilir, korunur.
#
# Sertifikayı BİR KEZ oluşturun (ayrıntılar README "Notlar" bölümünde):
#   Anahtar Zinciri Erişimi → menü: Sertifika Yardımcısı → Sertifika Oluştur…
#     Ad:              QuitLite Self-Signed
#     Kimlik Türü:     Kendinden İmzalı Kök
#     Sertifika Türü:  Kod İmzalama
# build.sh adında "QuitLite" geçen kod imzalama kimliğini otomatik bulur.
# Farklı bir kimlik kullanmak için:  QUITLITE_SIGN_ID="…" ./build.sh
SIGN_ID="${QUITLITE_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  # find-identity satırları:  1) <SHA1> "Kimlik Adı"
  # Tırnaklar arasındaki adı, içinde "QuitLite" geçenden çıkar. Tırnak içermeyen
  # bir desen kullanılır ki açgözlü .* yanlış alana taşmasın.
  # head -n1 boş çıktıda da 0 döner → set -e/pipefail derlemeyi durdurmaz.
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
             | sed -n 's/^[^"]*"\([^"]*QuitLite[^"]*\)".*/\1/p' | head -n1)"
fi
if [ -n "$SIGN_ID" ]; then
  echo "→ Kendinden imzalı sertifikayla imzalanıyor: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" "$APP"
else
  echo "→ Kendinden imzalı sertifika bulunamadı — ad-hoc imzalanıyor."
  echo "  (Kalıcı izin için README 'Notlar' bölümündeki sertifika adımlarını izleyin.)"
  codesign --force --sign - "$APP"
fi

echo "→ DMG oluşturuluyor…"
DMG="QuitLite.dmg"
rm -f "$DMG"
# DMG'yi bir hazırlık klasöründen oluştur: .app'in yanına /Applications
# kısayolu koy ki kullanıcı DMG'yi açınca uygulamayı doğrudan oraya
# sürükleyebilsin (aksi halde DMG'de yalnızca .app görünür, sürüklenecek
# hedef olmaz).
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "QuitLite" -srcfolder "$STAGE" -ov -format UDZO \
  -imagekey zlib-level=9 -quiet "$DMG"
rm -rf "$STAGE"

echo "✓ Hazır:"
echo "  $(pwd)/$APP   ($(du -sh "$APP" | cut -f1))"
echo "  $(pwd)/$DMG   ($(du -sh "$DMG" | cut -f1))"
