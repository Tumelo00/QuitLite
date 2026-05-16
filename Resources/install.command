#!/bin/bash
# QuitLite kurulum betiği — QuitLite DMG'sinin içinde "QuitLite Kur.command"
# adıyla gelir. ÇİFT TIKLAYIN: QuitLite'ı /Applications'a kurar, Gatekeeper
# karantina etiketini kaldırır ve uygulamayı açar. Terminale komut yazmanıza,
# kopyala-yapıştır yapmanıza gerek yoktur.

cd "$(dirname "$0")" 2>/dev/null || exit 1
SRC="./QuitLite.app"
DST="/Applications/QuitLite.app"

printf '\n  QuitLite Kurulumu\n  =================\n\n'

if [ ! -d "$SRC" ]; then
  echo "  HATA: QuitLite.app bu betiğin yanında bulunamadı."
  echo "  Bu betiği QuitLite DMG'sinin İÇİNDEN çift tıklayarak çalıştırın."
  echo ""
  read -r -p "  Kapatmak için Enter'a basın… "
  exit 1
fi

echo "  → QuitLite /Applications klasörüne kuruluyor…"
# Eski sürüm varsa kaldır (çalışıyorsa bile güvenli: dosya bağı kaldırılır,
# çalışan süreç etkilenmez), sonra yenisini kopyala.
rm -rf "$DST" 2>/dev/null
if ! ditto "$SRC" "$DST" 2>/dev/null; then
  echo ""
  echo "  /Applications klasörüne yazılamadı (yönetici hesabı gerekebilir)."
  echo "  Elle kurulum: QuitLite.app'i /Applications'a sürükleyin, sonra şu"
  echo "  komutu Terminal'e yapıştırıp Enter'a basın:"
  echo ""
  echo "      xattr -dr com.apple.quarantine /Applications/QuitLite.app"
  echo ""
  read -r -p "  Kapatmak için Enter'a basın… "
  exit 1
fi

echo "  → Gatekeeper karantina etiketi kaldırılıyor…"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null

echo "  → QuitLite açılıyor…"
open "$DST"

printf '\n  ✓ Kurulum tamamlandı. Bu Terminal penceresini kapatabilirsiniz.\n\n'
