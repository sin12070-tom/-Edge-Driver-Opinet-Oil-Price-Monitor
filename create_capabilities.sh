#!/bin/bash
# SmartThings Custom Capabilities 자동 생성 및 드라이버 설정 스크립트
#
# 이 스크립트는 다음 작업을 수행합니다:
# 1. SmartThings CLI 로그인 여부 확인 및 네임스페이스 감지
# 2. 8개의 커스텀 Capability 생성 및 Presentation 등록
# 3. 드라이버 코드와 프로필에서 {{NAMESPACE}} 플레이스홀더를 실제 네임스페이스로 치환
# 4. device-config.json을 클라우드에 등록하여 VID 생성 및 프로필에 자동 반영

set -e

# ANSI 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}===================================================${NC}"
echo -e "${GREEN}      오피넷 유가 모니터 Capability 등록 스크립트    ${NC}"
echo -e "${GREEN}===================================================${NC}"

# 1. SmartThings CLI 설치 여부 확인
if ! command -v smartthings &> /dev/null; then
    echo -e "${RED}[오류] smartthings CLI가 설치되어 있지 않습니다.${NC}"
    echo -e "https://github.com/SmartThingsCommunity/smartthings-cli 에서 CLI를 설치하고 로그인해 주세요."
    exit 1
fi

# 2. 로그인 및 네임스페이스 감지
echo -e "${YELLOW}[1/4] SmartThings 개발자 네임스페이스 조회 중...${NC}"
set +e
CAPS_JSON=$(smartthings capabilities -j 2>/dev/null)
set -e

NAMESPACE=""
if [ -n "$CAPS_JSON" ]; then
    NAMESPACE=$(echo "$CAPS_JSON" | grep -o '"namespace": "[^"]*' | head -n 1 | cut -d'"' -f4)
fi

if [ -z "$NAMESPACE" ]; then
    echo -e "${YELLOW}[경고] CLI 자동 감지 실패. 수동 입력을 요청합니다.${NC}"
    echo -n "수동으로 알파벳 네임스페이스(예: insidehonest32774)를 입력하세요: "
    read -r NAMESPACE
fi

if [ -z "$NAMESPACE" ]; then
    echo -e "${RED}[오류] 네임스페이스가 입력되지 않았습니다. 종료합니다.${NC}"
    exit 1
fi

echo -e "${GREEN}감지된 네임스페이스: $NAMESPACE${NC}\n"

# 3. Capability & Presentation 생성 루프
echo -e "${YELLOW}[2/4] 커스텀 Capability 생성 및 Presentation 등록 시작...${NC}"
CAPABILITIES=(
    "conn_status:opinetstatus"
    "ref_region:opinetrefregion"
    "national_avg:opinetnationalavgv2"
    "sido_avg:opinetsidoavgv2"
    "sigungu_avg:opinetsigunguavgv2"
    "lowest_price:opinetlowestpricev2"
    "fav_station1:opinetfavstation1v2"
    "fav_station2:opinetfavstation2v2"
    "region_search:opinetregionsearch"
    "station_search:opinetstationsearch"
    "region_result:opinetregionresult"
)

for entry in "${CAPABILITIES[@]}"; do
    FILE_PREFIX="${entry%%:*}"
    CAP_NAME="${entry##*:}"
    CAP_ID="${NAMESPACE}.${CAP_NAME}"

    echo -e "\n--------------------------------------------"
    echo -e "작업 중: ${CAP_NAME} (${FILE_PREFIX}.yaml)"
    echo -e "--------------------------------------------"

    # Capability가 존재하는지 확인 (없으면 생성, 있으면 스킵)
    set +e
    CAP_EXISTS=$(smartthings capabilities "${CAP_ID}" 2>/dev/null)
    set -e

    if [ -z "$CAP_EXISTS" ]; then
        echo -e "Capability ${CAP_ID} 생성 중..."
        smartthings capabilities:create -i "capabilities/${FILE_PREFIX}.yaml"
    else
        echo -e "Capability ${CAP_ID} 가 존재합니다. 업데이트 중..."
        smartthings capabilities:update "${CAP_ID}" -i "capabilities/${FILE_PREFIX}.yaml"
    fi

    # API 동기화 대기
    sleep 4

    # Presentation 등록
    echo -e "Presentation 등록/업데이트 중..."
    smartthings capabilities:presentation:update "${CAP_ID}" --capability-version 1 -i "capabilities/${FILE_PREFIX}_presentation.yaml" || \
    smartthings capabilities:presentation:create "${CAP_ID}" --capability-version 1 -i "capabilities/${FILE_PREFIX}_presentation.yaml"

    # 연속 요청 지연
    sleep 4
