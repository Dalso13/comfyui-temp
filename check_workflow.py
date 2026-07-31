#!/usr/bin/env python3
"""
check_workflow.py — 워크플로우 JSON 을 매니페스트와 대조 검증합니다.

Pod 을 띄우기 전에 로컬에서 돌리는 것이 목적입니다. GPU 요금 0원 구간에서
잡을 수 있는 실수를 여기서 전부 걸러냅니다.

검사 항목:
  1) 워크플로우가 참조하는 모델 파일이 매니페스트에 있는가
     -> 없으면 Pod 에서 로더 드롭다운이 비어 있게 됩니다
  2) 매니페스트에 있는데 워크플로우가 안 쓰는 파일은 무엇인가
     -> 헛되이 받는 용량
  3) high/low noise LoRA 가 올바른 샘플러 쪽에 물려 있는가
     -> 어긋나면 고스팅(이중 노출)이 납니다. 눈으로는 못 잡습니다.
  4) 프레임 수가 4n+1 인가, 해상도가 16 배수인가

사용법:
  python3 check_workflow.py workflows/anime_i2v.json
  python3 check_workflow.py --manifest manifest.tsv workflows/*.json
  python3 check_workflow.py --track anime workflows/anime_i2v.json
"""

import argparse
import json
import os
import re
import sys

# 모델 파일명을 담는 로더 노드들.
# 값은 UI 포맷에서 widgets_values 의 몇 번째가 파일명인지.
LOADER_WIDGET_INDEX = {
    "UNETLoader": 0,
    "LoraLoaderModelOnly": 0,
    "LoraLoader": 0,
    "CLIPLoader": 0,
    "VAELoader": 0,
    "CLIPVisionLoader": 0,
    "CheckpointLoaderSimple": 0,
    "DualCLIPLoader": 0,
}

# API 포맷에서 파일명이 들어가는 입력 키
API_FILE_KEYS = (
    "unet_name", "lora_name", "clip_name", "vae_name",
    "clip_name1", "clip_name2", "ckpt_name", "model_name",
)

MODEL_PASSTHROUGH = {"LoraLoaderModelOnly", "LoraLoader", "ModelSamplingSD3",
                     "ModelSamplingAuraFlow", "PathchSageAttentionKJ",
                     "ModelPatchTorchSettings"}

SAMPLER_TYPES = {"KSamplerAdvanced", "KSampler", "SamplerCustom",
                 "SamplerCustomAdvanced"}


class Report:
    def __init__(self):
        self.errors = []
        self.warns = []
        self.infos = []

    def err(self, m):
        self.errors.append(m)

    def warn(self, m):
        self.warns.append(m)

    def info(self, m):
        self.infos.append(m)

    def ok(self):
        return not self.errors


def load_manifest(path):
    """매니페스트에서 filename -> (track, stage) 를 만듭니다."""
    known = {}
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.replace("\r", "").rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 6:
                continue
            track, stage, dest, filename, url, _bytes = parts[:6]
            known[filename] = (track, stage, url)
    return known


def detect_format(data):
    if isinstance(data, dict) and "nodes" in data and isinstance(data["nodes"], list):
        return "ui"
    if isinstance(data, dict) and data and all(
        isinstance(v, dict) and "class_type" in v for v in data.values()
    ):
        return "api"
    return "unknown"


# ---------------------------------------------------------------------------
# UI 포맷 파싱
# ---------------------------------------------------------------------------
def parse_ui(data):
    nodes = {}
    for n in data.get("nodes", []):
        nodes[n.get("id")] = n
    # links: [link_id, origin_node, origin_slot, target_node, target_slot, type]
    links = {}
    for l in data.get("links", []) or []:
        if isinstance(l, list) and len(l) >= 6:
            links[l[0]] = {"from": l[1], "to": l[3], "type": l[5]}
    return nodes, links


