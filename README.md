# antigravity-region-fix

Локальный патч регионального гейта **Antigravity CLI (`agy`)** и бэкендов
Antigravity для Linux и macOS. Позволяет использовать уже авторизованный
Google-аккаунт без VPN, прокси, смены DNS и смены региона аккаунта.

Проверено на `agy 1.5.13` и `agy 1.5.14`, Fedora Linux 45, x86-64,
аккаунт с обычной consumer-авторизацией. Поддержка macOS (Mach-O, включая
universal-бинарники) реализована и покрыта юнит-тестами, но на реальном Mac
ещё не прогонялась — см. раздел 4.1.

## Установка

```bash
git clone https://github.com/sr9ch/antigravity_patcher.git
cd antigravity_patcher

make test        # 22 юнит-теста; установленный agy не обязателен
make install     # ставит ~/.local/bin/agy-region-fix и модуль в ~/.local/lib
```

Без установки всё работает прямо из каталога: `./agy-region-fix status`.

Другие способы:

```bash
pipx install .                     # через pyproject.toml, команда agy-region-fix
make install PREFIX=/usr/local     # системная установка (нужен sudo)
make uninstall                     # убрать саму утилиту
```

`make uninstall` не трогает ни `agy`, ни приложение и не удаляет резервные
копии в `~/.local/share/antigravity-region-fix/`.

---

## 1. Что именно блокирует CLI

Ошибка воспроизводится так:

```console
$ agy -p "Reply with exactly OK"
error: Eligibility check failed: Your current account is not eligible for
Antigravity, because it is not currently available in your location.
$ echo $?
1
```

Диагностика (лог `~/.gemini/antigravity-cli/log/cli-*.log`):

```
I ... keyringAuth: loaded token, ... expired=false
I ... server_oauth.go:221] applyAuthResult: email=..., authMethod=consumer
I ... URL: https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
I ... URL: https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels
W ... server_oauth.go:133] Account ineligible: Your current account is not eligible
      for Antigravity, because it is not currently available in your location.
E ... printmode.go:297] Print mode: eligibility check failed: ...
```

Разбор:

| Слой | Что происходит | Кто решает |
|---|---|---|
| OAuth | токен из keyring валиден, вход выполнен | Google OAuth |
| `loadCodeAssist` | сервер возвращает ineligible-тир с причиной `REGION_OUT_OF_SCOPE` | сервер |
| `fetchAvailableModels` | **успешно**, список моделей приходит | сервер |
| локальный гейт `hasValidAuth` | CLI читает флаг из ответа и **сам** выбирает ветку «недоступно» | **клиент** |
| `streamGenerateContent` | после снятия клиентского гейта **успешно отвечает** | сервер |

То есть блокировка — это **клиентское решение по серверной подсказке**, а не отказ
модельного API. Именно поэтому адресный патч клиента даёт реальную генерацию,
а не просто убирает экран ошибки.

Найденные в бинарнике точки (Go, символы сохранились в pclntab):

* `google3/third_party/jetski/cli/backend/backend.applyIneligibilityURLs`
* `google3/third_party/jetski/cli/backend/backend.IneligibilityFromResult`
* `...handleAuthResult` — гейт обычного CLI;
* `authclient.(*PersonalAuthValidator).Validate` — гейт режима `agy --hub`
  (его использует IDE-расширение).

### Важное ограничение

Патч **не создаёт серверных прав**. Если Google начнёт отклонять сам модельный
запрос (HTTP 400 `FAILED_PRECONDITION`, `User location is not supported for the
API use`, или 403 `PERMISSION_DENIED`), патч это не исправит — CLI честно покажет
серверную ошибку. На проверенном аккаунте таких отказов нет: ответы приходят.

---

## 2. Почему Flow Fix нельзя перенести как есть

Расширение `Fix-Flow-Firefox-0.2.0-signed.xpi` (исходники распакованы и изучены):

* `background.js` перехватывает **JS-бандл** `www.gstatic.com/.../AiSandboxAngularFrontend/...m=_b`
  через `webRequest.filterResponseData`;
* `patch.js` заменяет в бандле `return "/unsupported-country"` на `return!0;`,
  с резервными стратегиями `if(!...)` → `if(false)` и `_.uu(a,31)` → `true`;
* дополнительно отменяет редирект вкладки на `/unsupported-country`.

