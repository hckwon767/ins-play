#!/bin/bash
# get_radio_json.sh
# get_radio.sh 와 동일한 로직이지만 결과를 channels.json 형식으로 출력한다.
# GitHub Actions에서 실행되어 Pages에 배포된다.

COOKIE_FILE=$(mktemp)

# 브라우저 실제 요청에 맞춰 더블 인코딩된 해시태그 목록으로 수정
HASHTAGS=(
    "%F0%9F%8E%B6%20%EA%B0%80%EC%9A%94"  # 🎵 가요
)

# CSRF 토큰 및 초기 세션 쿠키 획득 (크롬 148 버전 User-Agent 반영)
INITIAL_PAGE=$(curl -s -c "$COOKIE_FILE" \
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36" \
  "https://www.inlive.co.kr/toplive")
CSRF_TOKEN=$(echo "$INITIAL_PAGE" | grep -oP 'meta name="csrf-token" content="\K[^"]+')

if [ -z "$CSRF_TOKEN" ]; then
  echo '{"error":"CSRF 토큰 획득 실패","channels":[],"updatedAt":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' >&1
  rm -f "$COOKIE_FILE"
  exit 0
fi

ALL_IDS=""

# 해시태그별 방송 ID 수집
for TAG in "${HASHTAGS[@]}"; do
  # 브라우저의 최신 Sec-Fetch 및 필수 헤더들을 모두 추가하여 차단 우회
  IDS=$(curl -s -b "$COOKIE_FILE" "https://www.inlive.co.kr/ajaxGetTopLiveList" \
    -X POST \
    -H "Accept: application/json, text/javascript, */*; q=0.01" \
    -H "Accept-Language: ko,en;q=0.9,zh-CN;q=0.8,zh;q=0.7" \
    -H "Connection: keep-alive" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "Origin: https://www.inlive.co.kr" \
    -H "Referer: https://www.inlive.co.kr/toplive" \
    -H "Sec-Fetch-Dest: empty" \
    -H "Sec-Fetch-Mode: cors" \
    -H "Sec-Fetch-Site: same-origin" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36" \
    -H "X-CSRF-TOKEN: $CSRF_TOKEN" \
    -H "sec-ch-ua: \"Chromium\";v=\"148\", \"Google Chrome\";v=\"148\", \"Not/A)Brand\";v=\"99\"" \
    -H "sec-ch-ua-mobile: ?0" \
    -H "sec-ch-ua-platform: \"Windows\"" \
    --data-raw "page_no=1&hashtag=${TAG}&searchval=" \
    | jq -r '.result[]? | "\(.f_bsid)\t\(.f_title // "")\t\(.f_hashtag // "")\t\(.f_img // "")"' 2>/dev/null)
  
  [ -n "$IDS" ] && ALL_IDS="${ALL_IDS}"$'\n'"${IDS}"
done

# 중복 제거 (bsid 기준)
UNIQUE=$(echo "$ALL_IDS" | grep -v '^$' | sort -u -t$'\t' -k1,1)

# JSON 배열 생성
ITEMS=""
COUNT=0

while IFS=$'\t' read -r BSID TITLE HASHTAG IMG; do
  [ -z "$BSID" ] && continue

  PLS_RAW=$(curl -s "http://${BSID}.inlive.co.kr/live/listen.pls" --max-time 5)
  STREAM_URL=$(echo "$PLS_RAW" | iconv -f euc-kr -t utf-8 2>/dev/null | grep "File1=" | cut -d'=' -f2-)
  PLS_TITLE=$(echo "$PLS_RAW" | iconv -f euc-kr -t utf-8 2>/dev/null | grep "Title1=" | cut -d'=' -f2-)

  [ -z "$STREAM_URL" ] && continue

  # 이름 결정: PLS 타이틀 > API 타이틀 > bsid
  NAME="${PLS_TITLE:-${TITLE:-$BSID}}"
  # JSON 특수문자 이스케이프
  NAME=$(echo "$NAME" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g')
  STREAM_URL=$(echo "$STREAM_URL" | tr -d '\r')

  # http:// 주소를 https:// 로 변경 (이미 https 이거나 형식이 다르면 유지)
  if [[ "$STREAM_URL" == http://* ]]; then
    STREAM_URL="https://${STREAM_URL#http://}"
  fi

  THUMB=""
  if [ -n "$IMG" ]; then
    THUMB="$IMG"
  else
    THUMB="https://cdn.inlive.co.kr/profile/${BSID}.jpg"
  fi

  ITEM="{\"bsid\":\"${BSID}\",\"name\":\"${NAME}\",\"streamUrl\":\"${STREAM_URL}\",\"thumbUrl\":\"${THUMB}\"}"

  if [ $COUNT -eq 0 ]; then
    ITEMS="$ITEM"
  else
    ITEMS="${ITEMS},${ITEM}"
  fi
  COUNT=$((COUNT + 1))

done <<< "$UNIQUE"

# KST 시각
UPDATED=$(date -d '+9 hours' '+%Y-%m-%d %H:%M' 2>/dev/null || date -u '+%Y-%m-%d %H:%M')

echo "{\"updatedAt\":\"${UPDATED} KST\",\"count\":${COUNT},\"channels\":[${ITEMS}]}"

rm -f "$COOKIE_FILE"
