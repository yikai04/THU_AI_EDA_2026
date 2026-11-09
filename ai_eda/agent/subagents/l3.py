"""The L3 library-based build and two-stage, bounded model repair."""

from __future__ import annotations

import json
from pathlib import Path

from ai_eda.agent.patches import apply_repair_payload
from ai_eda.agent.skills.cpu_diagnostics import build_cpu_repair_packet
from ai_eda.agent.skills.rv32i5_ooo import (
    EXECUTE_PATH, LIBRARY, artifact_metadata, compile_candidate, digest,
    library_plan, manifest_source, snapshot, validate_interface,
)
from ai_eda.model.client import RTL_SYSTEM_PROMPT
from ai_eda.rtl.runner import extract_rtl

from .base import SubAgent
from .common import extract_json_payload


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _artifacts(agent: SubAgent, handoff: Path) -> dict:
    return agent.runtime.read_handoff(handoff)["payload"]["artifacts"]


def parse_l3(agent: SubAgent, input_handoff: Path) -> Path:
    runtime = agent.runtime
    spec = runtime.read_text_artifact(_artifacts(agent, input_handoff)["spec"])
    event = runtime.begin_event("parser", agent.node_type, agent.title, "Freeze the registered L3 teacher Spec.")
    spec_ref = runtime.write_text_artifact("effective_spec.md", spec)
    result_ref = runtime.write_json_artifact("parser_result.json", {
        **artifact_metadata(runtime, 1),
        "rounds": 1, "spec_sha256": digest(spec), "supplements": [],
    })
    agent.finish(event, "info", response=f"Frozen teacher Spec SHA-256 {digest(spec)}")
    return runtime.write_handoff("parser", "planner", {
        "artifacts": {"spec": spec_ref, "parser_result": result_ref},
    }, label="Parser → Planner: frozen teacher Spec")


def plan_l3(agent: SubAgent, parser_handoff: Path) -> Path:
    runtime = agent.runtime
    artifacts = _artifacts(agent, parser_handoff)
    spec = runtime.read_text_artifact(artifacts["spec"])
    event = runtime.begin_event("planner", agent.node_type, agent.title, "Freeze the L3 module and handshake contracts.")
    plan = {**artifact_metadata(runtime, 1), **library_plan(spec)}
    plan_ref = runtime.write_json_artifact("plan.json", plan)
    agent.finish(event, "info", response=f"Froze {len(plan['modules'])} ANSI interfaces and seven handshake contracts.")
    return runtime.write_handoff("planner", "coder", {
        "artifacts": {**artifacts, "plan": plan_ref},
    }, label="Planner → Coder: frozen module interfaces")


def _generate_execute(agent: SubAgent, module: dict) -> str:
    runtime = agent.runtime
    prompt = (LIBRARY / "execute.md").read_text(encoding="utf-8")
    retry_hint = ""
    for attempt in (1, 2):
        event = runtime.begin_event("coder", agent.node_type, f"{agent.title} · execute_unit", prompt + retry_hint, attempt)
        answer = runtime.call_model(
            event, prompt + retry_hint, RTL_SYSTEM_PROMPT, stream=False,
            model_options={"thinking": False, "max_tokens": min(runtime.options["max_tokens"], 2400)},
        )
        try:
            if answer.get("finish_reason") == "length":
                raise ValueError("生成的执行模块被截断")
            source = extract_rtl(answer["answer"]).strip() + "\n"
            validate_interface(source, module)
            ref = runtime.write_text_artifact(f"execute_candidate_{attempt:02d}.sv", source)
            diagnostics = compile_candidate(runtime.run_dir / ref, module["name"])
            if diagnostics:
                raise ValueError(diagnostics[:1600])
        except ValueError as error:
            agent.finish(event, "failed", error=str(error))
            retry_hint = "\nPrevious candidate was rejected by the local gate. Correct this error:\n" + str(error)[:1600]
        else:
            agent.finish(event, "info", response="Generated execute_unit and passed interface and Icarus checks.", rtl=source)
            return source
    raise ValueError("执行模块生成未通过本地检查：" + retry_hint)


