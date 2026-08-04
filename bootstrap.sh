#!/usr/bin/env bash
#
# bootstrap.sh — RunPod Pod 에서 ComfyUI 작업 환경을 1회 구성합니다.
#
# 설계 원칙 (합의된 4개):
#   1) 스크립트 1개 + 트랙 인자          (anime / realistic / both)
#   2) 가장 큰 다운로드를 백그라운드 선행 (네트워크 병목과 CPU 병목을 겹침)
#   3) 트랙별 디스크 프로비저닝           (프리플라이트에서 부족하면 즉시 중단)
#   4) wget 목적지 직접 다운로드          (HF 캐시 이중 점유 회피)
#
# 사용법:
#   bash bootstrap.sh anime
#   bash bootstrap.sh realistic --jobs 2
#   bash bootstrap.sh both --strict
#
# 옵션:
#   --jobs N       동시 다운로드 수 (기본 3)
#   --strict       TODO/누락 항목이 있으면 진행하지 않음
#   --skip-nodes   커스텀 노드 설치 건너뛰기 (모델만 다시 받을 때)
#   --update-comfy ComfyUI git pull 시도 (기본 꺼짐 — 아래 설명 참고)
#   --quiet-dl     다운로드 진행률 표시 끄기
#   --dry-run      실제 다운로드/설치 없이 계획만 출력
#
# ComfyUI 업데이트가 기본 꺼짐인 이유:
#   RunPod 공식 ComfyUI 템플릿은 검증된 커밋에 detached HEAD 로 고정돼 있습니다.
#   추적 브랜치가 없어 git pull 이 실패하고, 억지로 최신으로 끌어올리면
#   템플릿이 검증한 조합(CUDA/torch/노드)을 깨뜨릴 위험만 생깁니다.
#   템플릿이 이미 버전을 고정해 주므로 재현성 측면에서도 이쪽이 낫습니다.
#   직접 빌드한 이미지처럼 추적 브랜치가 있는 환경에서만 --update-comfy 를 쓰세요.
#
# 환경변수:
#   COMFY_ROOT       ComfyUI 경로 자동탐지 실패 시 직접 지정
#   COMFY_PYTHON     파이썬 자동탐지 실패 시 직접 지정 (venv 의 bin/python)
#   HF_TOKEN         게이트된 HF 저장소용 (선택)
#   CIVITAI_TOKEN     civitai.com 다운로드 URL 인증용
#                     Civitai 계정 -> Settings -> API Keys 에서 발급
#                     매니페스트의 civitai.com URL 에 자동으로 붙습니다
#
set -uo pipefail

# ---------------------------------------------------------------------------
# 이 스크립트는 Pod(리눅스) 전용입니다. 백그라운드 디스패처가 `wait -n`(bash 4.3+)에
# 의존하고, 경로 탐지/디스크 검사도 컨테이너를 전제로 합니다.
# macOS 기본 bash 는 3.2 라 여기서 걸립니다. 로컬 검증용 도구는
# verify_manifest.sh 와 check_workflow.py 쪽입니다.
# ---------------------------------------------------------------------------
if [[ -z "${BASH_VERSINFO:-}" ]] || (( BASH_VERSINFO[0] < 4 )) \
   || { (( BASH_VERSINFO[0] == 4 )) && (( BASH_VERSINFO[1] < 3 )); }; then
  echo "이 스크립트는 bash 4.3 이상이 필요합니다 (현재: ${BASH_VERSION:-unknown})" >&2
  echo "  bootstrap.sh 는 RunPod Pod 안에서 실행하는 용도입니다." >&2
  echo "  로컬 검증은 verify_manifest.sh / check_workflow.py 를 쓰세요." >&2
  exit 1
fi

# ===========================================================================
# 커스텀 노드 정의
#
# COMMIT 을 비워두면 기본 브랜치를 따라갑니다. ComfyUI 코어는 "항상 최신"으로
# 결정했지만, 노드는 코어보다 훨씬 자주 깨집니다. 한 번 정상 동작을 확인한
# 뒤에는 그때의 커밋 해시를 여기 박아 고정하세요. (bootstrap 이 세션 종료 시
# 현재 커밋을 로그에 남기므로 그 값을 그대로 복사하면 됩니다.)
# ===========================================================================
NODES_COMMON=(
  "ComfyUI-Manager|https://github.com/Comfy-Org/ComfyUI-Manager.git|"
)
NODES_REALISTIC=(
  "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes.git|"
  "comfyui_controlnet_aux|https://github.com/Fannovel16/comfyui_controlnet_aux.git|"
  "ComfyUI-segment-anything-2|https://github.com/kijai/ComfyUI-segment-anything-2.git|"
)
# 애니 트랙은 내장 템플릿만 쓰므로 추가 노드가 없습니다.
NODES_ANIME=(
  "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|"
)

