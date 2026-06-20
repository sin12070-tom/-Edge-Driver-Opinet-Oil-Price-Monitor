-- Opinet Oil Price Monitor Edge Driver v1.0
-- LAN 방식 | Android Edge Bridge (AEB) 연동

local capabilities = require "st.capabilities"
local cap_conn_status = capabilities["insidehonest32774.opinetstatus"]
local cap_ref_region = capabilities["insidehonest32774.opinetrefregion"]
local cap_national = capabilities["insidehonest32774.opinetnationalavgv2"]
local cap_sido     = capabilities["insidehonest32774.opinetsidoavgv2"]
local cap_sigungu  = capabilities["insidehonest32774.opinetsigunguavgv2"]
local cap_lowest   = capabilities["insidehonest32774.opinetlowestpricev2"]
local cap_fav1     = capabilities["insidehonest32774.opinetfavstation1v2"]
local cap_fav2     = capabilities["insidehonest32774.opinetfavstation2v2"]
local cap_search   = capabilities["insidehonest32774.opinetregionsearch"]
local cap_station_search = capabilities["insidehonest32774.opinetstationsearch"]
local cap_result   = capabilities["insidehonest32774.opinetregionresult"]

local Driver       = require "st.driver"
local socket       = require "cosock.socket"
local log          = require "log"
local json         = require "st.json"
local http         = require "cosock.socket.http"
http.TIMEOUT       = 10 -- Prevent socket hang on Hub
local ltn12        = require "ltn12"
local mdns         = require "st.mdns"
local area_codes   = require "area_codes"

------------------------------------------------------------
-- 상수 & 매핑 테이블
------------------------------------------------------------
local DEFAULT_INTERVAL = 3600 -- 60분 (초 단위)
local DEFAULT_API_KEY  = ""

local OIL_NAMES = {
  B027 = "보통휘발유",
  B034 = "고급휘발유",
  D047 = "자동차경유",
  C004 = "실내등유",
  K015 = "자동차부탄"
}

local BRAND_NAMES = {
  SKE = "SK에너지",
  GSC = "GS칼텍스",
  HDO = "현대오일뱅크",
  SOL = "S-OIL",
  RTE = "자영알뜰",
  RTX = "고속도로알뜰",
  NHO = "농협알뜰",
  ETC = "자가상표",
  E1G = "E1",
  SKG = "SK가스"
}

------------------------------------------------------------
-- 헬퍼 함수
------------------------------------------------------------
local function pref(device, key, default)
  local v = device.preferences and device.preferences[key]
  if v == nil or v == "" then return default end
  return v
end

local function make_array(val)
  if not val then return {} end
  if val[1] ~= nil then return val end
  return { val }
end

local function url_encode(str)
  if not str then return "" end
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w %-%_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  str = str:gsub(" ", "+")
  return str
end

local function get_diff_str(diff)
  local d = tonumber(diff) or 0
  if d > 0 then
    return "+" .. tostring(d)
  else
    return tostring(d)
  end
end

local function emit_event(device, event)
  event.state_change = true
  event.displayed = false
  device:emit_event(event)
end

local function emit_component_event(device, comp, event)
  event.state_change = true
  event.displayed = false
  device:emit_component_event(comp, event)
end

------------------------------------------------------------
-- mDNS 및 AEB 연동 헬퍼
------------------------------------------------------------
local function discover_aeb(driver, device)
  log.info("mDNS를 통해 Android Edge Bridge (_edgebridge._tcp) 검색 시도...")
  local discover_responses = mdns.discover("_edgebridge._tcp", "local")
  if discover_responses and discover_responses.found then
    for _, found in ipairs(discover_responses.found) do
      if found.host_info and found.host_info.address then
        local ip = found.host_info.address
        local port = found.host_info.port or 8088
        local aeb_addr = ip .. ":" .. tostring(port)
        log.info("mDNS AEB 검색 성공: " .. aeb_addr)
        device:set_field("discovered_aeb_ip", aeb_addr, { persist = true })
        return aeb_addr
      end
    end
  end
  log.warn("mDNS AEB 검색 실패")
  return nil
end

local function get_aeb_address(driver, device)
  local auto_search = pref(device, "aebAutoSearch", true)
  if auto_search then
    local discovered = device:get_field("discovered_aeb_ip")
    if discovered then
      return discovered
    else
      local discovered_now = discover_aeb(driver, device)
      if discovered_now then return discovered_now end
    end
  end

  local manual_ip = pref(device, "aebIp", "")
  local manual_port = tonumber(pref(device, "aebPort", 8088)) or 8088
  if manual_ip ~= "" then
    if not string.find(manual_ip, ":") then
      return manual_ip .. ":" .. tostring(manual_port)
    end
    return manual_ip
  end

  return nil
end

