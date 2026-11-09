"""Coder 子 Agent：按计划逐文件生成 RTL。"""

from __future__ import annotations

import json
from pathlib import Path

from ai_eda.model.client import RTL_SYSTEM_PROMPT
from ai_eda.rtl.runner import extract_rtl
from ai_eda.agent.skills.rv32i5_l1_reference import load_reference

from .base import SubAgent
from .l3 import code_l3
from .common import RV32I_L1_CODE_PATTERNS, RV32I_PIPELINE_CHECKLIST, safe_project_path


def _architecture_block(plan: dict) -> str:
    architecture = plan.get("architecture")
    if not isinstance(architecture, dict):
        return ""
    parameters = architecture.get("parameters") or {}
    directives = architecture.get("coder_directives") or []
    reference = architecture.get("reference_structure") or {}
    return (
        "\n\nPlanner Skill 预评估架构参数（直接来自 Python Skill，必须严格遵守）：\n"
        + json.dumps(parameters, ensure_ascii=False, indent=2)
        + "\n\nCoder 指令：\n"
        + "\n".join(f"- {item}" for item in directives)
        + "\n\n参考结构：\n"
        + json.dumps(reference, ensure_ascii=False, indent=2)
        + "\n"
    )


class CoderAgent(SubAgent):
    name = "coder"
    title = "03 · Coder"
    node_type = "coder"
    # RTL 生成同样属于工具型输出。L1/L2 的 Plan+Spec 很长，思考模式可能把
    # 60k 输出预算全部消耗在 reasoning 上，导致没有 RTL 文本。默认关闭思考，
    # 把预算留给完整的 SystemVerilog 文件。
    MODEL_OPTIONS = {"thinking": False}

    def run(
        self,
        planner_handoff: Path,
        *,
        existing_files: dict[str, str] | None = None,
        start_module: str | None = None,
    ) -> Path:
        if self.runtime.options.get("l3_mode"):
            return code_l3(self, planner_handoff)
        incoming = self.runtime.read_handoff(planner_handoff)["payload"]
        artifacts = incoming.get("artifacts") or {}
        spec_ref = artifacts.get("spec")
        plan_ref = artifacts.get("plan")
        if not isinstance(spec_ref, str) or not isinstance(plan_ref, str):
            raise ValueError("Planner → Coder handoff 缺少 Spec 或 Plan artifact")
        effective_spec = self.runtime.read_text_artifact(spec_ref)
        plan = self.runtime.read_json_artifact(plan_ref)
        if not isinstance(plan, dict):
            raise ValueError("Plan artifact 格式无效")
        project_id = str((self.runtime.options.get("project") or {}).get("id") or "")
        project_checklist = (
            "\n\n" + RV32I_PIPELINE_CHECKLIST + "\n\n" + RV32I_L1_CODE_PATTERNS
            if project_id.startswith("rv32i5")
            else ""
        )
        files: dict[str, str] = {}
        existing = existing_files or {}
        reference = load_reference(str((self.runtime.options.get("project") or {}).get("id") or ""))
        modules = plan["modules"]
        start_index = 0
        if start_module:
            for index, module in enumerate(modules):
                if module.get("name") == start_module:
                    start_index = index
                    break
        architecture_block = _architecture_block(plan)
        for index, module in enumerate(modules):
            if index < start_index and module["file"] in existing:
                files[module["file"]] = existing[module["file"]]
                continue
            if module["file"] in reference:
                rtl = reference[module["file"]]
                target = safe_project_path(self.runtime.run_dir, module["file"])
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(rtl, encoding="utf-8")
                files[module["file"]] = rtl
                event = self.runtime.begin_event(
                    "coder", self.node_type, f"{self.title} · {module['name']}", "参考实现"
                )
                self.finish(
                    event,
                    "info",
                    response=f"Wrote {module['file']} (L1 reference, {len(rtl)} chars).",
                )
                continue
            prompt = (
                f"请实现项目中模块 `{module['name']}`，写入文件 `{module['file']}`。"
                "只输出该文件的完整 SystemVerilog RTL，不要输出 Markdown 围栏或解释。\n\n"
                "项目计划（必须严格遵守 modules[].interfaces 的端口名/方向/位宽；"
                "跨模块信号在该模块中也必须使用同一套名称和宽度，不能自行改名或增删端口）。\n"
                + architecture_block
                + "语法自检：端口列表已经声明的 output/input 信号不要在模块体内再次用 logic/wire 声明；"
                "每个信号只能有一个 driver；不要出现重复声明或多驱动。\n"
                f"{json.dumps(plan, ensure_ascii=False, indent=2)}\n\n"
                f"Spec：\n{effective_spec}\n\n"
                f"本模块说明：{module['description']}\n本模块接口契约：{module['interfaces']}"
                + project_checklist
            )
            event = self.runtime.begin_event(
                "coder", self.node_type, f"{self.title} · {module['name']}", prompt
            )
            result = self.runtime.call_model(
                event, prompt, RTL_SYSTEM_PROMPT, model_options=self.MODEL_OPTIONS
            )
            rtl = extract_rtl(result.get("answer") or "")
            if not rtl.strip() or "module" not in rtl:
                raise ValueError(f"Coder 没有为 {module['name']} 生成有效 RTL")
            target = safe_project_path(self.runtime.run_dir, module["file"])
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(rtl, encoding="utf-8")
            files[module["file"]] = rtl
            artifact_dir = self.runtime.run_dir / f"step-{event['step']:02d}-{event['node_id']}"
            (artifact_dir / "generated.sv").write_text(rtl, encoding="utf-8")
            self.save_context(plan_ref=plan_ref, last_file=self.runtime.artifact_ref(target))
            self.finish(
                event,
                "info",
                response=f"Wrote {module['file']} ({len(rtl)} chars).",
                rtl=rtl,
                reasoning=event.get("reasoning"),
                usage=event.get("usage"),
            )
        manifest = {
            "files": [
                {
                    "path": path,
                    "artifact": self.runtime.artifact_ref(
                        safe_project_path(self.runtime.run_dir, path)
                    ),
                    "bytes": len(content.encode("utf-8")),
                }
                for path, content in files.items()
            ]
        }
        manifest_ref = self.runtime.write_json_artifact("rtl_manifest.json", manifest)
        self.save_context(plan_ref=plan_ref, rtl_manifest_ref=manifest_ref)
        return self.runtime.write_handoff(
            "coder",
            "tester",
            {
                "artifacts": {
                    "spec": spec_ref,
                    "plan": plan_ref,
                    "rtl_manifest": manifest_ref,
                },
            },
            label="Coder → Tester: RTL manifest",
        )
