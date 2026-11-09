"""固定 Agent 流程的受限 EDA 自动设计执行器。

固定流水线：Parser → RTL Planner → Coder → Tester → Modifier（失败回环）。
Parser 需要补充 Spec 时通过 ``request_input`` 暂停并等待用户输入。
"""

from __future__ import annotations

import json
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from ai_eda.agent.projects import get_project
from ai_eda.agent.skills.rv32i5_ooo import PROJECT_ID as L3_PROJECT, digest, snapshot
from ai_eda.agent.subagents.l3 import DiagnoserAgent, PatchAgent
from ai_eda.agent.runs import (
    AgentCancelled,
    _now,
    _report_summary,
    _run_payload,
    _write_json,
    _write_metadata,
    agent_task_spec,
    load_agent_graph,
)
from ai_eda.agent.subagents.base import RunContext
from ai_eda.agent.subagents.coder import CoderAgent
from ai_eda.agent.subagents.common import safe_project_path
from ai_eda.agent.subagents.modifier import ModifierAgent
from ai_eda.agent.subagents.parser import ParserAgent
from ai_eda.agent.subagents.planner import PlannerAgent
from ai_eda.agent.subagents.tester import TesterAgent
from ai_eda.config import AGENT_RUNS_ROOT

EventSink = Callable[[dict[str, Any]], None]


def _check_cancel(cancel_event: Any) -> None:
    if cancel_event is not None and cancel_event.is_set():
        raise AgentCancelled("Agent 运行已取消。")