def ui_input_source(nodes, links, node_id, input_name):
    """해당 노드의 특정 입력이 어느 노드에서 왔는지 반환합니다."""
    n = nodes.get(node_id)
    if not n:
        return None
    for inp in n.get("inputs", []) or []:
        if inp.get("name") == input_name:
            lid = inp.get("link")
            if lid is None:
                return None
            link = links.get(lid)
            return link["from"] if link else None
    return None


def ui_widget(node, idx):
    wv = node.get("widgets_values")
    if isinstance(wv, list) and len(wv) > idx:
        v = wv[idx]
        return v if isinstance(v, str) else None
    if isinstance(wv, dict):
        for v in wv.values():
            if isinstance(v, str) and v.endswith(".safetensors"):
                return v
    return None


def trace_model_chain_ui(nodes, links, sampler_id):
    """
    샘플러의 model 입력에서 UNETLoader 까지 거슬러 올라가며
    경유한 LoRA 목록과 최종 UNET 파일명을 수집합니다.
    """
    loras = []
    unet = None
    cur = ui_input_source(nodes, links, sampler_id, "model")
    seen = set()
    while cur is not None and cur not in seen:
        seen.add(cur)
        n = nodes.get(cur)
        if not n:
            break
        t = n.get("type")
        if t in ("LoraLoaderModelOnly", "LoraLoader"):
            name = ui_widget(n, 0)
            if name:
                loras.append(name)
            cur = ui_input_source(nodes, links, cur, "model")
        elif t == "UNETLoader":
            unet = ui_widget(n, 0)
            break
        elif t in MODEL_PASSTHROUGH:
            cur = ui_input_source(nodes, links, cur, "model")
        else:
            cur = ui_input_source(nodes, links, cur, "model")
    return unet, loras


def collect_ui(data, rep):
    nodes, links = parse_ui(data)
    referenced = []

    for nid, n in nodes.items():
        t = n.get("type")
        if t in LOADER_WIDGET_INDEX:
            name = ui_widget(n, LOADER_WIDGET_INDEX[t])
            if name:
                referenced.append((name, t))

    # 샘플러별 모델 체인 추적
    chains = []
    for nid, n in nodes.items():
        if n.get("type") in SAMPLER_TYPES:
            unet, loras = trace_model_chain_ui(nodes, links, nid)
            if unet or loras:
                chains.append({"sampler": nid, "unet": unet, "loras": loras})

    # 해상도 / 프레임 수
    dims = []
    for nid, n in nodes.items():
        t = n.get("type") or ""
        if t in ("WanImageToVideo", "WanAnimateToVideo", "WanFirstLastFrameToVideo",
                 "EmptyHunyuanLatentVideo", "EmptyLatentVideo"):
            wv = n.get("widgets_values")
            if isinstance(wv, list):
                nums = [v for v in wv if isinstance(v, (int, float))]
                dims.append((t, nums))
    return referenced, chains, dims


# ---------------------------------------------------------------------------
# API 포맷 파싱
# ---------------------------------------------------------------------------
def api_input_source(data, node_id, key):
    node = data.get(str(node_id)) or data.get(node_id)
    if not node:
        return None
    v = node.get("inputs", {}).get(key)
    if isinstance(v, list) and v:
        return str(v[0])
    return None


def trace_model_chain_api(data, sampler_id):
    loras, unet = [], None
    cur = api_input_source(data, sampler_id, "model")
    seen = set()
    while cur is not None and cur not in seen:
        seen.add(cur)
        node = data.get(cur)
        if not node:
            break
        ct = node.get("class_type")
        if ct in ("LoraLoaderModelOnly", "LoraLoader"):
            nm = node.get("inputs", {}).get("lora_name")
            if isinstance(nm, str):
                loras.append(nm)
            cur = api_input_source(data, cur, "model")
        elif ct == "UNETLoader":
            nm = node.get("inputs", {}).get("unet_name")
            unet = nm if isinstance(nm, str) else None
            break
        else:
            cur = api_input_source(data, cur, "model")
    return unet, loras


