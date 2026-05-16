# QuitLite

Son penceresi kapanan macOS uygulamalarını otomatik olarak kapatan, aşırı hafif
bir araç. "Last Window Quits" benzeri; arka plan çekirdeği yalnızca **~2.3 MB RAM**
kullanır, kurulu boyutu **~180 KB**, DMG ise **~72 KB**.

## Mimari

Tek bir binary, iki modda çalışır:

- **Çekirdek modu** (`QuitLite --core`) — `NSApplication` yok, menü çubuğu yok,
  dock yok, ikon yok. Tüm izleme ve kapatma işini yapar. **~2.3 MB**, sürekli
  çalışır. `launchd` yönetir: girişte başlar, çökerse yeniden başlatılır,
  `ProcessType=Background` ile düşük öncelikli çalışır.
- **Ayar penceresi modu** (varsayılan) — yalnızca `QuitLite.app`'i açınca çalışır;
  pencere kapanınca süreç sonlanır. Arka planda iz bırakmaz.

`NSApplication` (menü çubuğu/GUI altyapısı) ~10 MB taban maliyeti getirir;
çekirdek bunu hiç yüklemediği için ~2.3 MB'de kalır. İki mod aynı binary olduğu
için tek bir Erişilebilirlik (TCC) kimliği paylaşır.

İki süreç ayrı bir IPC katmanı olmadan, paylaşılan bir `UserDefaults` suite
üzerinden haberleşir.

## Enerji optimizasyonu (UI kapalıyken)

- İzin yoklaması: izin verilene kadar 3 sn, verildikten sonra 300 sn.
- Emniyet taraması: 10 sn, geniş tolerans ile macOS uyanmalarına denk getirilir.
- Asıl algılama olay tabanlıdır (AX observer + NSWorkspace) — sistem boştayken
  ek uyanma olmaz.

## Özellikler

- Accessibility API (`AXObserver`) tabanlı pencere takibi.
- Kara liste / izin listesi modları.
- Ayarlanabilir kapatma gecikmesi (0–30 sn).
- Girişte otomatik başlama (`~/Library/LaunchAgents` + `launchctl`).
- Yanlış kapatmaya karşı koruma: gecikme + çift yeniden doğrulama + emniyet taraması.
- İsteğe bağlı menü çubuğu simgesi (ayarları açma / QuitLite'tan çıkma için).
  Açıkken çekirdek `NSApplication` ile çalışır (~10 MB); kapalıyken hafif moddadır.

## Derleme

```bash
./build.sh
```

Çıktı: `QuitLite.app` ve dağıtım için tek bir `QuitLite.dmg`.
Gereksinim: Swift 5.9+ ve Xcode komut satırı araçları.

## Kurulum

1. `QuitLite.dmg`'yi açın, `QuitLite.app`'i `/Applications`'a sürükleyin.
2. İlk açılışta Gatekeeper uyarısı çıkarsa: sağ tık → **Aç**, ya da
   `xattr -dr com.apple.quarantine /Applications/QuitLite.app`.
3. `QuitLite.app`'i açın — ayar penceresi gelir, arka plan çekirdeği kurulur.
4. Sistem Ayarları → Gizlilik ve Güvenlik → **Erişilebilirlik** altında
   **QuitLite**'a izin verin. Listede görünmüyorsa **+** düğmesiyle
   `QuitLite.app`'i ekleyip anahtarını açın.

Ayarları sonradan değiştirmek için yine `QuitLite.app`'i açın.

## Notlar

- Accessibility API gerektirdiği için App Store dışında dağıtılır.
- **Kalıcı Erişilebilirlik izni — kendinden imzalı sertifika:** Ad-hoc imza her
  derlemede kod karmasını (cdhash) değiştirir; TCC izni koda bağlı olduğu için
  her derlemede izni yeniden vermeniz gerekir. Bir kez kendinden imzalı sertifika
  oluşturursanız imza sabitlenir → izni bir kez verir, her derlemede korursunuz.

  Sertifikayı bir kez oluşturun:
  1. **Anahtar Zinciri Erişimi**'ni açın.
  2. Menü çubuğu → **Anahtar Zinciri Erişimi → Sertifika Yardımcısı →
     Sertifika Oluştur…**
  3. **Ad:** `QuitLite Self-Signed` · **Kimlik Türü:** Kendinden İmzalı Kök ·
     **Sertifika Türü:** Kod İmzalama → **Oluştur**.

  Sertifika ve özel anahtarı **giriş (login) anahtar zincirinde** bulunmalıdır;
  `security find-identity -p codesigning` yalnızca özel anahtarına erişilebilen
  kimlikleri listeler. Sertifikayı dışa aktarıp başka makineye taşırsanız özel
  anahtarı da (`.p12`) içermesine dikkat edin, yoksa imzalama ad-hoc'a düşer.

  `build.sh` artık adında "QuitLite" geçen kod imzalama kimliğini otomatik bulup
  onunla imzalar; bulamazsa ad-hoc imzaya düşer. Başka bir kimlik için:
  `QUITLITE_SIGN_ID="…" ./build.sh`.
- Varsayılan kara liste, pencere kapansa da arka planda kalması gereken
  uygulamaları (VPN'ler, LuLu, Amphetamine, Finder vb.) içerir.

## Lisans

MIT
