#!/usr/bin/env bash
#
# verify_manifest.sh — 매니페스트의 URL 생존 여부와 실제 크기를 사전 검증합니다.
#
# 목적:
#   1) 죽은 URL을 Pod 띄우기 전에 색출 (다운로드 90% 지점 사망 방지)
#   2) 실측 바이트를 확보 -> 부트스트랩의 멱등성 검사 기준
#   3) 트랙별 총량 집계 -> Pod 디스크 프로비저닝 수치 산출
#
# 사용법:
#   ./verify_manifest.sh                    # 검증만
#   ./verify_manifest.sh --fix              # bytes 컬럼 자동 기입
#   ./verify_manifest.sh -m other.tsv       # 다른 매니페스트 지정
#
# 토큰 (게이트된 저장소 / Civitai 용, 선택):
#   export HF_TOKEN=hf_xxx
#   export CIVITAI_TOKEN=xxx
#
set -uo pipefail

MANIFEST="manifest.tsv"
FIX=0
TIMEOUT=45

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)      FIX=1; shift ;;
    -m|--manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

# 스크립트가 scripts/ 안에 있어도 레포 루트의 매니페스트를 찾도록
if [[ ! -f "$MANIFEST" ]]; then
  alt="$(cd "$(dirname "$0")/.." && pwd)/$MANIFEST"
  [[ -f "$alt" ]] && MANIFEST="$alt"
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "매니페스트를 찾을 수 없습니다: $MANIFEST" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# URL 하나의 크기를 조회. 성공 시 바이트 수를 stdout 으로, 실패 시 빈 문자열.
# HF 의 LFS 파일은 리다이렉트되므로 -L 로 따라가고, x-linked-size 를 우선합니다.
# HEAD 를 거부하는 서버는 1바이트 range GET 으로 폴백합니다.
# ---------------------------------------------------------------------------
probe() {
  local url="$1" hdrs auth=() size code

  case "$url" in
    *huggingface.co*) [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN") ;;
    *civitai.com*)    [[ -n "${CIVITAI_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $CIVITAI_TOKEN") ;;
  esac

  # 1차: HEAD
  hdrs="$(curl -sIL --max-time "$TIMEOUT" "${auth[@]}" "$url" 2>/dev/null)"
  code="$(printf '%s' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^HTTP\//{c=$2} END{print c}')"

  if [[ "$code" != "200" ]]; then
    # 2차: range GET 폴백 (HEAD 거부 서버 대응)
    hdrs="$(curl -sL -r 0-0 -D - -o /dev/null --max-time "$TIMEOUT" "${auth[@]}" "$url" 2>/dev/null)"
    code="$(printf '%s' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^HTTP\//{c=$2} END{print c}')"
    [[ "$code" == "200" || "$code" == "206" ]] || { echo ""; return 1; }
    # Content-Range: bytes 0-0/12345  -> 총 크기는 슬래시 뒤
    size="$(printf '%s' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^content-range:/{n=split($0,a,"/"); gsub(/[^0-9]/,"",a[n]); print a[n]}' | tail -1)"
    [[ -n "$size" ]] && { echo "$size"; return 0; }
    echo ""; return 1
  fi

  # x-linked-size (HF LFS 실제 크기) 우선
  size="$(printf '%s' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^x-linked-size:/{gsub(/[^0-9]/,"",$2); print $2}' | tail -1)"
  [[ -z "$size" ]] && size="$(printf '%s' "$hdrs" | awk 'BEGIN{IGNORECASE=1} /^content-length:/{gsub(/[^0-9]/,"",$2); print $2}' | tail -1)"

  [[ -n "$size" && "$size" != "0" ]] && { echo "$size"; return 0; }
  echo ""; return 1
}

gb() { awk -v b="$1" 'BEGIN{ if (b+0==0) print "  -   "; else printf "%6.2f", b/1073741824 }'; }