local function aeb_get(driver, device, target_url)
  local aeb_addr = get_aeb_address(driver, device)
  if not aeb_addr then
    log.error("AEB 주소가 설정되지 않았거나 검색되지 않았습니다.")
    return nil, "No AEB Address"
  end

  local request_url = "http://" .. aeb_addr .. "/api/forward?url=" .. url_encode(target_url)
  log.debug("AEB 요청 전송: " .. request_url)

  local resp = {}
  local _, status, headers = http.request({
    url    = request_url,
    method = "GET",
    headers = {
      ["Connection"] = "close"
    },
    sink = ltn12.sink.table(resp),
  })

  if status ~= 200 then
    log.error("AEB HTTP 에러: status=" .. tostring(status))
    return nil, "HTTP Error " .. tostring(status)
  end

  local body = table.concat(resp)
  local ok, decoded = pcall(json.decode, body)
  if not ok then
    log.error("JSON 파싱 에러: " .. tostring(decoded))
    return nil, "JSON Parse Error"
  end

  return decoded, "OK"
end

------------------------------------------------------------
-- 문자열 & 숫자 포맷팅 헬퍼 함수
------------------------------------------------------------
local utf8 = utf8 or require("utf8")

local function truncate_utf8(str, max_len)
  if not str then return "" end
  local len = utf8.len(str)
  if not len then
    if #str > max_len then
      return string.sub(str, 1, max_len) .. ".."
    end
    return str
  end
  if len <= max_len then
    return str
  end
  local offset = utf8.offset(str, max_len + 1)
  if offset then
    return string.sub(str, 1, offset - 1) .. ".."
  end
  return str
end

local function format_comma(amount)
  local formatted = tostring(math.floor(tonumber(amount) or 0))
  while true do
    local formatted_new, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
    formatted = formatted_new
  end
  return formatted
end

local function clean_station_name(name)
  if not name then return "알수없음" end
  name = name:gsub("%(주%)", "")
  name = name:gsub("주식회사", "")
  name = name:gsub("%(유%)", "")
  name = name:gsub("유한회사", "")
  name = name:gsub("%(사%)", "")
  name = name:gsub("사단법인", "")
  name = name:gsub("%(재%)", "")
  name = name:gsub("재단법인", "")
  name = name:gsub("%(합%)", "")
  name = name:gsub("합자회사", "")
  name = name:gsub("합명회사", "")
  
  -- Trim spaces
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  
  return truncate_utf8(name, 10)
end

------------------------------------------------------------
-- 연결 상태 동적 업데이트 핸들러
------------------------------------------------------------
local function update_connection_status(driver, device)
  local api_key = pref(device, "opinetApiKey", DEFAULT_API_KEY)

  -- 1. API 키 입력 체크
  if api_key == nil or api_key == "" then
    emit_event(device, cap_conn_status.connStatus({ value = "API 입력 필요" }))
    return
  end

  -- 2. AEB 주소 획득 체크
  local aeb_addr = get_aeb_address(driver, device)
  if not aeb_addr then
    emit_event(device, cap_conn_status.connStatus({ value = "AEB 자동 검색 실패" }))
    return
  end

  -- 3. 정상 연결 완료 상태
  emit_event(device, cap_conn_status.connStatus({ value = aeb_addr .. " 연결됨" }))
end

----------------------------------------------------------------------------
-- 기준 지역 동적 업데이트 핸들러
------------------------------------------------------------
local function update_reference_region(driver, device)
  local api_key = pref(device, "opinetApiKey", DEFAULT_API_KEY)
  local sido_code = pref(device, "sidoCode", "01")
  local sigungu_code = pref(device, "sigunguCode", "")

  -- 1. 시도 한글명 조회
  local url_sido = string.format("https://www.opinet.co.kr/api/areaCode.do?code=%s&out=json", api_key)
  local data_sido, err_sido = aeb_get(driver, device, url_sido)
  local sido_name = nil

  if data_sido and data_sido.RESULT and data_sido.RESULT.OIL then
    local list = make_array(data_sido.RESULT.OIL)
    for _, item in ipairs(list) do
      if item.AREA_CD == sido_code then
        sido_name = item.AREA_NM
        break
      end
    end
  end

  if not sido_name then
    log.warn("시도 한글명을 매핑할 수 없습니다. 코드: " .. tostring(sido_code))
    sido_name = "알수없음(" .. sido_code .. ")"
  end

  local final_region = sido_name

  -- 2. 시군구 한글명 조회 (설정되었을 경우)
  if sigungu_code and sigungu_code ~= "" then
    local url_sigun = string.format("https://www.opinet.co.kr/api/areaCode.do?code=%s&out=json&area=%s", api_key, sido_code)
    local data_sigun, err_sigun = aeb_get(driver, device, url_sigun)
    local sigungu_name = nil

    if data_sigun and data_sigun.RESULT and data_sigun.RESULT.OIL then
      local list = make_array(data_sigun.RESULT.OIL)
      for _, item in ipairs(list) do
        if item.AREA_CD == sigungu_code then
          sigungu_name = item.AREA_NM
          break
        end
      end
    end

    if sigungu_name then
      final_region = sido_name .. " " .. sigungu_name
    else
      log.warn("시군구 한글명을 매핑할 수 없습니다. 코드: " .. tostring(sigungu_code))
      final_region = sido_name .. " 알수없음(" .. sigungu_code .. ")"
    end
  end

  log.info("조회된 기준 지역: " .. final_region)
  local comp = device.profile.components.search
  if comp then
    emit_component_event(device, comp, cap_ref_region.refRegion({ value = final_region }))
  else
    log.error("search 컴포넌트를 찾을 수 없습니다.")
  end
