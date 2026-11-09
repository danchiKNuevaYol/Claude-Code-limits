#!/bin/bash
# Двойной клик в Finder: забирает свежий код с GitHub,
# пересобирает Claude HUD и перезапускает его. Терминал не нужен.
cd "$(dirname "$0")" || exit 1

echo "→ Забираю изменения с GitHub…"
git pull --ff-only || echo "  (не получилось — собираю то, что есть)"

echo "→ Закрываю Claude HUD…"
killall ClaudeHUD 2>/dev/null

echo "→ Собираю…"
if ./build.sh install; then
  echo
  echo "✓ Готово, Claude HUD перезапущен. Окно закроется само."
  sleep 2
  osascript -e 'tell application "Terminal" to close (every window whose name contains "Обновить")' >/dev/null 2>&1 &
else
  echo
  echo "✗ Сборка не удалась. Скопируй текст выше и пришли Claude."
  read -n 1 -s -r -p "Нажми любую клавишу, чтобы закрыть…"
fi