def collect_api(data, rep):
    referenced = []
    for nid, node in data.items():
        ct = node.get("class_type")
        for k, v in (node.get("inputs") or {}).items():
            if k in API_FILE_KEYS and isinstance(v, str):
                referenced.append((v, ct))

    chains = []
    for nid, node in data.items():
        if node.get("class_type") in SAMPLER_TYPES:
            unet, loras = trace_model_chain_api(data, nid)
            if unet or loras:
                chains.append({"sampler": nid, "unet": unet, "loras": loras})

    dims = []
    for nid, node in data.items():
        ct = node.get("class_type") or ""
        if ct.startswith("Wan") or ct.startswith("Empty"):
            ins = node.get("inputs") or {}
            nums = [(k, v) for k, v in ins.items()
                    if k in ("width", "height", "length", "batch_size") and isinstance(v, int)]
            if nums:
                dims.append((ct, nums))
    return referenced, chains, dims


# ---------------------------------------------------------------------------
def stage_of(name):
    """
    파일명에서 high/low noise 단계를 판정합니다.
    배포자마다 표기가 제각각입니다: high_noise / high-noise / highnoise / HighNoise.
    하나라도 놓치면 정작 중요한 불일치 검사가 조용히 통과해버립니다.
    """
    low = re.sub(r"[^a-z]", "", name.lower())   # 구분자 제거 후 비교
    if "highnoise" in low:
        return "high"
    if "lownoise" in low:
        return "low"
    return None


def check_chains(chains, rep):
    """
    핵심 검사. high noise UNET 쪽 체인에 low noise LoRA 가 물려 있으면
    (또는 그 반대) 고스팅/이중노출이 납니다.
    """
    if not chains:
        rep.warn("샘플러의 모델 체인을 추적하지 못했습니다 "
                 "(커스텀 노드 기반 워크플로우면 정상일 수 있습니다)")
        return

    for ch in chains:
        unet = ch["unet"]
        ustage = stage_of(unet) if unet else None
        label = f"샘플러 #{ch['sampler']}"
        if unet:
            label += f"  UNET={unet}"
        rep.info(label)
        for lora in ch["loras"]:
            lstage = stage_of(lora)
            mark = "    LoRA " + lora
            if ustage and lstage and ustage != lstage:
                rep.err(f"단계 불일치: {ustage} noise UNET 체인에 "
                        f"{lstage} noise LoRA 가 물려 있습니다 -> {lora}\n"
                        f"      이 상태로 생성하면 고스팅(이중 노출)이 납니다.")
                mark += f"   <-- 불일치 ({lstage} vs UNET {ustage})"
            elif lstage and ustage and lstage == ustage:
                mark += "   (단계 일치)"
            rep.info(mark)

    # high/low 가 모두 존재해야 하는 MoE 구조인지 점검
    unets = [stage_of(c["unet"]) for c in chains if c["unet"]]
    if unets.count("high") and not unets.count("low"):
        rep.warn("high noise UNET 만 있고 low noise 가 없습니다. "
                 "Wan 2.2 MoE 는 두 단계를 모두 씁니다.")
    if unets.count("low") and not unets.count("high"):
        rep.warn("low noise UNET 만 있고 high noise 가 없습니다.")