end

------------------------------------------------------------
-- 오피넷 정보 조회 폴링 핸들러
------------------------------------------------------------
local function poll_handler(driver, device)
  log.info("오피넷 유가 정보 업데이트 시작")

  -- 연결 상태 및 기준 지역 명칭 동적 업데이트 실행
  pcall(update_connection_status, driver, device)
  pcall(update_reference_region, driver, device)

  local api_key      = pref(device, "opinetApiKey", DEFAULT_API_KEY)
  local sido_code    = pref(device, "sidoCode", "01")
  local sigungu_code = pref(device, "sigunguCode", "0101")
  local oil_type     = pref(device, "oilType", "B027")
  local fav_station1 = pref(device, "favGasStation1", "")
  local fav_station2 = pref(device, "favGasStation2", "")

  -- 0. API 키가 비어있을 때 처리
  if api_key == nil or api_key == "" then
    log.info("API Key가 비어있습니다. 조회를 중단하고 'API 입력 필요'를 설정합니다.")
    emit_event(device, cap_conn_status.connStatus({ value = "API 입력 필요" }))
    emit_event(device, cap_national.nationalAvg({ value = "API 입력 필요" }))
    emit_event(device, cap_national.nationalAvgNumeric({ value = 99999 }))
    emit_event(device, cap_sido.sidoAvg({ value = "API 입력 필요" }))
    emit_event(device, cap_sido.sidoAvgNumeric({ value = 99999 }))
    emit_event(device, cap_sigungu.sigunguAvg({ value = "API 입력 필요" }))
    emit_event(device, cap_sigungu.sigunguAvgNumeric({ value = 99999 }))
    emit_event(device, cap_lowest.lowestPrice({ value = "API 입력 필요" }))
    emit_event(device, cap_lowest.lowestPriceNumeric({ value = 99999 }))
    if fav_station1 ~= "" then
      emit_event(device, cap_fav1.favStationOne({ value = "API 입력 필요" }))
      emit_event(device, cap_fav1.favStationOneNumeric({ value = 99999 }))
    else
      emit_event(device, cap_fav1.favStationOne({ value = "미설정" }))
      emit_event(device, cap_fav1.favStationOneNumeric({ value = 0 }))
    end
    if fav_station2 ~= "" then
      emit_event(device, cap_fav2.favStationTwo({ value = "API 입력 필요" }))
      emit_event(device, cap_fav2.favStationTwoNumeric({ value = 99999 }))
    else
      emit_event(device, cap_fav2.favStationTwo({ value = "미설정" }))
      emit_event(device, cap_fav2.favStationTwoNumeric({ value = 0 }))
    end
    return
  end

  local oil_name = OIL_NAMES[oil_type] or oil_type

  -- 1. 전국 주요소 평균가격
  local url_national = string.format("https://www.opinet.co.kr/api/avgAllPrice.do?code=%s&out=json", api_key)
  local data, err = aeb_get(driver, device, url_national)

  -- API 키가 유효하지 않은 경우의 에러 체크 (JSON 응답 내 RESULT에 OIL이 없거나 HTTP 401/403 에러 발생 시)
  local is_api_key_error = false
  if data and data.RESULT and not data.RESULT.OIL then
    local msg = data.RESULT.message or ""
    log.warn("오피넷 API 응답 오류 감지: " .. tostring(msg))
    if string.find(msg, "인증") or string.find(msg, "키") or string.find(msg, "권한") then
      is_api_key_error = true
    end
  elseif err == "HTTP Error 401" or err == "HTTP Error 403" then
    is_api_key_error = true
  end

  if is_api_key_error then
    log.warn("유효하지 않은 API Key 감지. 조회를 중단하고 'API 입력 필요'를 설정합니다.")
    emit_event(device, cap_conn_status.connStatus({ value = "API 입력 필요" }))
    emit_event(device, cap_national.nationalAvg({ value = "API 입력 필요" }))
    emit_event(device, cap_national.nationalAvgNumeric({ value = 99999 }))
    emit_event(device, cap_sido.sidoAvg({ value = "API 입력 필요" }))
    emit_event(device, cap_sido.sidoAvgNumeric({ value = 99999 }))
    emit_event(device, cap_sigungu.sigunguAvg({ value = "API 입력 필요" }))
    emit_event(device, cap_sigungu.sigunguAvgNumeric({ value = 99999 }))
    emit_event(device, cap_lowest.lowestPrice({ value = "API 입력 필요" }))
    emit_event(device, cap_lowest.lowestPriceNumeric({ value = 99999 }))
    if fav_station1 ~= "" then
      emit_event(device, cap_fav1.favStationOne({ value = "API 입력 필요" }))
      emit_event(device, cap_fav1.favStationOneNumeric({ value = 99999 }))
    else
      emit_event(device, cap_fav1.favStationOne({ value = "미설정" }))
      emit_event(device, cap_fav1.favStationOneNumeric({ value = 0 }))
    end
    if fav_station2 ~= "" then
      emit_event(device, cap_fav2.favStationTwo({ value = "API 입력 필요" }))
      emit_event(device, cap_fav2.favStationTwoNumeric({ value = 99999 }))
    else
      emit_event(device, cap_fav2.favStationTwo({ value = "미설정" }))
      emit_event(device, cap_fav2.favStationTwoNumeric({ value = 0 }))
    end
    return
  end

  if data and data.RESULT and data.RESULT.OIL then
    local list = make_array(data.RESULT.OIL)
    local found = false
    for _, item in ipairs(list) do
      if item.PRODCD == oil_type then
        local val = string.format("%.1f원 (%s원)", tonumber(item.PRICE) or 0, get_diff_str(item.DIFF))
        emit_event(device, cap_national.nationalAvg({ value = val }))
        emit_event(device, cap_national.nationalAvgNumeric({ value = math.floor(tonumber(item.PRICE) or 99999) }))
        found = true
        break
      end
    end
    if not found then
      emit_event(device, cap_national.nationalAvg({ value = "정보 없음" }))
      emit_event(device, cap_national.nationalAvgNumeric({ value = 99999 }))
    end
  else
    emit_event(device, cap_national.nationalAvg({ value = "에러: " .. (err or "조회 실패") }))
    emit_event(device, cap_national.nationalAvgNumeric({ value = 99999 }))
  end

  -- 2. 시도별 주유소 평균가격
  local url_sido = string.format("https://www.opinet.co.kr/api/avgSidoPrice.do?code=%s&out=json&sido=%s&prodcd=%s", api_key, sido_code, oil_type)
  data, err = aeb_get(driver, device, url_sido)
  if data and data.RESULT and data.RESULT.OIL then
    local list = make_array(data.RESULT.OIL)
    local found = false
    for _, item in ipairs(list) do
      if item.PRODCD == oil_type then
        local val = string.format("%s : %.1f원 (%s원)", item.SIDONM or "", tonumber(item.PRICE) or 0, get_diff_str(item.DIFF))
        emit_event(device, cap_sido.sidoAvg({ value = val }))
        emit_event(device, cap_sido.sidoAvgNumeric({ value = math.floor(tonumber(item.PRICE) or 99999) }))
        found = true
        break
      end
    end
    if not found then
      emit_event(device, cap_sido.sidoAvg({ value = "정보 없음" }))
      emit_event(device, cap_sido.sidoAvgNumeric({ value = 99999 }))
    end
  else
    emit_event(device, cap_sido.sidoAvg({ value = "에러: " .. (err or "조회 실패") }))
    emit_event(device, cap_sido.sidoAvgNumeric({ value = 99999 }))
  end

  -- 3. 시군구별 주유소 평균가격
  local url_sigun = string.format("https://www.opinet.co.kr/api/avgSigunPrice.do?code=%s&out=json&sido=%s&sigun=%s&prodcd=%s", api_key, sido_code, sigungu_code, oil_type)
  data, err = aeb_get(driver, device, url_sigun)
  if data and data.RESULT and data.RESULT.OIL then
    local list = make_array(data.RESULT.OIL)
    local found = false
    for _, item in ipairs(list) do
      if item.PRODCD == oil_type then
        local val = string.format("%s : %.1f원 (%s원)", item.SIGUNNM or "", tonumber(item.PRICE) or 0, get_diff_str(item.DIFF))
        emit_event(device, cap_sigungu.sigunguAvg({ value = val }))
        emit_event(device, cap_sigungu.sigunguAvgNumeric({ value = math.floor(tonumber(item.PRICE) or 99999) }))
        found = true
        break
      end
    end
    if not found then
      emit_event(device, cap_sigungu.sigunguAvg({ value = "정보 없음" }))
      emit_event(device, cap_sigungu.sigunguAvgNumeric({ value = 99999 }))
    end
  else
    emit_event(device, cap_sigungu.sigunguAvg({ value = "에러: " .. (err or "조회 실패") }))
    emit_event(device, cap_sigungu.sigunguAvgNumeric({ value = 99999 }))
  end

  -- 4. 전국/지역별 최저가 주유소
  local area = sigungu_code ~= "" and sigungu_code or (sido_code ~= "" and sido_code or "")
  local url_lowest = string.format("https://www.opinet.co.kr/api/lowTop10.do?code=%s&out=json&prodcd=%s&area=%s&cnt=1", api_key, oil_type, area)
  data, err = aeb_get(driver, device, url_lowest)
  if data and data.RESULT and data.RESULT.OIL then
    local list = make_array(data.RESULT.OIL)
    if list[1] then
      -- 1순위 최저가는 항상 즉시 정수형 속성으로 고정 업데이트 (자동화용)
      emit_event(device, cap_lowest.lowestPriceNumeric({ value = math.floor(tonumber(list[1].PRICE) or 99999) }))

      if list[1].OS_NM and list[1].PRICE then
        local val = string.format("%s원 - %s(%s)", format_comma(list[1].PRICE), clean_station_name(list[1].OS_NM), list[1].UNI_ID or "")
        emit_event(device, cap_lowest.lowestPrice({ value = val }))
      else
        emit_event(device, cap_lowest.lowestPrice({ value = "최저가 정보 없음" }))
      end
    else
      emit_event(device, cap_lowest.lowestPrice({ value = "최저가 정보 없음" }))
      emit_event(device, cap_lowest.lowestPriceNumeric({ value = 99999 }))
    end
  else
    emit_event(device, cap_lowest.lowestPrice({ value = "에러: " .. (err or "조회 실패") }))
    emit_event(device, cap_lowest.lowestPriceNumeric({ value = 99999 }))
  end

  -- 5. 단골 주유소 1 상세 정보
  if fav_station1 ~= "" then
    local url_fav1 = string.format("https://www.opinet.co.kr/api/detailById.do?code=%s&out=json&id=%s", api_key, fav_station1)
    data, err = aeb_get(driver, device, url_fav1)
    if data and data.RESULT and data.RESULT.OIL then
      local oil_list = make_array(data.RESULT.OIL)
      local oil_detail = oil_list[1]
      if oil_detail then
        local prices = make_array(oil_detail.OIL_PRICE)
        local found = false
        for _, p in ipairs(prices) do
          if p.PRODCD == oil_type then
            local val = string.format("%s원 - %s", format_comma(p.PRICE), clean_station_name(oil_detail.OS_NM))
            emit_event(device, cap_fav1.favStationOne({ value = val }))
            emit_event(device, cap_fav1.favStationOneNumeric({ value = math.floor(tonumber(p.PRICE) or 99999) }))
            found = true
            break
          end
        end
        if not found then
          emit_event(device, cap_fav1.favStationOne({ value = (oil_detail.OS_NM or "주유소") .. " (유종 정보 없음)" }))
          emit_event(device, cap_fav1.favStationOneNumeric({ value = 99999 }))
        end
      else
        emit_event(device, cap_fav1.favStationOne({ value = "정보 파싱 에러" }))
        emit_event(device, cap_fav1.favStationOneNumeric({ value = 99999 }))
      end
    else
      emit_event(device, cap_fav1.favStationOne({ value = "에러: " .. (err or "조회 실패") }))
      emit_event(device, cap_fav1.favStationOneNumeric({ value = 99999 }))
    end
  else
    emit_event(device, cap_fav1.favStationOne({ value = "미설정" }))
    emit_event(device, cap_fav1.favStationOneNumeric({ value = 0 }))
  end

  -- 6. 단골 주유소 2 상세 정보
  if fav_station2 ~= "" then
    local url_fav2 = string.format("https://www.opinet.co.kr/api/detailById.do?code=%s&out=json&id=%s", api_key, fav_station2)
    data, err = aeb_get(driver, device, url_fav2)
    if data and data.RESULT and data.RESULT.OIL then
      local oil_list = make_array(data.RESULT.OIL)
      local oil_detail = oil_list[1]
      if oil_detail then
        local prices = make_array(oil_detail.OIL_PRICE)
        local found = false
        for _, p in ipairs(prices) do
          if p.PRODCD == oil_type then
            local val = string.format("%s원 - %s", format_comma(p.PRICE), clean_station_name(oil_detail.OS_NM))
            emit_event(device, cap_fav2.favStationTwo({ value = val }))
            emit_event(device, cap_fav2.favStationTwoNumeric({ value = math.floor(tonumber(p.PRICE) or 99999) }))
            found = true
            break
          end
        end
        if not found then
          emit_event(device, cap_fav2.favStationTwo({ value = (oil_detail.OS_NM or "주유소") .. " (유종 정보 없음)" }))
          emit_event(device, cap_fav2.favStationTwoNumeric({ value = 99999 }))
        end
      else
        emit_event(device, cap_fav2.favStationTwo({ value = "정보 파싱 에러" }))
        emit_event(device, cap_fav2.favStationTwoNumeric({ value = 99999 }))
      end
    else
      emit_event(device, cap_fav2.favStationTwo({ value = "에러: " .. (err or "조회 실패") }))
      emit_event(device, cap_fav2.favStationTwoNumeric({ value = 99999 }))
    end
  else
    emit_event(device, cap_fav2.favStationTwo({ value = "미설정" }))
    emit_event(device, cap_fav2.favStationTwoNumeric({ value = 0 }))
  end