# ===========================================================================
TRACK=""
JOBS=3
STRICT=0
SKIP_NODES=0
UPDATE_COMFY=0
QUIET_DL=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    anime|realistic|both) TRACK="$1"; shift ;;
    --jobs)         JOBS="${2:-3}"; shift 2 ;;
    --strict)       STRICT=1; shift ;;
    --skip-nodes)   SKIP_NODES=1; shift ;;
    --update-comfy) UPDATE_COMFY=1; shift ;;
    --skip-update)  shift ;;   # 하위호환: 이제 기본이 건너뛰기라 무시
    --quiet-dl)     QUIET_DL=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TRACK" ]]; then
  echo "트랙을 지정하세요: anime | realistic | both" >&2
  echo "  예) bash bootstrap.sh anime" >&2
  exit 2
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$REPO_DIR/manifest.tsv"
LOG_DIR="$REPO_DIR/logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
START_EPOCH="$(date +%s)"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap_${TRACK}_${STAMP}.log"

log()  { printf '%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '  ! %s\n' "$*" | tee -a "$LOG" >&2; }
die()  { printf '\n중단: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

log "=========================================================="
log " bootstrap  track=$TRACK  jobs=$JOBS  $(date '+%F %T')"
log " log: $LOG"
log "=========================================================="

[[ -f "$MANIFEST" ]] || die "매니페스트가 없습니다: $MANIFEST"

# CRLF 방어. 읽기용 정규화 사본에서만 파싱합니다.
NORM="$(mktemp)"; PLAN="$(mktemp)"
trap 'rm -f "$NORM" "$PLAN"' EXIT
if grep -q $'\r' "$MANIFEST"; then
  warn "매니페스트가 CRLF 입니다. 읽기는 정규화하지만 .gitattributes 로 LF 를 강제하세요."
fi
tr -d '\r' < "$MANIFEST" > "$NORM"

# ===========================================================================
# 1. ComfyUI 경로 탐지
#    템플릿마다 설치 위치가 다르고, 볼륨 밖에 깔려 있으면 Terminate 시
#    전부 사라집니다. 여기서 확실히 잡고 갑니다.
# ===========================================================================
detect_comfy() {
  [[ -n "${COMFY_ROOT:-}" ]] && { echo "$COMFY_ROOT"; return; }
  local c
  for c in /workspace/ComfyUI /workspace/comfyui /ComfyUI /comfyui \
           /opt/ComfyUI /root/ComfyUI "$HOME/ComfyUI"; do
    [[ -f "$c/main.py" ]] && { echo "$c"; return; }
  done
  # 마지막 수단: main.py 를 얕게 탐색
  c="$(find /workspace / -maxdepth 3 -name main.py -path '*omfy*' 2>/dev/null | head -1)"
  [[ -n "$c" ]] && { dirname "$c"; return; }
  echo ""
}

COMFY="$(detect_comfy)"
[[ -n "$COMFY" ]] || die "ComfyUI 경로를 찾지 못했습니다. COMFY_ROOT=/경로 로 지정하세요."
log ""
log "[1/6] ComfyUI 경로"
log "      $COMFY"

MODELS="$COMFY/models"
mkdir -p "$MODELS"

# /workspace 아래인지 = Terminate 후에도 남는 위치인지 확인
case "$COMFY" in
  /workspace/*) log "      /workspace 하위 (정상)" ;;
  *) warn "ComfyUI 가 /workspace 밖에 있습니다. 볼륨을 쓰신다면 여기 받은 모델은 Pod 삭제 시 사라집니다." ;;
esac

# clip_vision vs clip_visions 자동 감지
CLIP_DIR="clip_vision"
if [[ -d "$MODELS/clip_visions" && ! -d "$MODELS/clip_vision" ]]; then
  CLIP_DIR="clip_visions"
fi
log "      clip vision 디렉토리: $CLIP_DIR"

# ===========================================================================
# 2. 다운로드 계획 수립 (트랙 필터 + 멱등성 판정 + 큰 것부터 정렬)
# ===========================================================================
log ""
log "[2/6] 다운로드 계획"

todo_rows=0; skip_rows=0; need_bytes=0
while IFS=$'\t' read -r track stage dest filename url bytes || [[ -n "${track:-}" ]]; do
  [[ -z "${track:-}" || "${track:0:1}" == "#" ]] && continue
  [[ "$track" == "common" || "$track" == "$TRACK" || "$TRACK" == "both" ]] || continue

  if [[ "$url" == TODO* ]]; then
    warn "URL 미확정, 건너뜁니다: $filename ($url)"
    todo_rows=$((todo_rows+1))
    continue
  fi

  [[ "$dest" == "clip_vision" || "$dest" == "clip_visions" ]] && dest="$CLIP_DIR"
  target="$MODELS/$dest/$filename"

  if [[ -f "$target" ]]; then
    actual="$(stat -c %s "$target" 2>/dev/null || stat -f %z "$target" 2>/dev/null || echo 0)"
    if [[ "$bytes" == "0" ]]; then
      # 매니페스트에 기대 크기가 없어 검증 불가. wget -c 가 원격 크기와
      # 비교해 완결이면 즉시 종료하므로 재전송은 일어나지 않습니다.
      warn "크기 미검증(bytes=0), wget -c 로 확인: $filename  <- verify_manifest.sh --fix 를 먼저 돌리세요"
    elif [[ "$actual" == "$bytes" ]]; then
      skip_rows=$((skip_rows+1)); continue          # 완전 일치 -> 건너뜀
    else
      warn "크기 불일치, 이어받기: $filename (로컬 $actual / 기대 $bytes)"
    fi
  fi

  printf '%s\t%s\t%s\t%s\n' "${bytes:-0}" "$target" "$url" "$filename" >> "$PLAN"
  need_bytes=$(( need_bytes + ${bytes:-0} ))
done < "$NORM"

# 큰 파일부터: 가장 무거운 전송을 먼저 백그라운드에 띄워야 뒤의 CPU 작업에 가려집니다
if [[ -s "$PLAN" ]]; then
  sort -t$'\t' -k1,1nr -o "$PLAN" "$PLAN"
fi
dl_count=$(wc -l < "$PLAN" | tr -d ' ')

log "      받을 파일 $dl_count 개 / 이미 있음 $skip_rows 개 / 미확정 $todo_rows 개"
log "      필요 용량 $(awk -v b="$need_bytes" 'BEGIN{printf "%.2f", b/1073741824}') GiB"

if [[ $todo_rows -gt 0 && $STRICT -eq 1 ]]; then
  die "--strict: URL 미확정 항목이 $todo_rows 개 있습니다."
fi

# ===========================================================================
# 3. 프리플라이트 — 30초 안에 실패를 알아야 합니다
# ===========================================================================
log ""
log "[3/6] 프리플라이트"

avail_kb="$(df -Pk "$MODELS" | awk 'NR==2{print $4}')"
avail_b=$(( avail_kb * 1024 ))
log "      디스크 여유 $(awk -v b="$avail_b" 'BEGIN{printf "%.1f", b/1073741824}') GiB"
if [[ $need_bytes -gt 0 ]]; then
  # 생성 중 임시파일/출력물 여유로 5GiB 를 더 요구합니다
  require=$(( need_bytes + 5 * 1073741824 ))
  if [[ $avail_b -lt $require ]]; then
    die "디스크 부족. 필요 $(awk -v b="$require" 'BEGIN{printf "%.1f",b/1073741824}') GiB / 여유 $(awk -v b="$avail_b" 'BEGIN{printf "%.1f",b/1073741824}') GiB
     Pod 을 더 큰 볼륨 디스크로 다시 배포하세요."
  fi
fi

command -v wget >/dev/null || die "wget 이 없습니다. apt-get install -y wget"
command -v git  >/dev/null || die "git 이 없습니다."

# ComfyUI 가 실제로 쓰는 파이썬을 찾습니다.
# 템플릿이 venv 를 쓰는데 시스템 python 에 설치하면 노드가 의존성을 못 찾아
# 기동 시 조용히 import 에러가 납니다. 가장 잡기 어려운 종류의 실패입니다.
detect_python() {
  local c
  # 사용자가 직접 지정한 경우 최우선
  [[ -n "${COMFY_PYTHON:-}" && -x "${COMFY_PYTHON}" ]] && { echo "$COMFY_PYTHON"; return; }
  # 고정 이름 우선
  for c in "$COMFY/venv/bin/python" "$COMFY/.venv/bin/python" \
           /workspace/venv/bin/python /workspace/.venv/bin/python; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  # 접미사가 붙은 venv (RunPod 템플릿의 .venv-cu128 등)
  for c in "$COMFY"/.venv*/bin/python "$COMFY"/venv*/bin/python \
           /workspace/.venv*/bin/python /workspace/venv*/bin/python; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  # 기동 스크립트에 적힌 venv 를 마지막 단서로 사용
  c="$(grep -rhoE '(source|\.) +[^ ]*/(\.?venv[^ /]*)/bin/activate' \
        "$COMFY"/*.sh /workspace/*.sh 2>/dev/null | head -1 \
        | grep -oE '[^ ]*/bin/activate' | sed 's|/activate$|/python|')"
  [[ -n "$c" && -x "$c" ]] && { echo "$c"; return; }
  command -v python3 || command -v python
}
PY="$(detect_python)"
[[ -n "$PY" ]] || die "파이썬을 찾지 못했습니다."
log "      python: $PY"

# venv 가 있는데 시스템 파이썬을 고르면 노드 의존성이 ComfyUI 가 보지 못하는
# 곳에 설치되고, 최악의 경우 시스템 torch 를 건드려 ComfyUI 가 기동조차
# 못 하게 됩니다. 조용히 넘어가면 원인 추적이 매우 어려우므로 크게 알립니다.
case "$PY" in
  *venv*) ;;
  *)
    if compgen -G "$COMFY/.venv*" >/dev/null 2>&1 || compgen -G "$COMFY/venv*" >/dev/null 2>&1; then
      warn "venv 가 존재하는데 시스템 파이썬을 선택했습니다. 노드 의존성이 엉뚱한"
      warn "  곳에 설치됩니다. COMFY_PYTHON=/경로/bin/python 으로 지정하고 다시 실행하세요."
      warn "  후보: $(ls -d "$COMFY"/.venv* "$COMFY"/venv* 2>/dev/null | tr '\n' ' ')"
    fi
    ;;
