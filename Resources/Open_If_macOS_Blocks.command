#!/bin/zsh
# QuitLite — macOS engellerse aç
#
# Bu betik ŞEFFAFTIR ve YALNIZCA /Applications/QuitLite.app için çalışır.
# Yönetici (sudo) yetkisi istemez. Gatekeeper'ı genel olarak KAPATMAZ.
# Başka hiçbir uygulamaya/dosyaya dokunmaz. İnternetten bir şey indirmez.

APP="/Applications/QuitLite.app"

echo "=================================================="
echo " QuitLite — macOS Engellerse Aç"
echo "=================================================="
echo
echo "QuitLite notarize EDİLMEMİŞTİR; çünkü bu yapı ücretli bir Apple"
echo "Developer ID sertifikası olmadan dağıtılmıştır."
echo
echo "Bu betik YALNIZCA şunu yapar:"
echo "  - /Applications/QuitLite.app'ten karantina özniteliğini kaldırır."
echo "  - Gatekeeper'ı genel olarak DEVRE DIŞI BIRAKMAZ."
echo "  - Yönetici (sudo) yetkisi GEREKTİRMEZ."
echo "  - Başka hiçbir uygulamayı veya dosyayı DEĞİŞTİRMEZ."
echo

# Bu betiğin bulunduğu klasör (zsh: :A mutlak yol, :h dizin adı).
SCRIPT_DIR="${0:A:h}"

if [ ! -d "$APP" ]; then
  echo "✗ /Applications klasöründe QuitLite.app bulunamadı."
  echo
  if [ -d "$SCRIPT_DIR/QuitLite.app" ]; then
    echo "QuitLite.app şu an hâlâ DMG'nin (bağlı disk imajının) İÇİNDE."
    echo "Bu betik DMG'deki kopyaya DOKUNMAZ; yalnızca /Applications'a"
    echo "KURULMUŞ uygulamayla çalışır."
    echo
  fi
  echo "Önce QuitLite.app'i DMG penceresindeki Applications kısayoluna"
  echo "sürükleyin (yani /Applications klasörüne kopyalayın), sonra bu"
  echo "betiği yeniden çalıştırın."
  echo
  read "_ans?Kapatmak için Enter'a basın..."
  exit 1
fi

echo "Çalıştırılacak komut (yalnızca bu):"
echo "  xattr -dr com.apple.quarantine \"$APP\""
echo
read "yanit?Devam edilsin mi? (e/h): "
if [[ "$yanit" != "e" && "$yanit" != "E" ]]; then
  echo "İptal edildi. Hiçbir değişiklik yapılmadı."
  echo
  read "_ans?Kapatmak için Enter'a basın..."
  exit 0
fi

# Karantina özniteliği zaten yoksa xattr hata döndürür; bu bir sorun değildir
# (sonuç yine "karantina yok") — bu yüzden çıkış kodu önemsenmez.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
echo "✓ Karantina özniteliği kaldırıldı (varsa)."
echo "→ QuitLite açılıyor…"
open "$APP"
echo
read "_ans?Kapatmak için Enter'a basın..."