Это чисто фронтендовая косметика: убирается клиентский редирект, а серверные
проверки Flow остаются. Механизм работает только потому, что Flow — веб-приложение
с JS-бандлом.

У `agy` нет ни JS-бандла, ни настройки вида «region/eligibility» в `settings.json`
(проверено: строки `"region"`, `"location"`, `detected_location` относятся к
телеметрии и Vertex-маршрутизации, а не к гейту). Поэтому единственный эквивалент
браузерного подхода здесь — **адресная правка машинного кода**, что и реализовано.

---

## 3. Что делает патч

Две точечные замены в исполняемых сегментах ELF (x86-64):

**CLI, `handleAuthResult`:**

```asm
; было
test rcx, rcx
je   ...
cmp  byte ptr [rcx+8], 0     ; hasValidAuth
jne  eligible
; стало
test rcx, rcx
je   ...
test rcx, rcx                ; ZF=0, rcx здесь не ноль
nop
jne  eligible                ; всегда уходит в "eligible"
```

**Hub / IDE, `PersonalAuthValidator.Validate`:**

```asm
; было
cmp byte ptr [rax+8], 0
je  ...
; стало
mov byte ptr [rax+8], 1      ; hasValidAuth = true
nop
nop
```

Меняются только эти байты. TLS, сертификаты, сетевые настройки, токены и
учётные данные не затрагиваются. Программа не ходит в сеть.

---

## 4. Установка и использование

```bash
cd ~/Проекты/antigravity-region-fix

./agy-region-fix status      # версия, архитектура, состояние сигнатур, бэкап
./agy-region-fix patch       # применить (создаёт проверенный бэкап)
./agy-region-fix verify      # убедиться, что патч на месте
./agy-region-fix test        # реальный запрос: agy -p "Reply with exactly OK"
./agy-region-fix restore     # вернуть оригинальный бинарник
```

Полезное:

```bash
./agy-region-fix --dry-run patch          # показать смещения и хэши, ничего не писать
./agy-region-fix --path /opt/agy patch    # явный путь
./agy-region-fix --all patch              # + бэкенды приложений (App и IDE)
./agy-region-fix --app patch              # только приложения Antigravity App/IDE
./agy-region-fix backups                  # список резервных копий
./agy-region-fix prune --keep 1           # удалить старые копии (каждая ~200 МБ)
./agy-region-fix gates                    # известные сигнатуры
```

### Antigravity App и IDE

`--app` добавляет к целям:

* `~/.local/opt/antigravity-app/Antigravity-x64/resources/bin/language_server`
  — Go-бэкенд приложения «Google Antigravity App» (версия берётся из
  `resources/app.asar`, сейчас 2.29.0). Патчится гейт `hasValidAuth`
  (`PersonalAuthValidator.Validate`).
* `~/.gemini/bin/agy` — hub-бэкенд, который использует расширение `agy`
  в Antigravity IDE (1.5.2). Патчатся оба гейта.

Electron-бинарник `antigravity` и `antigravity-ide` не трогаются: в них нет
Go-гейта, вся проверка живёт в language_server/hub-бэкенде.

После обновления приложения (автообновление или переустановка) достаточно снова
выполнить `./agy-region-fix --app patch`.

Коды возврата: `0` — успех, `1` — ошибка проверки/теста, `2` — сигнатуры не
найдены или неоднозначны (запись не выполнялась), `3` — бинарник запущен.

### 4.1 macOS

Патчер понимает Mach-O: thin (x86_64 или arm64) и universal (fat) с двумя
слайсами. Каждый слайс сканируется сигнатурами своей архитектуры, поэтому
universal-бинарник патчится целиком за один запуск.

```bash
cd ~/antigravity-region-fix      # или любой каталог, куда скопирован проект
./agy-region-fix status          # покажет контейнер: macho / universal(x64+arm64)
./agy-region-fix patch
./agy-region-fix verify
./agy-region-fix restore
```

Пути по умолчанию: `agy` из `PATH`, `~/.local/bin/agy`, `/usr/local/bin/agy`,
`/opt/homebrew/bin/agy`. Приложение — `/Applications/Antigravity.app/Contents/Resources/bin/language_server`
(и `~/Applications/...`), включается флагом `--app` или `--all`.

**Подпись кода.** Правка байтов ломает исходную подпись Google, а на Apple
Silicon ядро не запускает неподписанный код. Порядок, который применяет патчер
(проверен по upstream RendeRR/QNIX-патчеру):