esac

# PEP 668(externally-managed-environment) 대응. venv 면 불필요하지만
# 시스템 파이썬이면 --break-system-packages 가 필요합니다.
PIP_EXTRA=""
if ! "$PY" -m pip install --dry-run --quiet --no-input pip >/dev/null 2>&1; then
  if "$PY" -m pip install --dry-run --quiet --no-input --break-system-packages pip >/dev/null 2>&1; then
    PIP_EXTRA="--break-system-packages"
    log "      pip: --break-system-packages 사용 (시스템 파이썬)"
  fi
fi
if command -v nvidia-smi >/dev/null; then
  log "      GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
else
  warn "nvidia-smi 없음. GPU 미인식 상태일 수 있습니다."
fi

if [[ $DRY -eq 1 ]]; then
  log ""
  log "[dry-run] 다음을 받을 예정입니다:"
  awk -F'\t' '{printf "  %8.2f GiB  %s\n", $1/1073741824, $4}' "$PLAN" | tee -a "$LOG"
  log ""
  log "[dry-run] 종료. 실제 실행은 --dry-run 을 빼고 다시 돌리세요."
  exit 0
fi

# ===========================================================================
# 4. 다운로드 백그라운드 착수 (여기서 즉시 시작해야 5~7분이 나옵니다)
# ===========================================================================
log ""
log "[4/6] 다운로드 시작 (백그라운드, 동시 $JOBS)"