def _load_resume_source(run_id: str) -> dict[str, Any]:
    """读取上一次运行的 Spec/Plan，用于从 Coder 继续执行。"""
    name = str(run_id or "").strip()
    if not name or Path(name).name != name or name in {".", ".."}:
        raise ValueError("resume_from 必须是单个运行目录名")
    root = AGENT_RUNS_ROOT.resolve()
    source = (root / name).resolve()
    if root not in source.parents or not source.is_dir():
        raise FileNotFoundError(f"找不到要续跑的运行：{name}")
    artifacts = source / "artifacts"
    spec_path = artifacts / "effective_spec.md"
    if not spec_path.is_file():
        spec_path = artifacts / "spec.md"
    plan_path = artifacts / "plan.json"
    if not spec_path.is_file():
        raise ValueError("上一次运行没有 Spec artifact，无法续跑")
    spec = spec_path.read_text(encoding="utf-8")
    plan: dict[str, Any] | None = None
    if plan_path.is_file():
        loaded_plan = json.loads(plan_path.read_text(encoding="utf-8"))
        if isinstance(loaded_plan, dict) and isinstance(loaded_plan.get("modules"), list):
            plan = loaded_plan
    parser_result: dict[str, Any] = {}
    parser_path = artifacts / "parser_result.json"
    if parser_path.is_file():
        try:
            parsed = json.loads(parser_path.read_text(encoding="utf-8"))
            if isinstance(parsed, dict):
                parser_result = parsed
        except json.JSONDecodeError:
            pass
    events_payload: dict[str, Any] = {}
    events_path = source / "events.json"
    if events_path.is_file():
        try:
            loaded = json.loads(events_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                events_payload = loaded
        except json.JSONDecodeError:
            pass
    source_events = events_payload.get("events") if isinstance(events_payload.get("events"), list) else []
    failed_event: dict[str, Any] | None = None
    for event in reversed(source_events):
        if not isinstance(event, dict):
            continue
        if event.get("status") in {"failed", "cancelled", "running"}:
            failed_event = event
            break
    if failed_event is None and source_events:
        failed_event = source_events[-1] if isinstance(source_events[-1], dict) else None
    stage = str((failed_event or {}).get("node_id") or "coder")
    if plan is None and stage not in {"parser", "planner"}:
        raise ValueError("上一次运行没有 Plan artifact，无法从 Coder/Tester 续跑")
    title = str((failed_event or {}).get("title") or "")
    module_name = title.rsplit(" · ", 1)[-1] if stage == "coder" and " · " in title else None
    project_files: dict[str, str] = {}
    manifests = sorted(artifacts.glob("rtl_manifest_[0-9][0-9].json"))
    if manifests:
        manifest = json.loads(manifests[-1].read_text(encoding="utf-8"))
        for entry in manifest["files"]:
            artifact = (source / entry["artifact"]).resolve()
            if source not in artifact.parents:
                raise ValueError("续跑的 RTL artifact 越出原运行目录")
            content = artifact.read_text(encoding="utf-8")
            if digest(content) != entry["sha256"]:
                raise ValueError(f"续跑的 RTL artifact 哈希不匹配：{entry['path']}")
            project_files[entry["path"]] = content
    else:
        project_rtl = source / "project" / "rtl"
        if project_rtl.is_dir():
            for path in sorted(project_rtl.glob("*.sv")):
                project_files[f"rtl/{path.name}"] = path.read_text(encoding="utf-8")
    return {
        "run_id": name,
        "spec": spec,
        "plan": plan,
        "parser_result": parser_result,
        "source": source,
        "stage": stage,
        "module": module_name,
        "event": failed_event,
        "project_files": project_files,
        "source_status": events_payload.get("status"),
        "project_id": events_payload.get("project_id"),
    }


def _seed_modifier_input(
    context: RunContext,
    source: dict[str, Any],
    spec_ref: str,
    plan_ref: str,
    manifest_ref: str,
) -> Path:
    """为从 Modifier 失败点续跑重建 Tester → Modifier 输入。"""
    source_dir = source["source"]
    candidates = sorted((source_dir / "handoffs").glob("tester_to_modifier_attempt*.json"))
    if not candidates:
        raise ValueError("上一次运行没有 Tester → Modifier handoff，无法从 Modifier 续跑")
    record = json.loads(candidates[-1].read_text(encoding="utf-8"))
    payload = record.get("payload") if isinstance(record, dict) else None
    artifacts = (payload or {}).get("artifacts") or {}
    source_report_ref = artifacts.get("report")
    if not isinstance(source_report_ref, str):
        raise ValueError("上一次运行缺少失败报告，无法从 Modifier 续跑")
    source_report = (source_dir / source_report_ref).resolve()
    if source_dir.resolve() not in source_report.parents or not source_report.is_file():
        raise ValueError("上一次运行的失败报告路径无效")
    report = json.loads(source_report.read_text(encoding="utf-8"))
    report_ref = context.write_json_artifact("resume_report.json", report)
    return context.write_handoff(
        "tester",
        "modifier",
        {
            "attempt": 1,
            "summary": (payload or {}).get("summary") or "上一轮 Tester 失败",
            "artifacts": {
                "spec": spec_ref,
                "plan": plan_ref,
                "rtl_manifest": manifest_ref,
                "report": report_ref,
            },
        },
        attempt=1,
        label=f"Resume {source['run_id']}: continue from Modifier",
    )


def _copy_resume_files(context: RunContext, files: dict[str, str]) -> None:
    for relative, content in files.items():
        target = safe_project_path(context.run_dir, relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")


def _seed_resume_project(
    context: RunContext,
    source: dict[str, Any],
    spec_ref: str,
    plan_ref: str,
) -> dict[str, Any]:
    """把上次项目的 RTL 复制到新运行，并建立进入 Tester 的 manifest/handoff。"""
    files = source.get("project_files") or {}
    if not isinstance(files, dict) or not files:
        raise ValueError("上一次运行没有可续跑的 RTL 项目文件")
    if context.options.get("l3_mode"):
        manifest_ref = snapshot(context, files, 1)
    else:
        _copy_resume_files(context, files)
        entries = [
            {
                "path": relative,
                "artifact": context.artifact_ref(safe_project_path(context.run_dir, relative)),
                "bytes": len(content.encode("utf-8")),
            }
            for relative, content in files.items()
        ]
        manifest_ref = context.write_json_artifact("rtl_manifest_resume.json", {"files": entries})
    tester_input = context.write_handoff(
        "coder",
        "tester",
        {
            "artifacts": {
                "spec": spec_ref,
                "plan": plan_ref,
                "rtl_manifest": manifest_ref,
            }
        },
        label=f"Resume {source['run_id']}: reuse current RTL",
    )
    return {"handler": tester_input, "files": files, "manifest": manifest_ref}


def run_agent(
    *,
    thinking: bool = True,
    reasoning_effort: str = "low",
    temperature: float = 0.2,
    max_tokens: int = 60000,
    max_calls: int = 100,
    max_repair_attempts: int = 8,
    planner_skill: bool = False,
    resume_from: str | None = None,
    on_event: EventSink | None = None,
    cancel_event: Any = None,
    design_id: str | None = None,
    design_name: str | None = None,
    project_id: str | None = None,
    request_input: Callable[[dict[str, Any]], str] | None = None,
    l3_mode: str | None = None,
) -> dict[str, Any]:
    """运行固定流水线，L3 使用 Diagnoser 与 Patch Agent 分段修复。

    ``graph.json`` 只是该固定流程的只读可视化，不参与调度。每个 Agent 都从上游
    handoff 中取得 artifact 引用，再按引用读取 Spec、RTL 或报告内容。
    """
    if reasoning_effort not in {"low", "high", "max"}:
        raise ValueError("reasoning_effort 无效")
    if not 1 <= int(max_calls) <= 1000:
        raise ValueError("max_calls 必须在 1 到 1000 之间")
    if not 1 <= int(max_repair_attempts) <= 10:
        raise ValueError("max_repair_attempts 必须在 1 到 10 之间")
    max_tester_attempts = int(max_repair_attempts) + 1
    project = get_project(project_id)
    if l3_mode is not None and (project["id"] != L3_PROJECT or l3_mode not in {"hybrid", "reference", "legacy"}):
        raise ValueError("l3_mode requires the L3 project and hybrid, reference or legacy mode")
    if project["id"] == L3_PROJECT and l3_mode is None:
        l3_mode = "hybrid"
    split_repair = l3_mode in {"hybrid", "reference"}
    graph = load_agent_graph(L3_PROJECT if split_repair else None)
    spec_base = agent_task_spec(project["id"])
    run_id = f"agent-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')}"
    run_dir = AGENT_RUNS_ROOT / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    _write_json(run_dir / "graph.json", graph)
    (run_dir / "project").mkdir(exist_ok=True)

    events: list[dict[str, Any]] = []
    started_at = _now()
    started_clock = time.perf_counter()
    current_status = "running"
    final_report: dict[str, Any] | None = None
    final_result: dict[str, Any] | None = None
    effective_spec = spec_base
    parser_result: dict[str, Any] = {}
    plan: dict[str, Any] | None = None
    files: list[dict[str, Any]] = []
    tester_attempts = 0

    def persist(status: str = "running", error: str | None = None) -> None:
        _write_json(
            run_dir / "events.json",
            _run_payload(
                run_id=run_id,
                run_dir=run_dir,
                graph=graph,
                events=events,
                status=status,
                started_at=started_at,
                report=final_report,
                result=final_result,
                spec=effective_spec,
                error=error,
                design_id=design_id,
                design_name=design_name,
                project_id=project["id"],
                resumed_from=resume_from,
            ),
        )

    def emit(event: dict[str, Any]) -> None:
        if on_event is not None:
            on_event(json.loads(json.dumps(event, ensure_ascii=False)))

    def begin_event(
        node_id: str, node_type: str, title: str, prompt: str, attempt: int = 1
    ) -> dict[str, Any]:
        event: dict[str, Any] = {
            "run_id": run_id,
            "step": len(events) + 1,
            "node_id": node_id,
            "node_type": node_type,
            "title": title,
            "prompt": prompt,
            "status": "running",
            "attempt": attempt,
            "started_at": _now(),
            "_started_clock": time.perf_counter(),
        }
        events.append(event)
        persist()
        emit(event)
        return event

    def finish_event(event: dict[str, Any], status: str, **fields: Any) -> None:
        event.update(fields)
        event["status"] = status
        event["duration_ms"] = round(
            (time.perf_counter() - event.get("_started_clock", time.perf_counter())) * 1000
        )
        event.pop("_started_clock", None)
        event["finished_at"] = _now()
        persist()
        emit(event)

    def check_cancel() -> None:
        _check_cancel(cancel_event)

    persist()
    try:
        context = RunContext(
            run_dir=run_dir,
            options={
                "temperature": temperature,
                "max_tokens": max_tokens,
                "thinking": thinking,
                "reasoning_effort": reasoning_effort,
                "planner_skill": bool(planner_skill),
                "project": project,
                "l3_mode": l3_mode if split_repair else None,
                "model_stream": l3_mode != "legacy",
            },
            begin_event=begin_event,
            finish_event=finish_event,
            persist=persist,
            emit=emit,
            check_cancel=check_cancel,
            request_input=request_input,
            max_calls=max_calls,
        )
        if resume_from:
            resume_source = _load_resume_source(resume_from)
            if resume_source.get("project_id") and resume_source["project_id"] != project["id"]:
                raise ValueError("续跑的来源必须属于同一个项目")
            effective_spec = resume_source["spec"]
            plan = resume_source["plan"]
            parser_result = resume_source.get("parser_result") or {}
            resume_stage = str(resume_source.get("stage") or "coder")
            if split_repair and resume_stage in {"modifier", "diagnoser", "patch"}:
                resume_stage = "tester"
            if split_repair and resume_stage == "coder" and not (plan or {}).get("spec_sha256"):
                resume_stage = "planner"
            if resume_stage == "modifier":
                # 续跑从 Modifier 输入开始；随后第一次 Tester 应使用第 2 轮，
                # 避免与 seed 的 tester_to_modifier_attempt1.json 重名。
                tester_attempts = 1
            spec_ref = context.write_text_artifact("effective_spec.md", effective_spec)
            plan_ref = context.write_json_artifact("plan.json", plan)
            parser_result_ref = context.write_json_artifact(
                "parser_result_resume.json", parser_result
            )
            if resume_stage == "parser":
                initial_handoff = context.write_handoff(
                    "spec",
                    "parser",
                    {"task": project["id"], "artifacts": {"spec": context.write_text_artifact("spec.md", effective_spec)}},
                    label=f"Resume {resume_from}: continue from Parser",
                )
                parser = ParserAgent(context)
                parser_handoff = parser.run(initial_handoff)
                planner = PlannerAgent(context)
                planner_handoff = planner.run(parser_handoff)
                coder = CoderAgent(context)
                next_tester_input = coder.run(planner_handoff)
            elif resume_stage == "planner":
                parser_result_ref = context.write_json_artifact(
                    "parser_result_resume.json", parser_result
                )
                parser_handoff = context.write_handoff(
                    "parser",
                    "planner",
                    {
                        "artifacts": {
                            "spec": spec_ref,
                            "parser_result": parser_result_ref,
                        }
                    },
                    label=f"Resume {resume_from}: continue from Planner",
                )
                planner = PlannerAgent(context)
                planner_handoff = planner.run(parser_handoff)
                coder = CoderAgent(context)
                next_tester_input = coder.run(planner_handoff)
            elif resume_stage == "coder":
                _copy_resume_files(context, resume_source.get("project_files") or {})
                planner_handoff = context.write_handoff(
                    "planner",
                    "coder",
                    {
                        "artifacts": {
                            "spec": spec_ref,
                            "plan": plan_ref,
                            "parser_result": parser_result_ref,
                        }
                    },
                    label=f"Resume {resume_from}: continue from Coder",
                )
                coder = CoderAgent(context)
                next_tester_input = coder.run(
                    planner_handoff,
                    existing_files=resume_source.get("project_files") or {},
                    start_module=resume_source.get("module"),
                )
            elif resume_stage in {"tester", "modifier", "summary"}:
                seeded = _seed_resume_project(
                    context, resume_source, spec_ref, plan_ref
                )
                if resume_stage == "modifier":
                    modifier_input = _seed_modifier_input(
                        context,
                        resume_source,
                        spec_ref,
                        plan_ref,
                        seeded["manifest"],
                    )
                    modifier = ModifierAgent(context)
                    next_tester_input = modifier.run(modifier_input, 1)
                else:
                    # 已有完整 RTL 时直接从 Tester 继续。
                    next_tester_input = seeded["handler"]
            else:
                raise ValueError(
                    f"上一次运行停在 {resume_stage}，没有可直接继续的 Coder/Tester 产物"
                )
        else:
            resume_stage = None
            spec_ref = context.write_text_artifact("spec.md", spec_base)
            initial_handoff = context.write_handoff(
                "spec",
                "parser",
                {"task": project["id"], "artifacts": {"spec": spec_ref}},
                label="Input Spec → Parser: Spec artifact",
            )

            parser = ParserAgent(context)
            parser_handoff = parser.run(initial_handoff)

            planner = PlannerAgent(context)
            planner_handoff = planner.run(parser_handoff)
            coder = CoderAgent(context)
            next_tester_input = coder.run(planner_handoff)

        tester = TesterAgent(context)
        if split_repair:
            diagnoser = DiagnoserAgent(context)
            patcher = PatchAgent(context)
        else:
            modifier = ModifierAgent(context)
        while True:
            tester_attempts += 1
            tester_handoff = tester.run(next_tester_input, tester_attempts)
            tester_payload = context.read_handoff(tester_handoff)["payload"]
            tester_artifacts = tester_payload.get("artifacts") or {}
            report_ref = tester_artifacts.get("report")
            if not isinstance(report_ref, str):
                raise ValueError("Tester handoff 缺少报告 artifact")
            report = context.read_json_artifact(report_ref)
            if not isinstance(report, dict):
                raise ValueError("Tester 报告 artifact 格式无效")
            final_report = report
            if report.get("passed"):
                break
            if tester_attempts >= int(max_tester_attempts):
                break
            check_cancel()
            if split_repair:
                diagnosis = diagnoser.run(tester_handoff, tester_attempts)
                next_tester_input = patcher.run(diagnosis, tester_attempts)
            else:
                next_tester_input = modifier.run(tester_handoff, tester_attempts)

        if final_report is None:
            raise ValueError("Tester 没有产出验收报告")
        final_handoff = context.read_handoff(tester_handoff)["payload"]
        final_artifacts = final_handoff.get("artifacts") or {}
        spec_ref = final_artifacts.get("spec")
        plan_ref = final_artifacts.get("plan")
        manifest_ref = final_artifacts.get("rtl_manifest")
        if not all(isinstance(ref, str) for ref in (spec_ref, plan_ref, manifest_ref)):
            raise ValueError("最终 handoff 缺少 Spec、Plan 或 RTL manifest artifact")
        effective_spec = context.read_text_artifact(spec_ref)
        plan = context.read_json_artifact(plan_ref)
        manifest = context.read_json_artifact(manifest_ref)
        if not isinstance(plan, dict) or not isinstance(manifest, dict):
            raise ValueError("最终 artifact 格式无效")
        files = manifest.get("files") if isinstance(manifest.get("files"), list) else []
        if not resume_from:
            parser_payload = context.read_handoff(parser_handoff)["payload"]
            parser_result_ref = (parser_payload.get("artifacts") or {}).get("parser_result")
            if isinstance(parser_result_ref, str):
                parsed = context.read_json_artifact(parser_result_ref)
                parser_result = parsed if isinstance(parsed, dict) else {}
        passed = bool(final_report.get("passed"))
        final_result = {
            "passed": passed,
            "stage": final_report.get("stage"),
            "summary": _report_summary(final_report),
            "metrics": final_report.get("metrics") or {},
            "spec": effective_spec,
            "plan": plan,
            "files": files,
            "parser_rounds": parser_result.get("rounds", 1),
            "supplements": parser_result.get("supplements", []),
            "tester_attempts": tester_attempts,
            "resumed_from": resume_from,
            "cpu_capability": final_report.get("cpu_capability"),
            "test_suites": final_report.get("test_suites"),
            "performance": final_report.get("performance"),
        }
        _write_json(run_dir / "result.json", final_result)
        current_status = "passed" if passed else "failed"
    except AgentCancelled as error:
        current_status = "cancelled"
        for pending in events:
            if pending.get("status") in {"running", "waiting_input"}:
                pending.update(
                    {"status": "cancelled", "finished_at": _now(), "error": str(error)}
                )
        payload = _run_payload(
            run_id=run_id,
            run_dir=run_dir,
            graph=graph,
            events=events,
            status=current_status,
            started_at=started_at,
            finished_at=_now(),
            report=final_report,
            result=final_result,
            spec=effective_spec,
            resumed_from=resume_from,
            error=str(error),
            design_id=design_id,
            design_name=design_name,
            project_id=project["id"],
        )
        payload["duration_ms"] = round((time.perf_counter() - started_clock) * 1000)
        _write_json(run_dir / "events.json", payload)
        try:
            _write_metadata(
                run_dir,
                graph=graph,
                run_id=run_id,
                status=current_status,
                started_at=started_at,
                finished_at=payload["finished_at"],
                attempts=tester_attempts or 1,
                max_repair_attempts=max_repair_attempts,
                resumed_from=resume_from,
                temperature=temperature,
                max_tokens=max_tokens,
                thinking=thinking,
                reasoning_effort=reasoning_effort,
                design_id=design_id,
                design_name=design_name,
                project_id=project["id"],
            )
        except Exception:
            pass
        raise
    except Exception as error:
        current_status = "failed"
        for pending in events:
            if pending.get("status") in {"running", "waiting_input"}:
                finish_event(pending, "failed", error=str(error))
        payload = _run_payload(
            run_id=run_id,
            run_dir=run_dir,
            graph=graph,
            events=events,
            status=current_status,
            started_at=started_at,
            finished_at=_now(),
            report=final_report,
            result=final_result,
            spec=effective_spec,
            resumed_from=resume_from,
            error=str(error),
            design_id=design_id,
            design_name=design_name,
            project_id=project["id"],
        )
        payload["duration_ms"] = round((time.perf_counter() - started_clock) * 1000)
        _write_json(run_dir / "events.json", payload)
        try:
            _write_metadata(
                run_dir,
                graph=graph,
                run_id=run_id,
                status=current_status,
                started_at=started_at,
                finished_at=payload["finished_at"],
                attempts=tester_attempts or 1,
                max_repair_attempts=max_repair_attempts,
                resumed_from=resume_from,
                temperature=temperature,
                max_tokens=max_tokens,
                thinking=thinking,
                reasoning_effort=reasoning_effort,
                design_id=design_id,
                design_name=design_name,
                project_id=project["id"],
            )
        except Exception:
            pass
        raise

    payload = _run_payload(
        run_id=run_id,
        run_dir=run_dir,
        graph=graph,
        events=events,
        status=current_status,
        started_at=started_at,
        finished_at=_now(),
        report=final_report,
        result=final_result,
        spec=effective_spec,
        resumed_from=resume_from,
        design_id=design_id,
        design_name=design_name,
        project_id=project["id"],
    )
    payload["duration_ms"] = round((time.perf_counter() - started_clock) * 1000)
    _write_json(run_dir / "events.json", payload)
    _write_metadata(
        run_dir,
        graph=graph,
        run_id=run_id,
        status=current_status,
        started_at=started_at,
        finished_at=payload["finished_at"],
        attempts=tester_attempts or 1,
        max_repair_attempts=max_repair_attempts,
        resumed_from=resume_from,
        temperature=temperature,
        max_tokens=max_tokens,
        thinking=thinking,
        reasoning_effort=reasoning_effort,
        design_id=design_id,
        design_name=design_name,
        project_id=project["id"],
    )
    return payload



