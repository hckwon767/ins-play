#!/bin/bash

# 임시 파일 정의
COOKIE_FILE=$(mktemp)
JSON_TMP=$(mktemp)

# 최종적으로 저장할 파일명 설정
OUTPUT_FILE="channels.json"

# ---------------------------------------------------------
# [설정] 해시태그 목록 (URL 인코딩 값과 실제 매핑할 한글 태그명 부모 배열)
# ---------------------------------------------------------
# 포맷: "URL인코딩_값|출력할_태그명"
HASHTAGS=(
    "%F0%9F%8E%B6%20%EA%B0%80%EC%9A%94|🎶 가요"
    "%F0%9F%8E%A4%20%EB%85%B8%EB%9E%98|🎤 노래"
    "%F0%9F%93%BB%20%EC%B6%94%EC%96%B5%EC%9D%8C%EC%95%85|📻 추억음악"
    "%EC%9D%8C%EC%95%85|음악"
    "%F0%9F%A5%AA%20POP|🤠 POP"
    "%F0%9F%8E%B9%20%EC%97%B0%EC%A3%BC|🎹 연주"
    "%ED%81%B4%EB%9E%A8%EC%8B%9D|클래식"
    "%EB%9D%BD%26%EB%A9%94%ED%83%88|락&메탈"
    "%EC%9E%AC%EC%A6%88|재즈"
    "%EA%B8%B0%ED%83%80|기타"
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

# 임시 JSON 배열 시작 지점 생성
echo "[" > "$JSON_TMP"
first=true

# 중복 수집 방지를 위한 방문 기록 변수
PROCESSED_IDS=""

# 2. 해시태그 배열을 순회하며 실시간 방송 수집 및 파싱 처리
for item in "${HASHTAGS[@]}"
do
    # 인코딩 값과 한글 태그명 분리
    tag_encoded=$(echo "$item" | cut -d'|' -f1)
    tag_name=$(echo "$item" | cut -d'|' -f2)

    POST_DATA="page_no=1&hashtag=${tag_encoded}&searchval="
    
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
    
    # 현재 태그에서 수집된 ID들을 순회
    for bsid in $IDS
    do
        [ -z "$bsid" ] && continue

        # 이미 상위 태그에서 처리된 방송 ID라면 중복 방지를 위해 스킵
        if echo "$PROCESSED_IDS" | grep -q -w "$bsid"; then
            continue
        fi

        # 개별 방송국의 pls 주소 요청
        PLS_DATA=$(curl -s "http://${bsid}.inlive.co.kr/live/listen.pls" | iconv -f euc-kr -t utf-8 2>/dev/null)
        
        # 데이터 유효성 검증 및 추출
        if echo "$PLS_DATA" | grep -q "File1="; then
            
            # 이름 추출
            station_name=$(echo "$PLS_DATA" | grep "Title1=" | cut -d'=' -f2-)
            [ -z "$station_name" ] && station_name="Inlive_Station"
            
            # 타이틀에 '트로트'라는 글자가 포함되어 있다면 리스트에서 제외 (스킵)
            if echo "$station_name" | grep -q -E "트로트|테스트|찬송|중년|노을|라이브|마이크|Power Music"; then
                continue
            fi
            
            # 스트리밍 URL 추출
            stream_url=$(echo "$PLS_DATA" | grep "File1=" | cut -d'=' -f2-)
            
            # JSON 포맷에 맞는 요소 추가 (첫 항목이 아니면 콤마 추가)
            if [ "$first" = true ]; then
                first=false
            else
                echo "," >> "$JSON_TMP"
            fi
            
            # jq를 사용하여 tag, name, streamUrl 구조로 객체 생성
            jq -n \
              --arg tag "$tag_name" \
              --arg name "$station_name" \
              --arg streamUrl "$stream_url" \
              '{tag: $tag, name: $name, streamUrl: $streamUrl}' >> "$JSON_TMP"

            # 처리된 ID 목록에 추가
            PROCESSED_IDS="${PROCESSED_IDS} ${bsid}"
        fi
    done
done

echo "]" >> "$JSON_TMP"

# 3. "channels" 오브젝트로 감싸서 지정된 OUTPUT_FILE(channels.json)에 덤프
jq '{"channels": .}' "$JSON_TMP" > "$OUTPUT_FILE"

echo "[완료] 태그 정보가 포함된 방송 데이터가 '${OUTPUT_FILE}' 파일로 저장되었습니다."

# 임시 파일들 정리
rm -f "$COOKIE_FILE" "$JSON_TMP"