DL_LOG_DIR="$LOG_DIR/downloads_$STAMP"
mkdir -p "$DL_LOG_DIR"
FAIL_FLAG="$(mktemp)"

download_one() {
  local bytes="$1" target="$2" url="$3" name="$4"
  local auth=() prog=(-q)
  case "$url" in
    *huggingface.co*) [[ -n "${HF_TOKEN:-}" ]] && auth=(--header="Authorization: Bearer $HF_TOKEN") ;;
    *civitai.com*)    [[ -n "${CIVITAI_TOKEN:-}" ]] && auth=(--header="Authorization: Bearer $CIVITAI_TOKEN") ;;
  esac
  # 진행률: 로그 파일로 가므로 병렬 출력이 섞이지 않습니다.
  # tail -f 로 개별 파일 진행을 볼 수 있게 하는 것이 목적입니다.
  [[ $QUIET_DL -eq 0 ]] && prog=(-q --show-progress --progress=dot:giga)
  mkdir -p "$(dirname "$target")"
  if wget -c "${prog[@]}" --tries=3 --timeout=60 ${auth[@]+"${auth[@]}"} -O "$target" "$url" \
        >"$DL_LOG_DIR/$name.log" 2>&1; then
    if [[ "$bytes" != "0" ]]; then
      local got; got="$(stat -c %s "$target" 2>/dev/null || echo 0)"
      if [[ "$got" != "$bytes" ]]; then
        echo "$name 크기 불일치 (기대 $bytes / 실제 $got)" >> "$FAIL_FLAG"
        return 1
      fi
    fi
    return 0
  fi
  echo "$name 다운로드 실패 (로그: $DL_LOG_DIR/$name.log)" >> "$FAIL_FLAG"
  return 1
}

