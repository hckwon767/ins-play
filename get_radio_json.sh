#!/bin/bash

# 임시 파일 정의
COOKIE_FILE=$(mktemp)
JSON_TMP=$(mktemp)

# [추가] 최종적으로 저장할 파일명 설정
OUTPUT_FILE="channels.json"

# ---------------------------------------------------------
# [설정] 수집하고 싶은 해시태그 목록 전체 반영
# ---------------------------------------------------------
HASHTAGS=(
    "%EC%A2%85%ED%95%A9"                              # 종합
    "%F0%9F%8E%B6%20%EA%B0%80%EC%9A%94"               # 🎵 가요
    "%ED%8A%B8%EB%A1%9C%ED%8A%B8"                     # 트로트
    "%F0%9F%A5%AA%20POP"                              # 🤠 POP
    "%ED%81%B4%EB%9E%A8%EC%8B%9D"                     # 클래식
    "%EB%9D%BD%26%EB%A9%94%ED%83%88"                  # 락&메탈
    "%EC%9E%AC%EC%A6%88"                              # 재즈
    "%E2%9B%EA%20CCM"                                 # ⛪ CCM
    "%EA%B8%B0%ED%83%80"                              # 기타
    "%F0%9F%8E%A4%20%EB%85%B8%EB%9E%98"               # 🎤 노래
    "%F0%9F%8E%B9%20%EC%97%B0%EC%A3%BC"               # 🎹 연주
    "%F0%9F%93%BB%20%EC%B3%94%EC%96%B5"               # 📻 추억
    "%EC%9D%8C%EC%95%85"                              # 음악
    "%E2%98%95%20%ED%9E%90%EB%A7%81"                  # ☕ 힐링
    "%F0%9F%98%99%20%EC%88%98%EB%8B%A4"               # 😙 수다
    "%ED%9A%BD%20%EC%8B%A0%EC%B2%AD%EA%B3%A1"         # 🧾 신청곡
    "%F0%9F%8E%AE%20%EA%B2%8C%EC%9E%84"               # 🎮 게임
    "%EC%9D%8C%EC%95%85%EB%B0%A9%EC%A1%A1"            # 음악방송
    "%F0%9F%8C%B1%201020"                             # 🌱 1020
    "%F0%9F%8C%B9%202030"                             # 🌹 2030
    "%F0%9F%B0%97%203040"                             # 🌷 3040
    "%ED%8A%B8%EB%A1%A1%2040%EB%8C%80~"               # 🌳 40대~
)

# 1. 메인 페이지에 접근하여 초기 세션 쿠키 및 CSRF 토큰 추출 (1회만 수행)
INITIAL_PAGE=$(curl -s -c "$COOKIE_FILE" "https://www.inlive.co.kr/toplive")
CSRF_TOKEN=$(echo "$INITIAL_PAGE" | grep -oP 'meta name="csrf-token" content="\K[^"]+')

# 토큰 추출 실패 시 예외 처리
if [ -z "$CSRF_TOKEN" ]; then
    rm -f "$COOKIE_FILE" "$JSON_TMP"
    echo "Error: CSRF 토큰을 가져오지 못했습니다." >&2
    exit 1
fi

# 중복 방송국 수집을 방지하기 위해 임시 보관할 변수
ALL_LIVE_IDS=""

# 2. 해시태그 배열을 돌면서 방송 ID(f_bsid) 수집
for tag in "${HASHTAGS[@]}"
do
    POST_DATA="page_no=1&hashtag=${tag}&searchval="
    
    # API 호출하여 f_bsid 목록 추출
    IDS=$(curl -s -b "$COOKIE_FILE" "https://www.inlive.co.kr/ajaxGetTopLiveList" \
      -X POST \
      -H "Accept: application/json, text/javascript, */*; q=0.01" \
      -H "Accept-Language: ko,en;q=0.9" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      -H "X-Requested-With: XMLHttpRequest" \
      -H "Origin: https://www.inlive.co.kr" \
      -H "Referer: https://www.inlive.co.kr/toplive" \
      -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36" \
      -H "X-CSRF-TOKEN: $CSRF_TOKEN" \
      --data-raw "$POST_DATA" | jq -r '.result[].f_bsid' 2>/dev/null)
    
    # 추출된 ID들을 하나로 합치기
    if [ ! -z "$IDS" ]; then
        ALL_LIVE_IDS="${ALL_LIVE_IDS}${IFS}${IDS}"
    fi
done

# 중복된 방송 ID 제거 처리 (여러 태그에 중복 랭크된 방송국 제거)
UNIQUE_IDS=$(echo "$ALL_LIVE_IDS" | tr ' ' '\n' | grep -v '^$' | sort -u)

# 임시 JSON 배열 시작 지점 생성
echo "[" > "$JSON_TMP"
first=true

# 3. 수집된 모든 고유 방송 ID를 순회하며 데이터 추출 및 JSON 구조화
for bsid in $UNIQUE_IDS
do
    # 개별 방송국의 pls 주소 요청 (인코딩 변환 포함)
    PLS_DATA=$(curl -s "http://${bsid}.inlive.co.kr/live/listen.pls" | iconv -f euc-kr -t utf-8 2>/dev/null)
    
    # 데이터 유효성 검증 및 추출
    if echo "$PLS_DATA" | grep -q "File1="; then
        
        # 이름 추출 (JSON 형식 저장이므로 굳이 언더바 공백 변환 없이 원래 공백/이름 유지)
        station_name=$(echo "$PLS_DATA" | grep "Title1=" | cut -d'=' -f2-)
        [ -z "$station_name" ] && station_name="Inlive_Station"
        
        # 타이틀에 '트로트'라는 글자가 포함되어 있다면 리스트에서 제외 (스킵)
        if echo "$station_name" | grep -q "트로트"; then
            continue
        fi
        
        # 스트리밍 URL 추출
        stream_url=$(echo "$PLS_DATA" | grep "File1=" | cut -d'=' -f2-)
        
        # 썸네일 URL 조합
        thumb_url="https://cdn.inlive.co.kr/profile/${bsid}.jpg"
        
        # JSON 포맷에 맞는 요소 추가 (첫 항목이 아니면 콤마 추가)
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$JSON_TMP"
        fi
        
        # jq 객체 생성용 뼈대 임시 작성
        jq -n \
          --arg bsid "$bsid" \
          --arg name "$station_name" \
          --arg streamUrl "$stream_url" \
          --arg thumbUrl "$thumb_url" \
          '{bsid: $bsid, name: $name, streamUrl: $streamUrl, thumbUrl: $thumbUrl}' >> "$JSON_TMP"
    fi
done

echo "]" >> "$JSON_TMP"

# 4. "channels" 오브젝트로 감싸서 지정된 OUTPUT_FILE(channels.json)에 덤프
jq '{"channels": .}' "$JSON_TMP" > "$OUTPUT_FILE"

echo "[완료] 방송 데이터 수집이 끝나고 '${OUTPUT_FILE}' 파일로 저장되었습니다."

# 임시 파일들 정리
rm -f "$COOKIE_FILE" "$JSON_TMP"
