<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Значок приложения Palmos">
  <h1>Palmos</h1>
</div>

<div align="center">
  <p>Нативное приложение для строки меню macOS, чтобы следить за внешними физическими накопителями.</p>
  <p><a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="../README.md">English</a> · <a href="README.ja.md">日本語</a> · <strong>Русский</strong></p>
</div>

Palmos выводит в строку меню информацию, которую стоит проверить перед отключением внешнего диска. Главный объект здесь — физическое устройство; его тома и разделы показаны ниже. APFS-диск с несколькими томами всё равно остаётся одним диском в списке.

<table>
  <tr><td width="32%"><strong>Всё сразу</strong><br><br>Не открывая «Дисковую утилиту», можно увидеть текущую скорость чтения и записи, итоги текущего сеанса, ёмкость, смонтированные тома и путь подключения.</td><td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="Панель меню Palmos с данными об устройстве, скорости, ёмкости, SMART и температуре"></td></tr>
  <tr><td><strong>SMART, когда он доступен</strong><br><br>Установите необязательный SMART Helper из настроек, если нужны данные о здоровье или температуре SMART. Остальные функции Palmos работают и без него.</td><td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="Настройки Palmos с SMART Helper"></td></tr>
</table>

## Что показывает Palmos

- Текущую скорость чтения и записи, а также счётчики для текущего сеанса подключения.
- Общую, занятую и свободную ёмкость; смонтированные тома, файловые системы и разделы.
- Сведения о подключении USB, Thunderbolt, USB4, SD или поддерживаемом PCIe-туннелировании.
- Безопасное извлечение всего физического устройства. Palmos сначала размонтирует диск, затем извлекает его и сообщает, что носитель можно отключить, только после успеха. Если macOS сообщает, что устройство занято, Palmos может помочь найти удерживающие его процессы до выбора дальнейшего действия.

## Поддерживаемые устройства

Palmos поддерживает внешние физические накопители, подключённые через USB, Thunderbolt, USB4, SD и поддерживаемое PCIe-туннелирование: внешние SSD, HDD, SD-карты и корпуса для NVMe. В списке может появиться и не смонтированное физическое устройство.

Внутренние диски, сетевые тома, виртуальные носители и подключения iPhone или iPad намеренно не показываются. Требуются Apple Silicon (arm64) и macOS 26 или новее.

SMART не равен обнаружению устройства: нужные команды должны поддерживаться и самим накопителем, и корпусом либо адаптером. Некоторые мосты USB–SATA/NVMe не передают SMART или требуют режим транспорта, с которым Palmos не умеет работать. В таком случае Palmos покажет, что SMART недоступен или требуется поддержка транспорта; установка Helper не меняет возможности аппаратного моста.

## Установка и первый запуск

### Homebrew

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

### DMG и первый запуск

1. Скачайте DMG для arm64 на [GitHub Releases](https://github.com/SlippinDylan/Palmos/releases), откройте его и перетащите `Palmos.app` в `Applications`.
2. Текущие выпуски подписаны сертификатом Apple Development, но не нотариально заверены. macOS может отказать при первом запуске из-за атрибута карантина, установленного при скачивании. В таком случае удалите этот атрибут только у установленного App:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Palmos.app
   ```

3. Откройте Palmos, подключите внешний диск и нажмите значок в строке меню. Выберите устройство, чтобы увидеть тома, ёмкость, скорость, топологию и управление извлечением.

Команда удаляет только атрибут карантина загрузки у `/Applications/Palmos.app`; она не обходит проверку подписи кода. Не выполняйте её для App, которому не доверяете.

## SMART Helper и обновления

SMART Helper необязателен. Когда раздел SMART попросит его установить, выберите **Install Helper** в Settings и подтвердите запрос администратора macOS. Palmos устанавливает вместе с Helper собственный доверенный companion `smartctl` и не использует копию из Homebrew или каталога, доступного пользователю на запись.

Palmos автоматически проверяет обновления App; проверку можно запустить вручную через **Settings → About → Check for Updates…**. Обновление App заменяет только `Palmos.app` и не устанавливает и не обновляет привилегированный Helper без явного действия. Если Palmos попросит обновить Helper, откройте **Settings → SMART Helper**.

Удаление `Palmos.app` не удаляет уже установленный Helper. Если нужно удалить и его, выполните следующие команды только после решения удалить Palmos. Они нацелены на указанные системную службу и companion Palmos, а не на ваши диски или данные:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## Сборка из исходного кода

Откройте `Palmos.xcworkspace` в Xcode 26.4 или новее с macOS 26 SDK, выберите схему `PalmosApp` и соберите проект. Неподписанная сборка работает без SMART. Для сборки App с поддержкой SMART App, Helper и companion должны использовать один Apple Development Team. После настройки сертификата выполните:

```bash
Scripts/build-local-smart-app.sh
```

## Лицензия

Copyright © 2025–2026 SlippinDylan Studio. Palmos распространяется по [Apache License 2.0](../LICENSE).

В App входят [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess) по лицензии MIT и `smartctl`, собранный из smartmontools 7.5 по GPL version 2 or later. Уведомления находятся в [Shared/Licensing](../Shared/Licensing).