# ---------------------------------------------------------------------------
# 디스패처를 백그라운드로 통째로 분리합니다.
#
# 이전 버전은 이 자리에서 동시 실행 수를 기다렸습니다. 그래서 파일이 JOBS 개를
# 넘으면 4번째부터 이 루프에 갇혀, 아래 [5/6] 의 CPU 작업이 다운로드가 끝날
# 때까지 시작조차 못 했습니다. 병렬화의 목적이 정확히 무산되는 구조였습니다.
# 이제 대기는 디스패처 안에서만 일어나고 메인 셸은 즉시 다음 단계로 갑니다.
# ---------------------------------------------------------------------------
DISPATCH_PID=""
if [[ $dl_count -gt 0 ]]; then
  while IFS=$'\t' read -r bytes target url name; do
    log "      -> $name ($(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1073741824}') GiB)"
  done < "$PLAN"

  (
    running=0
    while IFS=$'\t' read -r bytes target url name; do
      while (( running >= JOBS )); do
        wait -n 2>/dev/null || true
        running=$((running-1))
      done
      download_one "$bytes" "$target" "$url" "$name" &
      running=$((running+1))
    done < "$PLAN"
    wait
  ) &
  DISPATCH_PID=$!
  log "      (백그라운드 진행. 개별 진행률: tail -f $DL_LOG_DIR/<파일명>.log)"
else
  log "      받을 파일이 없습니다 (전부 캐시됨)"
fi

# ===========================================================================
# 5. 다운로드가 도는 동안 CPU 작업 진행 — 이게 병렬화의 핵심입니다
# ===========================================================================
log ""
log "[5/6] ComfyUI 최신화 + 커스텀 노드 (다운로드와 병행)"

if [[ $UPDATE_COMFY -eq 1 && -d "$COMFY/.git" ]]; then
  if ( cd "$COMFY" && git pull --ff-only ) >>"$LOG" 2>&1; then
    log "      ComfyUI git pull 완료"
  else
    warn "ComfyUI git pull 실패 (계속 진행)"
    warn "  추적 브랜치가 없는 detached HEAD 일 수 있습니다. 템플릿이 버전을"
    warn "  고정한 것이므로 정상이며, --update-comfy 를 빼고 쓰시면 됩니다."
  fi
else
  log "      ComfyUI 업데이트 건너뜀 (템플릿 고정 버전 사용)"
fi

install_node() {
  local name="$1" repo="$2" commit="$3"
  local dir="$COMFY/custom_nodes/$name"
  if [[ -d "$dir/.git" ]]; then
    ( cd "$dir" && git fetch -q --all && \
      { [[ -n "$commit" ]] && git checkout -q "$commit" || git pull -q --ff-only; } ) >>"$LOG" 2>&1
    log "      = $name (기존)"
  else
    git clone -q "$repo" "$dir" >>"$LOG" 2>&1 || { warn "$name clone 실패"; return 1; }
    [[ -n "$commit" ]] && ( cd "$dir" && git checkout -q "$commit" ) >>"$LOG" 2>&1
    log "      + $name (신규)"
  fi
  if [[ -f "$dir/requirements.txt" ]]; then
    if "$PY" -m pip install -q --no-input $PIP_EXTRA -r "$dir/requirements.txt" >>"$LOG" 2>&1; then
      log "        deps ok"
    else
      warn "$name requirements 설치 실패 — 이 노드는 기동 시 import 에러가 날 수 있습니다"
      warn "  로그: grep -A5 'ERROR' $LOG"
    fi
  fi
}