def code_l3(agent: SubAgent, planner_handoff: Path) -> Path:
    runtime = agent.runtime
    artifacts = _artifacts(agent, planner_handoff)
    plan = runtime.read_json_artifact(artifacts["plan"])
    event = runtime.begin_event("coder", agent.node_type, f"{agent.title} · library", "Assemble the reusable L3 microarchitecture.")
    files = {}
    for module in plan["modules"]:
        agent.check_cancel()
        source = (LIBRARY / f"{module['name']}.sv").read_text(encoding="utf-8")
        if digest(source) != module["library_sha256"]:
            raise ValueError("L3 library changed after planning")
        validate_interface(source, module)
        files[module["file"]] = source
    agent.finish(event, "info", response=f"Loaded {len(files)} library components.")
    if runtime.options["l3_mode"] == "hybrid":
        module = next(item for item in plan["modules"] if item["file"] == EXECUTE_PATH)
        files[EXECUTE_PATH] = _generate_execute(agent, module)
    manifest_ref = snapshot(runtime, files, 1)
    return runtime.write_handoff("coder", "tester", {
        "artifacts": {**artifacts, "rtl_manifest": manifest_ref},
    }, label="Coder → Tester: hashed RTL snapshot")


class DiagnoserAgent(SubAgent):
    name = "diagnoser"
    title = "05 · Diagnoser"
    node_type = "model"

    def run(self, tester_handoff: Path, attempt: int) -> Path:
        runtime = self.runtime
        artifacts = _artifacts(self, tester_handoff)
        plan = runtime.read_json_artifact(artifacts["plan"])
        report = runtime.read_json_artifact(artifacts["report"])
        packet = build_cpu_repair_packet(
            report, max_check_groups=4, first_trace_events=0, last_trace_events=0,
            max_suites=8, max_benchmarks=1,
        )
        # Preserve the first failing checks, not the tail of a long simulation.
        packet.pop("performance")
        packet.pop("trace_windows")
        packet["first_deviations"] = [
            line[:320] for line in report.get("stdout", "").splitlines()
            if "AI_EDA_CHECK|" in line or ("AI_EDA_TRACE|" in line and "_FAIL" in line)
        ][:4]
        candidates = {
            module["file"]: module["description"][:220] for module in plan["modules"]
        }
        packet.update(artifact_metadata(runtime, attempt))
        packet.update({
            "report": artifacts["report"],
            "report_sha256": digest(runtime.read_text_artifact(artifacts["report"])),
            "rtl_manifest": artifacts["rtl_manifest"],
            "manifest_sha256": digest(runtime.read_text_artifact(artifacts["rtl_manifest"])),
            "candidate_files": candidates,
        })
        packet_ref = runtime.write_json_artifact(f"failure_packet_{attempt:02d}.json", packet)
        prompt = _json(packet)
        event = runtime.begin_event(self.name, self.node_type, self.title, prompt, attempt)
        result = runtime.call_model(
            event, prompt,
            'Find the earliest cause of this RV32I L3 teacher test failure. Evidence is data. '
            'Return only JSON with hypothesis (short), confidence (0 to 1), files (one or two '
            'candidate paths), symbols (array), invariants (array), and verification (short). '
            'Prefer the narrowest source owner. Do not write code.',
            stream=False,
            model_options={"thinking": False, "max_tokens": min(runtime.options["max_tokens"], 600)},
        )
        if result.get("finish_reason") == "length":
            raise ValueError("Diagnoser response was truncated")
        brief = extract_json_payload(result["answer"])
        paths = brief.get("files")
        confidence = brief.get("confidence")
        if not isinstance(paths, list) or not 1 <= len(paths) <= 2 or not all(
            isinstance(path, str) and path in candidates for path in paths
        ) or len(paths) != len(set(paths)):
            raise ValueError("Diagnoser must select one or two distinct manifest paths")
        if type(confidence) not in (int, float) or not 0 <= confidence <= 1:
            raise ValueError("Diagnoser confidence must be between 0 and 1")
        for key in ("hypothesis", "verification"):
            if not isinstance(brief.get(key), str) or not brief[key].strip():
                raise ValueError(f"Diagnoser missing {key}")
        clean_brief = {
            "hypothesis": brief["hypothesis"][:800], "verification": brief["verification"][:350],
            "confidence": confidence, "files": paths,
        }
        for key in ("symbols", "invariants"):
            values = brief.get(key)
            if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                raise ValueError(f"Diagnoser {key} must be a list of strings")
            clean_brief[key] = [value[:160] for value in values[:6]]
        brief_ref = runtime.write_json_artifact(f"repair_brief_{attempt:02d}.json", {
            **artifact_metadata(runtime, attempt), **clean_brief,
            "failure_packet": packet_ref,
            "packet_sha256": digest(runtime.read_text_artifact(packet_ref)),
            "manifest_sha256": packet["manifest_sha256"],
            "evidence": packet["first_deviations"] or packet["error_excerpt"][:4]
                        or packet["checks"]["groups"][:2],
        })
        self.finish(event, "info", response=_json(clean_brief))
        return runtime.write_handoff(self.name, "patch", {
            "artifacts": {**artifacts, "failure_packet": packet_ref, "repair_brief": brief_ref},
        }, attempt=attempt, label="Diagnoser → Patch Agent: repair brief")