def check_dims(dims, rep):
    for t, nums in dims:
        vals = [v for v in nums] if nums and not isinstance(nums[0], tuple) else None
        if vals is None:
            d = dict(nums)
            w, h, length = d.get("width"), d.get("height"), d.get("length")
        else:
            w = vals[0] if len(vals) > 0 else None
            h = vals[1] if len(vals) > 1 else None
            length = vals[2] if len(vals) > 2 else None
        if isinstance(w, int) and w % 16:
            rep.err(f"{t}: width={w} 가 16의 배수가 아닙니다")
        if isinstance(h, int) and h % 16:
            rep.err(f"{t}: height={h} 가 16의 배수가 아닙니다")
        if isinstance(length, int) and length > 1:
            if length % 4 != 1:
                rep.err(f"{t}: length={length} 가 4n+1 이 아닙니다 "
                        f"(유효 예: 33, 41, 65, 81)")
            elif length < 65:
                rep.warn(f"{t}: length={length}. 애니 스타일 LoRA 는 프레임이 적으면 "
                         f"트리거되지 않을 수 있습니다 (65~81 권장)")
        if isinstance(w, int) and isinstance(h, int):
            rep.info(f"{t}: {w}x{h}" + (f", {length} 프레임" if length else ""))


def check_file(path, known, track, rep):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as e:
        rep.err(f"JSON 파싱 실패: {e}")
        return set()
    except OSError as e:
        rep.err(f"파일을 열 수 없습니다: {e}")
        return set()

    fmt = detect_format(data)
    if fmt == "unknown":
        rep.err("ComfyUI 워크플로우 JSON 으로 보이지 않습니다 "
                "(nodes 배열도 class_type 맵도 없음)")
        return set()
    rep.info(f"포맷: {'UI(저장본)' if fmt == 'ui' else 'API(export)'}")

    referenced, chains, dims = (collect_ui if fmt == "ui" else collect_api)(data, rep)

    used = set()
    if known is None:
        rep.warn("매니페스트를 찾을 수 없어 파일명 대조는 건너뜁니다")
    else:
        for name, ntype in referenced:
            used.add(name)
            if name not in known:
                rep.err(f"매니페스트에 없는 모델: {name}  ({ntype})\n"
                        f"      -> Pod 에서 이 로더의 드롭다운이 비어 있게 됩니다.")
            else:
                t, s, _ = known[name]
                if track and t not in ("common", track):
                    rep.warn(f"{name} 은 '{t}' 트랙 파일인데 '{track}' 워크플로우가 참조합니다")

    check_chains(chains, rep)
    check_dims(dims, rep)
    return used


def main():
    ap = argparse.ArgumentParser(description="ComfyUI 워크플로우 사전 검증")
    ap.add_argument("workflows", nargs="+", help="검사할 JSON 파일")
    ap.add_argument("-m", "--manifest", default=None, help="매니페스트 경로")
    ap.add_argument("-t", "--track", default=None,
                    choices=["anime", "realistic"], help="기대 트랙")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    mpath = args.manifest or os.path.join(here, "manifest.tsv")
    known = load_manifest(mpath)
    if known is not None:
        print(f"매니페스트: {mpath}  ({len(known)} 개 항목)\n")

    total_used = set()
    failed = 0

    for wf in args.workflows:
        rep = Report()
        print("=" * 66)
        print(os.path.basename(wf))
        print("=" * 66)
        used = check_file(wf, known, args.track, rep)
        total_used |= used

        for m in rep.infos:
            print("  " + m)
        if rep.warns:
            print()
            for m in rep.warns:
                print("  [경고] " + m)
        if rep.errors:
            print()
            for m in rep.errors:
                print("  [오류] " + m)
            failed += 1
        print()
        print("  판정:", "통과" if rep.ok() else "실패")
        print()

    # 매니페스트에는 있는데 어떤 워크플로우도 안 쓰는 파일
    if known and total_used:
        unused = [n for n in known if n not in total_used]
        if unused:
            print("=" * 66)
            print("어느 워크플로우도 참조하지 않는 매니페스트 항목")
            print("=" * 66)
            for n in unused:
                t, s, url = known[n]
                tag = " (URL 미확정)" if url.startswith("TODO") else ""
                print(f"  {t:<10} {n}{tag}")
            print("\n  다른 트랙 파일이면 정상입니다. 아니라면 받을 필요가 없는 용량입니다.")
            print()

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