end

------------------------------------------------------------
-- Command Handlers
------------------------------------------------------------
local function handle_refresh(driver, device, command)
  log.info("수동 유가 정보 새로고침 요청")
  poll_handler(driver, device)
end

------------------------------------------------------------
-- 지역코드 검색 결과 순환 교대 노출(롤링) 함수
------------------------------------------------------------
local function cycle_region_results(driver, device)
  local matches = device:get_field("region_search_matches")
  if not matches or #matches == 0 then return end

  local idx = device:get_field("region_search_index") or 1
  if idx > #matches then idx = 1 end

  local display_val = string.format("(%d/%d) %s", idx, #matches, matches[idx])
  local comp = device.profile.components.search
  if comp then
    emit_component_event(device, comp, cap_result.searchResult({ value = display_val }))
  end

  device:set_field("region_search_index", idx + 1)

  local timer = driver:call_with_delay(4, function()
    cycle_region_results(driver, device)
  end)
  device:set_field("region_alternate_timer", timer)
end

-- 지역코드 조회 텍스트 입력 처리기
local function handle_set_keyword(driver, device, command)
  local keyword = command.args.keyword
  log.info("지역코드 검색 요청 키워드: " .. tostring(keyword))

  local comp = device.profile.components.search
  if not comp then
    log.error("search 컴포넌트를 찾을 수 없습니다.")
    return
  end

  -- 키워드 상태 즉시 갱신
  emit_component_event(device, comp, cap_search.keyword({ value = keyword }))

  -- 기존 지역코드 교대 타이머 및 상태 해제
  local old_timer = device:get_field("region_alternate_timer")
  if old_timer then
    driver:cancel_timer(old_timer)
    device:set_field("region_alternate_timer", nil)
  end
  device:set_field("region_search_matches", nil)
  device:set_field("region_search_index", nil)

  if not keyword or keyword == "" then
    emit_component_event(device, comp, cap_result.searchResult({ value = "검색어를 입력해 주세요." }))
    return
  end

  -- 헬퍼 함수: 양방향 유연한 텍스트 매칭 검사
  local function is_match(name, kw)
    if not name or not kw then return false end
    return string.find(name, kw, 1, true) ~= nil or string.find(kw, name, 1, true) ~= nil
  end

  local matches = {}

  -- 로컬 area_codes 테이블에서 전국 검색 수행
  if area_codes then
    for sido_cd, sido_data in pairs(area_codes) do
      -- 1. 시도 매칭 검사
      if is_match(sido_data.name, keyword) then
        table.insert(matches, string.format("%s : %s", sido_data.name, sido_cd))
      end
      
      -- 2. 시군구 매칭 검사
      if sido_data.sigungu then
        for sigungu_cd, sigungu_nm in pairs(sido_data.sigungu) do
          if is_match(sigungu_nm, keyword) then
            -- 시도명과 시군구명을 결합하여 가독성 증대 (예: "인천 서구 : 1506")
            table.insert(matches, string.format("%s %s : %s", sido_data.name, sigungu_nm, sigungu_cd))
          end
        end
      end
    end
  end

  -- 정렬하여 일정한 순서로 노출되도록 함
  table.sort(matches)

  -- 결과 출력
  if #matches > 0 then
    if #matches == 1 then
      emit_component_event(device, comp, cap_result.searchResult({ value = matches[1] }))
    else
      device:set_field("region_search_matches", matches)
      device:set_field("region_search_index", 1)
      cycle_region_results(driver, device)
    end
  else
    emit_component_event(device, comp, cap_result.searchResult({ value = "검색 결과 없음" }))
  end
end

------------------------------------------------------------
-- 주유소코드 검색 결과 순환 교대 노출(롤링) 함수
------------------------------------------------------------
local function cycle_station_results(driver, device)
  local matches = device:get_field("station_search_matches")
  if not matches or #matches == 0 then return end

  local idx = device:get_field("station_search_index") or 1
  if idx > #matches then idx = 1 end

  local display_val = string.format("(%d/%d) %s", idx, #matches, matches[idx])
  local comp = device.profile.components.search
  if comp then
    emit_component_event(device, comp, cap_result.searchResult({ value = display_val }))
  end

  device:set_field("station_search_index", idx + 1)

  local timer = driver:call_with_delay(4, function()
    cycle_station_results(driver, device)
  end)
  device:set_field("station_alternate_timer", timer)
end

-- 주유소코드 조회 텍스트 입력 처리기
local function handle_set_station_keyword(driver, device, command)
  local keyword = command.args.stationKeyword
  log.info("주유소코드 검색 요청 키워드: " .. tostring(keyword))

  local comp = device.profile.components.search
  if not comp then
    log.error("search 컴포넌트를 찾을 수 없습니다.")
    return
  end

  -- 키워드 상태 즉시 갱신
  emit_component_event(device, comp, cap_station_search.stationKeyword({ value = keyword }))

  -- 기존 순환 교대 타이머 및 상태 해제
  local old_timer = device:get_field("station_alternate_timer")
  if old_timer then
    driver:cancel_timer(old_timer)
    device:set_field("station_alternate_timer", nil)
  end
  device:set_field("station_search_matches", nil)
  device:set_field("station_search_index", nil)

  if not keyword or keyword == "" then
    emit_component_event(device, comp, cap_result.searchResult({ value = "검색어를 입력해 주세요." }))
    return
  end

  local api_key   = pref(device, "opinetApiKey", DEFAULT_API_KEY)

  -- 상호명 주유소 검색 API 호출 (전국 단위 검색을 위해 area 제한 파라미터 제외)
  local url_station = string.format("https://www.opinet.co.kr/api/searchByName.do?code=%s&out=json&osnm=%s", api_key, url_encode(keyword))

  local data, err = aeb_get(driver, device, url_station)
  if data and data.RESULT and data.RESULT.OIL then
    local stations = make_array(data.RESULT.OIL)
    local matches = {}
    for _, item in ipairs(stations) do
      if item.OS_NM and item.UNI_ID then
        table.insert(matches, string.format("%s : %s", item.OS_NM, item.UNI_ID))
      end
    end

    if #matches > 0 then
      if #matches == 1 then
        emit_component_event(device, comp, cap_result.searchResult({ value = matches[1] }))
      else
        device:set_field("station_search_matches", matches)
        device:set_field("station_search_index", 1)
        cycle_station_results(driver, device)
      end
    else
      emit_component_event(device, comp, cap_result.searchResult({ value = "검색 결과 없음" }))
    end
  else
    emit_component_event(device, comp, cap_result.searchResult({ value = "에러: " .. (err or "조회 실패") }))
  end
end

------------------------------------------------------------
-- Lifecycle Handlers
------------------------------------------------------------
local function device_init(driver, device)
  log.debug(device.id .. " > INITIALIZING")

  -- 기본 상태 초기화
  emit_event(device, cap_conn_status.connStatus({ value = "대기 중..." }))
  emit_event(device, cap_national.nationalAvg({ value = "대기 중..." }))
  emit_event(device, cap_national.nationalAvgNumeric({ value = 99999 }))
  emit_event(device, cap_sido.sidoAvg({ value = "대기 중..." }))
  emit_event(device, cap_sido.sidoAvgNumeric({ value = 99999 }))
  emit_event(device, cap_sigungu.sigunguAvg({ value = "대기 중..." }))
  emit_event(device, cap_sigungu.sigunguAvgNumeric({ value = 99999 }))
  emit_event(device, cap_lowest.lowestPrice({ value = "대기 중..." }))
  emit_event(device, cap_lowest.lowestPriceNumeric({ value = 99999 }))
  emit_event(device, cap_fav1.favStationOne({ value = "대기 중..." }))
  emit_event(device, cap_fav1.favStationOneNumeric({ value = 99999 }))
  emit_event(device, cap_fav2.favStationTwo({ value = "대기 중..." }))
  emit_event(device, cap_fav2.favStationTwoNumeric({ value = 99999 }))

  local comp_search = device.profile.components.search
  if comp_search then
    emit_component_event(device, comp_search, cap_ref_region.refRegion({ value = "대기 중..." }))
    emit_component_event(device, comp_search, cap_search.keyword({ value = "" }))
    emit_component_event(device, comp_search, cap_station_search.stationKeyword({ value = "" }))
    emit_component_event(device, comp_search, cap_result.searchResult({ value = "검색 결과 대기 중" }))
  else
    log.error("search 컴포넌트를 찾을 수 없습니다.")
  end

  -- mDNS 탐색 시도
  discover_aeb(driver, device)

  -- 주기적 폴링 타이머 설정 (분 단위 -> 초 단위)
  local interval_min = tonumber(pref(device, "refreshInterval", 60)) or 60
  local interval_sec = interval_min * 60
  log.info(string.format("폴링 타이머 등록: %d초 (%d분) 마다 실행", interval_sec, interval_min))

  local poll_timer = driver:call_on_schedule(
    interval_sec,
    function()
      poll_handler(driver, device)
    end
  )
  device:set_field("poll_timer", poll_timer)

  -- 최초 실행 즉시 조회 실행
  poll_handler(driver, device)
end

local function device_added(driver, device)
  log.info(device.id .. " > ADDED")
end

local function device_removed(driver, device)
  log.warn(device.id .. " > REMOVED")
  local old_timer = device:get_field("poll_timer")
  if old_timer then
    driver:cancel_timer(old_timer)
  end
  local alt_timer = device:get_field("station_alternate_timer")
  if alt_timer then
    driver:cancel_timer(alt_timer)
  end
  local region_alt_timer = device:get_field("region_alternate_timer")
  if region_alt_timer then
    driver:cancel_timer(region_alt_timer)
  end
end

local function handler_infochanged(driver, device, event, args)
  log.debug("설정 변경 감지 핸들러 호출됨")
  local changed = false

  if args.old_st_store.preferences then
    local old_pref = args.old_st_store.preferences
    local new_pref = device.preferences

    -- 1. 폴링 주기 변경 여부 확인
    if old_pref.refreshInterval ~= new_pref.refreshInterval then
      local new_interval_min = tonumber(new_pref.refreshInterval) or 60
      local new_interval_sec = new_interval_min * 60
      log.info(string.format("폴링 간격 변경 감지 -> %d분 (%d초)", new_interval_min, new_interval_sec))
      
      local old_timer = device:get_field("poll_timer")
      if old_timer then
        driver:cancel_timer(old_timer)
      end
      
      local poll_timer = driver:call_on_schedule(
        new_interval_sec,
        function()
          poll_handler(driver, device)
        end
      )
      device:set_field("poll_timer", poll_timer)
      changed = true
    end

    -- 2. 다른 핵심 설정값(API Key, 시도/시군구 코드, 유종, 단골 코드) 변경 감지
    if old_pref.opinetApiKey ~= new_pref.opinetApiKey or
       old_pref.sidoCode ~= new_pref.sidoCode or
       old_pref.sigunguCode ~= new_pref.sigunguCode or
       old_pref.oilType ~= new_pref.oilType or
       old_pref.favGasStation1 ~= new_pref.favGasStation1 or
       old_pref.favGasStation2 ~= new_pref.favGasStation2 or
       old_pref.aebAutoSearch ~= new_pref.aebAutoSearch or
       old_pref.aebIp ~= new_pref.aebIp or
       old_pref.aebPort ~= new_pref.aebPort then
      log.info("핵심 설정 파라미터 변경 감지")
      if old_pref.aebAutoSearch ~= new_pref.aebAutoSearch or
         old_pref.aebIp ~= new_pref.aebIp or
         old_pref.aebPort ~= new_pref.aebPort then
        device:set_field("discovered_aeb_ip", nil) -- 캐시된 IP 초기화
        discover_aeb(driver, device)
      end
      changed = true
    end
  end

  if changed then
    log.info("설정이 변경되었습니다. 즉시 오피넷 폴링 조회를 시작합니다.")
    poll_handler(driver, device)
  end
end

------------------------------------------------------------
-- Discovery Handler (LAN 방식)
------------------------------------------------------------
local function discovery_handler(driver, _, should_continue)
  log.info("discovery_handler 실행 - 오피넷 유가정보 모니터 기기 생성 시도")
  
  local create_device_msg = {
    type                  = "LAN",
    device_network_id     = "opinet_oil_price_monitor_singleton",
    label                 = "오피넷 유가정보 모니터",
    profile               = "opinet-monitor",
    manufacturer          = "Custom",
    model                 = "Opinet-Oil-Monitor",
    vendor_provided_label = "오피넷 유가정보 모니터",
  }

  local ok, err = pcall(function()
    assert(driver:try_create_device(create_device_msg), "기기 생성 실패")
  end)

  if ok then
    log.info("오피넷 유가정보 모니터 기기 생성 성공")
  else
    log.error("오피넷 기기 생성 중 오류 발생: " .. tostring(err))
  end
end

------------------------------------------------------------
-- Driver 등록
------------------------------------------------------------
local opinetDriver = Driver("opinet-oil-price-monitor-v1", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init        = device_init,
    added       = device_added,
    removed     = device_removed,
    infoChanged = handler_infochanged,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [cap_search.ID] = {
      [cap_search.commands.setKeyword.NAME] = handle_set_keyword,
    },
    [cap_station_search.ID] = {
      [cap_station_search.commands.setStationKeyword.NAME] = handle_set_station_keyword,
    }
  }
})

log.info("Opinet Oil Price Monitor Driver Starting...")
opinetDriver:run()