# ---------------------------------------------------------------------------
printf '매니페스트: %s\n\n' "$MANIFEST"
printf '%-10s %-6s %-9s %s\n' "TRACK" "STAGE" "SIZE(GB)" "FILE"
printf '%s\n' "----------------------------------------------------------------------"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
declare -A TRACK_TOTAL
fail=0; todo=0; ok=0

while IFS=$'\t' read -r track stage dest filename url bytes || [[ -n "${track:-}" ]]; do
  [[ -z "${track:-}" || "${track:0:1}" == "#" ]] && { printf '%s\n' "$track	$stage	$dest	$filename	$url	$bytes" >> "$TMP" 2>/dev/null || true; continue; }

  if [[ "$url" == TODO* ]]; then
    printf '%-10s %-6s %-9s %s  <-- URL 미확정 (%s)\n' "$track" "$stage" "TODO" "$filename" "$url"
    todo=$((todo+1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$track" "$stage" "$dest" "$filename" "$url" "$bytes" >> "$TMP"
    continue
  fi

  size="$(probe "$url")"
  if [[ -z "$size" ]]; then
    printf '%-10s %-6s %-9s %s  <-- 실패 (URL 확인 필요)\n' "$track" "$stage" "FAIL" "$filename"
    fail=$((fail+1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$track" "$stage" "$dest" "$filename" "$url" "$bytes" >> "$TMP"
  else
    printf '%-10s %-6s %-9s %s\n' "$track" "$stage" "$(gb "$size")" "$filename"
    ok=$((ok+1))
    TRACK_TOTAL[$track]=$(( ${TRACK_TOTAL[$track]:-0} + size ))
    if [[ -n "$bytes" && "$bytes" != "0" && "$bytes" != "$size" ]]; then
      printf '%-10s %-6s %-9s   ^ 경고: 기록된 크기(%s)와 다름\n' "" "" "" "$bytes"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$track" "$stage" "$dest" "$filename" "$url" "$size" >> "$TMP"
  fi
done < "$MANIFEST"

# ---------------------------------------------------------------------------
common=${TRACK_TOTAL[common]:-0}
anime=${TRACK_TOTAL[anime]:-0}
realistic=${TRACK_TOTAL[realistic]:-0}

printf '\n%s\n' "== 트랙별 다운로드 총량 (확인된 것만) =========================="
printf '  common          %s GB\n' "$(gb $common)"
printf '  anime  (+공용)  %s GB\n' "$(gb $((common + anime)))"
printf '  realistic(+공용) %s GB\n' "$(gb $((common + realistic)))"
printf '  both            %s GB\n' "$(gb $((common + anime + realistic)))"

printf '\n%s\n' "== 권장 볼륨 디스크 (총량 x 1.4 + 여유 10GB) =================="
for t in anime realistic both; do
  case $t in
    anime)     s=$((common + anime)) ;;
    realistic) s=$((common + realistic)) ;;
    both)      s=$((common + anime + realistic)) ;;
  esac
  awk -v s="$s" -v n="$t" 'BEGIN{ if (s==0) {printf "  %-10s  (측정 불가)\n", n} else {printf "  %-10s  %d GB\n", n, int(s/1073741824*1.4)+10} }'
done

printf '\n결과: 정상 %d / 실패 %d / 미확정 %d\n' "$ok" "$fail" "$todo"

if [[ $FIX -eq 1 ]]; then
  cp "$MANIFEST" "${MANIFEST}.bak"
  cp "$TMP" "$MANIFEST"
  printf '\nbytes 컬럼을 기입했습니다. 백업: %s.bak\n' "$MANIFEST"
  printf '주의: 주석 줄의 정렬이 흐트러질 수 있으니 diff 로 확인하세요.\n'
fi

if [[ $fail -gt 0 || $todo -gt 0 ]]; then
  printf '\n미해결 항목이 있습니다. 전부 정상이 되기 전에는 Pod 을 띄우지 마세요.\n'
  exit 1
fi
printf '\n전부 정상입니다. 2단계로 진행하세요.\n'
