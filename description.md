# GoTelegram Manager

Профессиональный Bash-скрипт для автоматической установки и управления MTProto прокси с поддержкой Fake TLS маскировки. Прокси предназначен для обхода блокировок
и обеспечения безопасного доступа к Telegram в странах с ограничениями.

## Возможности

- Автоматическая установка Docker (если не установлен)
- Настройка MTProto прокси с Fake TLS маскировкой
- Маскировка трафика под обычный HTTPS
- Выбор домена для маскировки:
  - Google.com, Wikipedia.org, GitHub.com, Cloudflare.com
  - Microsoft.com, Amazon.com, Yahoo.com, DuckDuckGo.com
  - Apple.com, Meta.com или свой домен
- Выбор порта (443, 8443, 9443 или любой другой)
- Проверка доступности порта перед установкой
- Генерация корректного Fake TLS секрета с префиксом `ee`
- Создание QR-кодов для быстрого подключения с телефона

## Режимы использования

### Интерактивное меню
```bash
sudo gotelegram

# (Команды командной строки)
sudo gotelegram install   # Установка прокси
sudo gotelegram show      # Показать данные подключения
sudo gotelegram logs      # Последние 30 строк логов
sudo gotelegram logs -a   # Все логи через less
sudo gotelegram remove    # Полное удаление
sudo gotelegram about     # Информация о программе
sudo gotelegram help      # Справка

# Быстрая установка 
wget -O setup_gotelegram.sh https://raw.githubusercontent.com/kci2003/gotelegram_mtproxy/main/setup_gotelegram.sh && \
chmod +x setup_gotelegram.sh && \
sudo ./setup_gotelegram.sh

# 1. Скачать и запустить
wget -O setup_gotelegram.sh https://raw.githubusercontent.com/kci2003/gotelegram_mtproxy/main/setup_gotelegram.sh
chmod +x setup_gotelegram.sh
sudo ./setup_gotelegram.sh

# 2. В меню выбрать "Установить прокси"
# 3. Выбрать домен маскировки (например, google.com)
# 4. Выбрать порт (например, 443)
# 5. Получить данные для подключения

# 6. Подключиться к прокси через Telegram
# 7. Готово!