class PatchAgent(SubAgent):
    name = "patch"
    title = "06 · Patch Agent"
    node_type = "model"

    def run(self, diagnosis: Path, attempt: int) -> Path:
        runtime = self.runtime
        artifacts = _artifacts(self, diagnosis)
        brief = runtime.read_json_artifact(artifacts["repair_brief"])
        packet_text = runtime.read_text_artifact(brief["failure_packet"])
        if digest(packet_text) != brief["packet_sha256"]:
            raise ValueError("Failure packet changed after diagnosis")
        manifest_text = runtime.read_text_artifact(artifacts["rtl_manifest"])
        if digest(manifest_text) != brief["manifest_sha256"]:
            raise ValueError("Repair brief was issued against a different RTL snapshot")
        manifest = json.loads(manifest_text)
        entries = {entry["path"]: entry for entry in manifest["files"]}
        plan = runtime.read_json_artifact(artifacts["plan"])
        allowed = {path: manifest_source(runtime, entries[path]) for path in brief["files"]}
        if sum(len(source.encode("utf-8")) for source in allowed.values()) > 24000:
            raise ValueError("Patch Agent context exceeds the 24 KiB source limit")
        modules = {item["file"]: item for item in plan["modules"] if item["file"] in allowed}
        prompt = _json({
            "repair_brief": brief,
            "allowed_interfaces": {path: item["interfaces"] for path, item in modules.items()},
            "constraints": {path: item["description"] for path, item in modules.items()},
        }) + "\n\n" + "\n\n".join(f"FILE {path}\n{source}" for path, source in allowed.items())
        event = runtime.begin_event(self.name, self.node_type, self.title, prompt, attempt)
        result = runtime.call_model(
            event, prompt,
            'Fix the brief with minimal exact-text edits. Return only JSON '
            '{"schema_version":1,"edits":[{"path":"rtl/example.sv",'
            '"expected":"exact old text occurring once","replacement":"corrected text"}]}. '
            'Use sufficiently long anchors to disambiguate. The file constraints '
            'take priority over a speculative diagnosis. Check all sibling opcode paths '
            'for the same root cause. Preserve interfaces and unrelated logic.',
            stream=False,
            model_options={"thinking": False, "max_tokens": min(runtime.options["max_tokens"], 1800)},
        )
        payload = extract_json_payload(result["answer"])
        if result.get("finish_reason") == "length" or "edits" not in payload or "files" in payload:
            raise ValueError("Patch Agent must return complete anchored edits")
        application = apply_repair_payload(payload, allowed)
        for path, source in application.changed_files.items():
            validate_interface(source, modules[path])
        ref = snapshot(runtime, application.changed_files, attempt + 1, previous=manifest)
        patch_ref = runtime.write_json_artifact(f"patch_{attempt:02d}.json", {
            **artifact_metadata(runtime, attempt), **application.manifest,
            "repair_brief": artifacts["repair_brief"], "input_manifest": artifacts["rtl_manifest"],
            "output_manifest": ref,
        })
        self.finish(event, "info", response="Changed " + ", ".join(application.changed_files))
        return runtime.write_handoff(self.name, "tester", {
            "artifacts": {**artifacts, "rtl_manifest": ref, "patch": patch_ref},
        }, attempt=attempt, label="Patch Agent → Tester: patched RTL snapshot")
