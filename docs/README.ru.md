<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Значок приложения Palmos">
  <h1>Palmos</h1>
  <p>Нативное приложение для строки меню macOS, которое контролирует внешние физические накопители.</p>
  <p>
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="../README.md">English</a> ·
    <a href="README.ja.md">日本語</a> ·
    <strong>Русский</strong>
  </p>
</div>

## Что такое Palmos

Palmos показывает состояние подключённых внешних дисков прямо в строке меню. Нативная панель содержит сведения о ёмкости, подключённых томах, интерфейсе подключения, текущей скорости чтения и записи, безопасном извлечении, а также необязательные данные SMART о состоянии и температуре.

Основной объект — внешний физический накопитель. Внутренние диски, сетевые тома, виртуальные носители и подключения iPhone или iPad не отображаются.

## Возможности

<table>
  <tr>
    <td width="32%">
      <strong>Всегда в строке меню</strong><br><br>
      Palmos автоматически обнаруживает USB, Thunderbolt, USB4, SD-карты, внешние SSD, HDD и корпуса NVMe и показывает их в компактной нативной панели.
    </td>
    <td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="Панель Palmos с обзором, скоростью, ёмкостью, SMART и температурой"></td>
  </tr>
  <tr>
    <td>
      <strong>Необязательный мониторинг SMART</strong><br><br>
      Установите Helper с ограниченными полномочиями, только если нужен расширенный доступ к состоянию SMART и температуре. Остальные функции работают без него.
    </td>
    <td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="Настройки Palmos с установленным SMART Helper"></td>
  </tr>
</table>

## Поддерживаемая среда

| Параметр | Значение |
|---|---|
| Поддерживаются | USB, Thunderbolt / USB4, SD-карты, внешние SSD и HDD, внешние корпуса NVMe |
| Не поддерживаются | Внутренние диски, сетевые тома, виртуальные носители, подключения iPhone и iPad |
| Минимальная версия | macOS 26 или новее |
| Архитектура | Apple Silicon (arm64) |
| Среда сборки | Xcode 26.4 или новее с macOS 26 SDK |
| Распространение | Подписанный Apple Development, но не нотариально заверенный DMG через GitHub Releases |

## Установка и выпуски

Каждый GitHub Release содержит один файл `Palmos-v<версия>.dmg` только для arm64. Откройте DMG и перетащите `Palmos.app` в `Applications`. Выпуски подписываются бесплатным сертификатом Apple Development, но не проходят нотариальное заверение. Перед первым запуском удалите атрибут карантина:

```bash
sudo xattr -rd com.apple.quarantine /Applications/Palmos.app
```

Публикация настраивается в [`Config/Release/manifest.json`](../Config/Release/manifest.json). Она выполняется только после успешного main CI, при `release: true`, для ещё не опубликованной версии и при наличии единственного непустого совпадающего раздела в [CHANGELOG.md](../CHANGELOG.md).

### Homebrew и обновления App

После публикации GitHub Release с поддержкой Sparkle фиксированная checksum DMG и подписанный appcast синхронизируются с общим tap:

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

Для stable используется `palmos`, для alpha — `palmos@alpha`. Palmos использует Sparkle 2 для фоновой проверки обновлений и ручной команды **Check for Updates…** в Settings → About. Подписанный appcast: `https://slippindylan.github.io/homebrew-tap/palmos/appcast.xml`.

Обновление App заменяет только `Palmos.app`. Оно не устанавливает и не обновляет привилегированный SMART Helper или подписанный companion `smartctl`; при необходимости обновляйте их явно через Settings → SMART Helper с подтверждением администратора.

Для push в `main` и pull request всегда запускаются лёгкие проверки автоматизации выпуска. Если изменены только `README.md`, `docs/`, `LICENSE` или `AGENTS.md`, сборка macOS пропускается, кроме случаев, когда публикация включена. Для остальных изменений проверяются Core, App, безопасность Helper, упаковка и неподписанная arm64-сборка; `release: true` также принудительно включает эту полную проверку.

## SMART Helper

Необязательный Helper устанавливается через `SMJobBless` в `/Library/PrivilegedHelperTools/com.palmos.smartservice`. Он предоставляет только согласование версий, ограниченное чтение SMART, установку companion и ограниченную диагностику занятых устройств.

Удаление App не удаляет Helper автоматически.

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## Сборка из исходного кода

Откройте `Palmos.xcworkspace` и выберите scheme `PalmosApp`. Для локальной сборки с поддержкой SMART подготовьте сертификат Apple Development и выполните:

```bash
Scripts/build-local-smart-app.sh
```

## Лицензия

Copyright © 2025–2026 SlippinDylan Studio. Palmos распространяется по лицензии [Apache License 2.0](../LICENSE).

Palmos включает MenuBarExtraAccess 1.3.0 под лицензией MIT и подписанный `smartctl`, собранный из smartmontools 7.5 под GPL version 2 or later. Полные тексты находятся в [`Shared/Licensing`](../Shared/Licensing).