1. **Снапшот подписи.** Перед первой правкой внутри `.app` сохраняется
   оригинальная подпись в `<App>.app.agysignbak`: главный исполняемый файл,
   `Contents/_CodeSignature/*`, `Contents/CodeResources` + манифест с sha256.
   `restore` возвращает их вместе с оригинальными байтами, поэтому приложение
   остаётся с подписью Google.
2. **Preflight Library Validation.** Если главный бинарник подписан с
   Hardened Runtime (`flags` содержат `0x10000`/`0x2000`), ad-hoc подпись
   сломает загрузку вложенных библиотек и приложение не стартует. В этом
   случае патчер **отказывается** писать, пока не передан
   `--macos-disable-library-validation`; тогда entitlement
   `com.apple.security.cs.disable-library-validation` добавляется только
   главному исполняемому файлу бандла (не framework'ам).
3. **Подпись изнутри наружу**: вложенные `Frameworks`/`Library`, затем
   изменённый бинарник, затем сам бандл — с
   `--preserve-metadata=identifier,entitlements,flags,runtime`, ad-hoc
   (`--sign -`) и без `--timestamp`.
4. **Проверка** `codesign --verify --deep --strict`; при ошибке патчер
   откатывает байты и подпись из бэкапа.
5. **Quarantine** снимается (`xattr -dr com.apple.quarantine`), иначе
   Gatekeeper может заблокировать запуск.

Для standalone CLI (вне `.app`) подписывается только сам бинарник. Отключить
всё это можно флагом `--no-resign`, тогда подпись придётся обновить вручную:

```bash
codesign --force --sign - --timestamp=none ~/.local/bin/agy
```

Цена: нотаризация Google после патча больше не действует — система не
подтверждает, что код пришёл от Google. Это неизбежно при изменении
подписанного бинарника.

**Проверка сигнатур на Mac.** arm64-сигнатуры взяты из upstream и на этой
машине (Linux x86-64) не проверялись. Первый запуск на Mac:

```bash
./agy-region-fix --path /Applications/Antigravity.app/Contents/Resources/bin/language_server status
```

Если для слайса написано `absent` — код гейта в этой сборке отличается (или не
совпал контекст: перед arm64-гейтом CLI обязаны стоять `cbnz x1` и `cbz x0`;
патчер проверяет их, чтобы не зацепить похожие байты). Патчер в этом случае
ничего не запишет (код 2). Пришлите вывод `status` и `uname -m` — сигнатуры
поправлю.

iOS/macOS-специфика: `agy` для macOS ставится тем же установщиком, автообновление
перезаписывает бинарник и снимает патч так же, как на Linux; после обновления
повторите `./agy-region-fix patch`.

---

## 5. Гарантии безопасности

* **Резервная копия** кладётся в
  `~/.local/share/antigravity-region-fix/backups/agy-<версия>-<sha12>.orig`
  вместе с JSON-манифестом (sha256, размер, версия, архитектура, дата).
* **Проверка сигнатур** — только в исполняемых PT_LOAD-сегментах. Патч
  применяется, если сигнатура найдена **ровно один раз**. Ноль, два и более
  совпадений, а также смешанное состояние «частично пропатчено» → отказ без записи.
* **Защита от повторного применения** — повторный `patch` сообщает
  «уже пропатчено» и ничего не пишет.
* **Атомарная запись** — временный файл в том же каталоге, `fsync`, `os.replace`,
  сохранение прав. После записи хэш и состояние гейтов перепроверяются; при
  расхождении автоматически восстанавливается оригинал.
* **Проверка бэкапа** — `restore` принимает только копию, чей sha256 совпадает с
  манифестом, и которая сама не содержит патча.
* **Запущенный процесс** — патч/откат отказываются работать, пока `agy` запущен
  (обход только явным `--force`).
* Никаких токенов в логах, никакой сети, никакой подмены TLS.

---

## 6. Обновления CLI

`agy` умеет обновляться сам (за время работы он обновился с 1.5.13 до 1.5.14).
После обновления патч исчезает — это нормально. Действие:

```bash
./agy-region-fix status      # увидит новую версию и состояние "original"
./agy-region-fix patch       # создаст бэкап новой версии и пропатчит её
```

Сигнатуры не привязаны к абсолютным смещениям, поэтому работают и на 1.5.13, и на
1.5.14 (смещения в них: `cli @ 0x9d09c09`, `hub @ 0x9639eea` — меняются от сборки
к сборке). Если в новой версии код гейта перепишут, патчер откажется писать и
вернёт код `2` — тогда нужно обновить сигнатуры в `GATES`.

---

## 7. Результаты проверки (реальные)

| Шаг | Команда | Результат |
|---|---|---|
| Исходное состояние | `agy -p "Reply with exactly OK"` | ошибка eligibility, exit 1 |
| Патч | `./agy-region-fix patch` | cli @ 0x9d09c12, hub @ 0x9639eea |
| Запуск | `agy --version` | `1.5.14` |
| Модели | `agy models` | Gemini 3.8 Flash, Claude Sonnet 4.6, Claude Opus 4.6, GPT-OSS 120B |
| Запрос 1 | `agy -p "Reply with exactly OK"` | `OK`, exit 0 |
| Запрос 2 | `agy -p "Compute 17*23..."` | `391`, exit 0 |
| Запрос 3 | `agy -p "почему небо синее?"` | развёрнутый ответ по-русски, exit 0 |
| Повторный патч | `./agy-region-fix patch` | «уже пропатчено», exit 0 |
| Откат | `./agy-region-fix restore` | sha256 оригинала совпал |
| После отката | `agy -p ...` | снова ошибка eligibility, exit 1 |

### Antigravity App 2.29.0 (language_server)

| Шаг | Действие | Результат |
|---|---|---|
| Оригинал | запуск приложения | экран «Welcome to Antigravity / Continue with Google», сессия не принимается |
| Патч | `./agy-region-fix --app patch` | hub @ 0x770848a |
| Запуск | приложение | «Hi Kirill», авторизация подхватилась сама |
| Модели | список моделей в UI | Gemini 3.8 Flash (High/Medium/Low), Claude Sonnet 4.6, Claude Opus 4.6, GPT-OSS 120B |
| Запрос 1 | «Reply with exactly OK» | `OK` |
| Запрос 2 | «Compute 17*23…» | `391` |

Проверка выполнялась через CDP самого приложения (без ручных кликов),
ответы получены от модели, а не из кэша.

Авторизация не сбрасывалась: использован существующий токен из keyring,
повторного входа не требовалось.

---

## 8. Файлы

```
antigravity_patcher/
├── agy-region-fix              # Bash-launcher
├── agy_region_fix.py           # патчер (stdlib Python 3.8+)
├── pyproject.toml              # установка через pipx/pip
├── Makefile                    # test / install / uninstall / status
├── LICENSE                     # MIT
├── NOTICE                      # атрибуция upstream
├── README.md
├── .github/workflows/tests.yml # CI: py_compile + тесты на 3.8/3.10/3.12
└── tests/test_patcher.py       # 22 юнит-теста

~/.local/share/antigravity-region-fix/backups/
└── <имя>-<версия>-<sha12>.orig (+ .json)
```

Запуск тестов: `make test` (или `python3 tests/test_patcher.py`).

---

## 9. Честный вывод

На проверенном аккаунте ограничение действительно **клиентское**: сервер сообщает
признак региона в `loadCodeAssist`, но модели и генерация для аккаунта доступны.
Патч снимает локальный гейт, и CLI получает реальные ответы моделей через штатную
инфраструктуру Google — без VPN, прокси и смены региона.

Если на другом аккаунте Google отклонит уже сам модельный запрос, это будет
видно как серверная ошибка 400/403; в таком случае ограничение находится на
стороне сервера и локальным патчем не решается.

---

## 10. Источники и совместимость

* Сигнатуры гейтов и arm64-контекст (`cbnz x1; cbz x0`) сверены с
  [RendeRR/antigravity-patcher](https://github.com/RendeRR/antigravity-patcher)
  (MIT), который в свою очередь основан на
  [QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher).
* Логика macOS-подписи (снапшот подписи бандла, preflight Library Validation,
  подпись изнутри наружу, снятие quarantine) повторяет проверенный там подход;
  реализация и все проверки — в этом проекте.
* Официальное: [google-antigravity/antigravity-cli](https://github.com/google-antigravity/antigravity-cli),
  [antigravity.google/docs](https://antigravity.google/docs/).
* Версии, на которых сверены сигнатуры: CLI 1.5.13, 1.5.14 (Linux x86-64);
  бэкенд IDE 1.5.2; приложение 2.29.0 (language_server).
