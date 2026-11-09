"""Frozen interface library and manifest handling for the RV32I L3 workflow."""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone
from pathlib import Path

from ai_eda.config import AGENT_CONTENT_ROOT

PROJECT_ID = "rv32i5_ooo"
SPEC_SHA256 = "0ff959abf7f5cbd2669691d19b11fb6ccd7b0eb1884a5924ece4d542a5ffa89d"
LIBRARY = AGENT_CONTENT_ROOT / "skills" / PROJECT_ID
EXECUTE_PATH = "rtl/execute_unit.sv"

MODULES = {
    "rv32i5": "Top-level connections, instruction classes, global dispatch/retire, ECALL and debug events.",
    "fetch_unit": "Predicted PC, request metadata, skid buffer, epoch and redirect.",
    "icache": "16 direct-mapped instruction lines, four-beat refill, discard killed path.",
    "dcache": "16 direct-mapped data lines, write-allocate and byte-merge write-through.",
    "branch_predictor": "Tagged BTB, two-bit BHT, conditional direction training and jump targets.",
    "rename_unit": "RAT/committed map, 40 PR values and ready bits, free FIFO, branch checkpoints.",
    "issue_queue": "Eight ROB-tagged slots, oldest-ready integer select, in-order control resolution.",
    "reorder_buffer": "Eight entries, ordered head commit, completion tags and age-based squash mask.",
    "load_store_unit": "ROB-tagged memory queue, head-only issue, byte lanes and sign extension.",
    "execute_unit": "RV32I ALU and branches. SLL/SRL/SRA shift by b[4:0]. Only SLLI/SRLI/SRAI use insn[24:20].",
}

CONTRACTS = {
    "fetch_predictor": "Use the lookup for the accepted fetch PC. Carry predicted next PC with each instruction. Resolve compares the issued prediction against the actual next PC.",
    "fetch_icache": "One accepted lookup at a time, hit response the next cycle, refill response after four beats. Flush kills the old fetch epoch and drains a presented external beat.",
    "rename_rob": "A single dispatch handshake reserves one ROB tag and optional new PR, storing old PR. Free the old PR only on retirement. A surviving branch keeps its own PR; restore its post-allocation RAT and rewind allocation head without rewinding retirement tail.",
    "rename_issue": "Dispatch passes source PRs, new PR and ROB tag. The ROB bounds IQ and LSQ occupancy since each has one slot per tag. Discard applies to younger slots only.",
    "issue_execute": "Pick an oldest ready integer op by PR ready bits. Memory request handshake takes the single issue slot; accepted integers complete combinationally. Do not resolve a branch before an older unresolved branch.",
    "lsu_dcache": "The LSU drives stable valid/address/we/be/data until accepted. Only the ROB head starts memory requests, so redirect cannot kill an active D request. Completion uses the captured tag, lane and destination.",
    "retirement": "Head-only, at most one per clock, with original PC/insn. Store completes after write-through response. ECALL stops younger dispatch, retires after older work drains, and asserts halted/exit_code on the following edge.",
}


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def header(source: str) -> tuple[str, str]:
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    matches = list(re.finditer(r"\bmodule\s+(\w+)\s*\((.*?)\)\s*;", source, re.S))
    if len(matches) != 1 or len(re.findall(r"\bmodule\b", source)) != 1 or len(
        re.findall(r"\bendmodule\b", source)
    ) != 1:
        raise ValueError("需要一个完整的 ANSI SystemVerilog 模块")
    return matches[0].group(1), matches[0].group(2).strip()


def validate_interface(source: str, module: dict) -> None:
    name, ports = header(source)
    def normalize(text: str) -> str:
        return re.sub(r"\s+", "", re.sub(r"\b(?:logic|reg|wire)\b", "", text))

    if name != module["name"] or normalize(ports) != normalize(module["interfaces"]):
        raise ValueError(f"接口与冻结计划不符：{module['name']}")
    if re.search(r"(?m)^\s*`(?:include|define|undef|ifdef|ifndef)\b", source):
        raise ValueError(f"模块不得依赖或改变预处理环境：{name}")


def library_plan(spec: str) -> dict:
    if digest(spec) != SPEC_SHA256:
        raise ValueError("The teacher Spec changed. Revalidate the L3 component library against it.")
    modules = []
    for name, description in MODULES.items():
        source = (LIBRARY / f"{name}.sv").read_text(encoding="utf-8")
        declared_name, ports = header(source)
        if declared_name != name:
            raise ValueError(f"L3 library module {name} declares {declared_name}")
        modules.append({
            "name": name, "file": f"rtl/{name}.sv", "description": description,
            "interfaces": ports, "library_sha256": digest(source),
        })
    return {
        "schema_version": 1,
        "project_name": PROJECT_ID,
        "top_module": "rv32i5",
        "spec_sha256": SPEC_SHA256,
        "interfaces": CONTRACTS,
        "modules": modules,
    }


def artifact_metadata(runtime, attempt: int) -> dict:
    return {
        "schema_version": 1,
        "run_id": runtime.run_dir.name,
        "project_id": PROJECT_ID,
        "attempt": attempt,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def snapshot(runtime, changes: dict[str, str], attempt: int, previous: dict | None = None) -> str:
    from ai_eda.agent.subagents.common import safe_project_path

    entries = {entry["path"]: entry for entry in (previous or {}).get("files", [])}
    for path, source in changes.items():
        worktree = safe_project_path(runtime.run_dir, path)
        worktree.parent.mkdir(parents=True, exist_ok=True)
        worktree.write_text(source, encoding="utf-8")
        entries[path] = {
            "path": path,
            "artifact": runtime.write_text_artifact(f"rtl-{attempt:02d}/{path}", source),
            "sha256": digest(source),
            "bytes": len(source.encode("utf-8")),
            "attempt": attempt,
        }
    return runtime.write_json_artifact(f"rtl_manifest_{attempt:02d}.json", {
        **artifact_metadata(runtime, attempt),
        "files": list(entries.values()),
    })


def manifest_source(runtime, entry: dict) -> str:
    source = runtime.read_text_artifact(entry["artifact"])
    if entry.get("sha256") and digest(source) != entry["sha256"]:
        raise ValueError(f"RTL artifact 哈希不匹配：{entry['path']}")
    return source


def compile_candidate(path: Path, module_name: str) -> str:
    """Return compiler errors before staging the generated ALU for the project test."""
    import subprocess

    result = subprocess.run(
        ["iverilog", "-g2012", "-tnull", "-s", module_name, str(path)],
        capture_output=True, text=True, timeout=20,
    )
    return result.stderr if result.returncode else ""