done

# 2.5. Capability 한국어 번역(Locale) 등록
echo -e "${YELLOW}[2.5/4] 커스텀 Capability 한국어 번역 등록 시작...${NC}"
mkdir -p capabilities/translations

for entry in "${CAPABILITIES[@]}"; do
    FILE_PREFIX="${entry%%:*}"
    CAP_NAME="${entry##*:}"
    CAP_ID="${NAMESPACE}.${CAP_NAME}"

    echo -e "한국어 번역 파일 생성 및 등록: ${CAP_ID}"
    
    ATTR_NAME=""
    DISPLAY_LABEL=""
    if [ "$CAP_NAME" = "opinetrefregion" ]; then
        ATTR_NAME="refRegion"
        DISPLAY_LABEL="기준 지역"
    elif [ "$CAP_NAME" = "opinetstatus" ]; then
        ATTR_NAME="connStatus"
        DISPLAY_LABEL="연결 상태"
    elif [ "$CAP_NAME" = "opinetstationsearch" ]; then
        ATTR_NAME="stationKeyword"
        DISPLAY_LABEL="주유소코드 조회"
    elif [ "$CAP_NAME" = "opinetnationalavgv2" ]; then
        ATTR_NAME="nationalAvg"
        DISPLAY_LABEL="전국 주유소 평균가격"
    elif [ "$CAP_NAME" = "opinetsidoavgv2" ]; then
        ATTR_NAME="sidoAvg"
        DISPLAY_LABEL="시도별 주유소 평균가격"
    elif [ "$CAP_NAME" = "opinetsigunguavgv2" ]; then
        ATTR_NAME="sigunguAvg"
        DISPLAY_LABEL="시군구 주유소 평균가격"
    elif [ "$CAP_NAME" = "opinetlowestpricev2" ]; then
        ATTR_NAME="lowestPrice"
        DISPLAY_LABEL="지역별 최저가 주유소"
    elif [ "$CAP_NAME" = "opinetfavstation1v2" ]; then
        ATTR_NAME="favStationOne"
        DISPLAY_LABEL="단골 주유소 1"
    elif [ "$CAP_NAME" = "opinetfavstation2v2" ]; then
        ATTR_NAME="favStationTwo"
        DISPLAY_LABEL="단골 주유소 2"
    elif [ "$CAP_NAME" = "opinetregionsearch" ]; then
        ATTR_NAME="keyword"
        DISPLAY_LABEL="지역코드 조회"
    elif [ "$CAP_NAME" = "opinetregionresult" ]; then
        ATTR_NAME="searchResult"
        DISPLAY_LABEL="조회 결과"
    fi

    # ko.yaml 생성
    NUMERIC_ATTR_NAME=""
    if [ "$CAP_NAME" = "opinetnationalavgv2" ]; then
        NUMERIC_ATTR_NAME="nationalAvgNumeric"
    elif [ "$CAP_NAME" = "opinetsidoavgv2" ]; then
        NUMERIC_ATTR_NAME="sidoAvgNumeric"
    elif [ "$CAP_NAME" = "opinetsigunguavgv2" ]; then
        NUMERIC_ATTR_NAME="sigunguAvgNumeric"
    elif [ "$CAP_NAME" = "opinetlowestpricev2" ]; then
        NUMERIC_ATTR_NAME="lowestPriceNumeric"
    elif [ "$CAP_NAME" = "opinetfavstation1v2" ]; then
        NUMERIC_ATTR_NAME="favStationOneNumeric"
    elif [ "$CAP_NAME" = "opinetfavstation2v2" ]; then
        NUMERIC_ATTR_NAME="favStationTwoNumeric"
    fi

    if [ -n "$NUMERIC_ATTR_NAME" ]; then
        cat << EOF > "capabilities/translations/ko_${FILE_PREFIX}.yaml"