if [[ $SKIP_NODES -eq 0 ]]; then
  mkdir -p "$COMFY/custom_nodes"
  nodes=("${NODES_COMMON[@]}")
  [[ "$TRACK" == "realistic" || "$TRACK" == "both" ]] && nodes+=("${NODES_REALISTIC[@]}")
  [[ "$TRACK" == "anime"     || "$TRACK" == "both" ]] && nodes+=("${NODES_ANIME[@]:-}")
  for spec in "${nodes[@]}"; do
    [[ -z "$spec" ]] && continue
    IFS='|' read -r n r c <<< "$spec"
    install_node "$n" "$r" "$c"
  done
else
  log "      커스텀 노드 설치 건너뜀"
fi

# 워크플로우 JSON 배치
WF_SRC="$REPO_DIR/workflows"
WF_DST="$COMFY/user/default/workflows"
if [[ -d "$WF_SRC" ]]; then
  mkdir -p "$WF_DST"
  cp -f "$WF_SRC"/*.json "$WF_DST"/ 2>/dev/null \
    && log "      워크플로우 JSON 배치 완료 -> $WF_DST" \
    || warn "워크플로우 JSON 이 없습니다 ($WF_SRC)"
fi

# ===========================================================================
# 6. 다운로드 완료 대기 + 검증
# ===========================================================================
log ""
log "[6/6] 다운로드 완료 대기"
rc=0
if [[ -n "$DISPATCH_PID" ]]; then
  wait "$DISPATCH_PID" || rc=1
fi

# 실측 처리량 기록. 다음 세션의 GPU/리전 선택과 --jobs 조정 근거가 됩니다.
ELAPSED=$(( $(date +%s) - START_EPOCH ))
if [[ $need_bytes -gt 0 && $ELAPSED -gt 0 ]]; then
  log "      소요 $((ELAPSED/60))분 $((ELAPSED%60))초 / 평균 $(awk -v b="$need_bytes" -v s="$ELAPSED" 'BEGIN{printf "%.1f", b/s/1048576}') MB/s"
fi

if [[ -s "$FAIL_FLAG" ]]; then
  log ""
  log "실패한 항목:"
  sed 's/^/  - /' "$FAIL_FLAG" | tee -a "$LOG"
  log ""
  log "이 스크립트는 멱등합니다. 그대로 다시 실행하면 받은 것은 건너뛰고"
  log "실패분만 이어받습니다."
  rm -f "$FAIL_FLAG"
  exit 1
fi
rm -f "$FAIL_FLAG"

# 버전 기록 — "항상 최신" 정책의 대가를 상환하는 부분입니다.
# 카나리 결과가 달라졌을 때 무엇이 바뀌었는지 여기서 답이 나옵니다.
{
  echo ""
  echo "--- 버전 스냅샷 ($(date '+%F %T')) ---"
  echo "ComfyUI: $( (cd "$COMFY" && git rev-parse --short HEAD) 2>/dev/null || echo 'n/a' )"
  for d in "$COMFY"/custom_nodes/*/; do
    [[ -d "$d/.git" ]] || continue
    printf '%-32s %s\n' "$(basename "$d")" "$( (cd "$d" && git rev-parse --short HEAD) 2>/dev/null )"
  done
} | tee -a "$LOG"

log ""
log "=========================================================="
log " 완료. track=$TRACK"
[[ $todo_rows -gt 0 ]] && log " 주의: URL 미확정 $todo_rows 개는 받지 않았습니다."
log ""
log " 다음: ComfyUI 재시작 후 8188 포트 접속"
log "   1) 워크플로우 로드 -> 빨간 노드 0개 확인"
log "   2) 각 로더 드롭다운에 모델이 보이는지 확인"
log "   3) 애니: 480p / 81프레임 / 4스텝 / LoRA strength 1.0"
log "      실사: 3~5초 입력, 포즈 프리뷰부터 눈으로 확인"
log "=========================================================="
exit $rc