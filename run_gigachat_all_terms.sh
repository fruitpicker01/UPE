#!/usr/bin/env bash
# Построчная отправка JSONL в GigaChat с ретраями и таймаутами.
# Требуется jq и curl в контейнере.

set -u  # без -e, чтобы не падать на единичной ошибке
LC_ALL=C.UTF-8

FILE="${1:-prompts_gigachat_terms.jsonl}"           # JSONL с payload'ами
OUT_DIR="${OUT_DIR:-out_$(date +%Y%m%d_%H%M%S)}"
ENDPOINT="${ENDPOINT:-gigachat-int/v1/chat/completions}"  # как в вашем примере
PAUSE="${PAUSE:-0.6}"                          # пауза между запросами (сек)
MAX_TIME="${MAX_TIME:-180}"                    # curl --max-time (сек)
RETRY="${RETRY:-5}"                            # количество ретраев
RETRY_DELAY="${RETRY_DELAY:-2}"                # сек между ретраями
RETRY_MAX_TIME="${RETRY_MAX_TIME:-300}"        # общее время ретраев
# Если нужен токен: экспортируйте GIGA_TOKEN и заголовок добавится автоматически
# export GIGA_TOKEN="...."

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq не найден. Установите jq в образе контейнера."
  exit 1
fi

mkdir -p "$OUT_DIR/raw"
: > "$OUT_DIR/responses.jsonl"

i=0
# читаем ЛЮБУЮ длину строки целиком
while IFS= read -r line || [ -n "$line" ]; do
  i=$((i+1))

  # достаём оригинальный prompt из тела запроса (уже в JSON)
  prompt="$(jq -r '.messages[0].content' <<<"$line" 2>/dev/null || echo "")"

  RAW_FILE="$OUT_DIR/raw/${i}.json"

  # собираем команду curl (с опциональным Authorization)
  CURL_ARGS=(
    -sS -X POST "$ENDPOINT"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
    --data-raw "$line"
    --max-time "$MAX_TIME"
    --retry "$RETRY"
    --retry-all-errors
    --retry-delay "$RETRY_DELAY"
    --retry-max-time "$RETRY_MAX_TIME"
    --fail-with-body
    -w "%{http_code}"
    -o "$RAW_FILE"
  )
  if [[ -n "${GIGA_TOKEN:-}" ]]; then
    CURL_ARGS=(-H "Authorization: Bearer $GIGA_TOKEN" "${CURL_ARGS[@]}")
  fi

  http_code="$(curl "${CURL_ARGS[@]}" || true)"

  # пробуем извлечь текст ответа
  if [[ -s "$RAW_FILE" ]]; then
    text="$(jq -r '.choices[0].message.content // empty' "$RAW_FILE" 2>/dev/null || echo "")"
  else
    text=""
  fi

  # дописываем сводку в responses.jsonl
  jq -Rn \
     --arg idx "$i" \
     --arg status "$http_code" \
     --arg prompt "$prompt" \
     --arg text "$text" \
     '{"idx":($idx|tonumber),"http_status":($status|tonumber),"prompt":$prompt,"response_text":$text}' \
     >> "$OUT_DIR/responses.jsonl"

  # небольшая пауза + лёгкий джиттер
  sleep "$PAUSE"
  usleep=$(( (RANDOM % 300) * 1000 ))  # до ~0.3 сек
  python - <<PY 2>/dev/null
import time; time.sleep(${usleep}/1_000_000)
PY

  # лог в stdout
  echo "[$i] HTTP $http_code"
done < "$FILE"

echo "Готово. См. $OUT_DIR/responses.jsonl и $OUT_DIR/raw/*.json"