tag: ko
label: "${DISPLAY_LABEL}"
attributes:
  ${ATTR_NAME}:
    label: "${DISPLAY_LABEL}"
  ${NUMERIC_ATTR_NAME}:
    label: "${DISPLAY_LABEL}"
EOF
    else
        cat << EOF > "capabilities/translations/ko_${FILE_PREFIX}.yaml"
tag: ko
label: "${DISPLAY_LABEL}"
attributes:
  ${ATTR_NAME}:
    label: "${DISPLAY_LABEL}"
EOF
    fi

    # 한국어 번역 등록/업데이트
    set +e
    smartthings capabilities:translations:update "${CAP_ID}" -i "capabilities/translations/ko_${FILE_PREFIX}.yaml" 2>/dev/null || \
    smartthings capabilities:translations:create "${CAP_ID}" -i "capabilities/translations/ko_${FILE_PREFIX}.yaml"
    set -e

    # 번역 등록 지연
    sleep 3
done

echo -e "\n${GREEN}모든 커스텀 Capability 및 한국어 번역 등록 완료!${NC}\n"

# 4. 소스코드 내 네임스페이스 치환
echo -e "${YELLOW}[3/4] 드라이버 소스코드 및 프로필 파일 내 네임스페이스 치환 중...${NC}"
echo -e "치환 파일: src/init.lua, profiles/opinet-monitor.yml, device-config.json"

sed -i '' "s/{{NAMESPACE}}/${NAMESPACE}/g" src/init.lua
sed -i '' "s/{{NAMESPACE}}/${NAMESPACE}/g" profiles/opinet-monitor.yml
sed -i '' "s/{{NAMESPACE}}/${NAMESPACE}/g" device-config.json

echo -e "${GREEN}치환 완료!${NC}\n"

# 5. 디바이스 프레젠테이션(device-config) 등록 및 VID 발급
echo -e "${YELLOW}[4/4] 디바이스 프레젠테이션 등록 및 VID 생성 중...${NC}"
DEVICE_PRESENTATION_JSON=$(smartthings presentation:device-config:create -i device-config.json -j)

VID=$(echo "$DEVICE_PRESENTATION_JSON" | grep -o '"vid": "[^"]*' | head -n 1 | cut -d'"' -f4)

if [ -n "$VID" ]; then
    echo -e "${GREEN}발급된 VID: $VID${NC}"
    echo -e "프로필 파일(profiles/opinet-monitor.yml)의 vid 값을 업데이트합니다..."
    sed -i '' "s/vid: .*/vid: ${VID}/g" profiles/opinet-monitor.yml
    echo -e "${GREEN}VID 업데이트 성공!${NC}"
else
    echo -e "${RED}[경고] VID 발급에 실패하였습니다. 수동으로 등록하여 프로필의 vid에 넣어주세요.${NC}"
fi

echo -e "\n${GREEN}===================================================${NC}"
echo -e "${GREEN}             모든 작업이 성공적으로 완료되었습니다!         ${NC}"
echo -e "${GREEN}       이제 드라이버를 패키징하여 허브에 배포하시면 됩니다.      ${NC}"
echo -e "  명령어: smartthings edge:drivers:package${NC}"
echo -e "${GREEN}===================================================${NC}"
