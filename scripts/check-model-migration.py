#!/usr/bin/env python3
#
# 数据模型迁移安全检查。
#
# ── 为什么需要这个脚本 ───────────────────────────────────────
# 真实事故：给 `@Model` 加了一个**非可选且没有默认值**的新字段
# （`SupplyItem.recentUnitsRaw: String`）。SwiftData（底层 Core Data）
# 做轻量迁移时，新增非可选字段**必须带默认值**，否则整个 store 打不开。
# 而启动代码在打不开时会降级到内存库 ——
# 于是用户看到的是「装完新版本数据全丢了，预设也重新乱掉」，
# 而真正的错误信息被 catch 吞掉了，完全看不出是迁移问题。
#
# 人工 review 抓不住这个：那一行 `var recentUnitsRaw: String` 跟别的
# 属性长得一模一样。所以必须让机器守。
#
# ── 规则 ─────────────────────────────────────────────────────
# 与基线（`scripts/model-schema-baseline.json`）相比：
#
#   · **新增**的存储属性 → 必须可选 `T?` 或带默认值 `= ...`，否则 ❌
#   · **删除**的属性 → ⚠️ 警告（一般安全，但要确认没在别处引用了旧值）
#   · **改类型**的属性 → ❌ 错误（轻量迁移做不了，需要自定义迁移）
#
# 基线是"上一次确认能正常打开旧数据"的模型快照。改完模型后如果检查通过，
# 用 `--update` 重新生成基线并提交，这样下一次改动才有参照。
#
# 用法：
#   python3 scripts/check-model-migration.py            # 检查
#   python3 scripts/check-model-migration.py --update    # 更新基线
#

import io
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "ArtStock" / "Models"
BASELINE = ROOT / "scripts" / "model-schema-baseline.json"


def parse_models():
    """扫出所有 @Model 类里的存储属性。

    返回 {类名: {属性名: 类型字符串}}。
    只统计**存储属性**：带 `{` 的计算属性、`static`、`let` 都不算。
    """
    models = {}
    for path in sorted(MODELS_DIR.glob("*.swift")):
        text = io.open(path, encoding="utf-8").read()
        # 按 @Model 切块，块内找 class 名与大括号范围
        for match in re.finditer(r"@Model\b", text):
            head = text[match.end():match.end() + 400]
            class_match = re.search(r"(?:final\s+)?class\s+(\w+)", head)
            if not class_match:
                continue
            class_name = class_match.group(1)
            # 从 class 声明处开始，按大括号配对取类体
            body_start = text.index("{", match.end() + class_match.start())
            depth = 0
            index = body_start
            while index < len(text):
                if text[index] == "{":
                    depth += 1
                elif text[index] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                index += 1
            body = text[body_start + 1:index]

            props = {}
            # 逐行扫。跳过计算属性（行内或少数几行内有 `{`）与 static/let
            for line in body.split("\n"):
                stripped = line.strip()
                if stripped.startswith("//") or stripped.startswith("///"):
                    continue
                if stripped.startswith(("static ", "let ", "func ", "@Relationship", "//")):
                    # @Relationship 后面那行才是属性，交给下一轮
                    if stripped.startswith("@Relationship"):
                        continue
                    continue
                if "{" in stripped:
                    continue  # 计算属性
                prop = re.match(
                    r"^(?:@\w+(?:\([^)]*\))?\s+)*var\s+(\w+)\s*:\s*([^=\n]+?)\s*(?:=\s*(.+))?$",
                    stripped,
                )
                if not prop:
                    continue
                name, type_text, default = prop.group(1), prop.group(2).strip(), prop.group(3)
                # 关系数组有隐式空数组语义，不算迁移风险
                if type_text.startswith("["):
                    continue
                props[name] = {"type": type_text, "hasDefault": default is not None}
            models[class_name] = props
    return models


def is_migration_safe(prop):
    return prop["type"].endswith("?") or prop["hasDefault"]


def main():
    update = "--update" in sys.argv
    current = parse_models()

    if update or not BASELINE.exists():
        BASELINE.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        total = sum(len(v) for v in current.values())
        print(f"已写入基线：{BASELINE.relative_to(ROOT)}")
        print(f"  {len(current)} 个 @Model，{total} 个存储属性")
        if not update:
            print("  （基线原本不存在，这次顺便生成。之后再改模型才会有对照。）")
        return 0

    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))

    errors = []
    warnings = []

    for class_name, props in sorted(current.items()):
        base_props = baseline.get(class_name, {})
        if class_name not in baseline:
            # 新实体：加一张新表是additive的，安全。但表内字段同样要合规。
            # 加一张新表本身是 additive 的，不会影响已有数据 —— 所以是警告不是错误。
            # （报错会让人以为加新功能都做不了，那是错的。）
            warnings.append(f"新实体 {class_name}（{len(props)} 个字段）—— 加新表本身是安全的")
            for name, prop in sorted(props.items()):
                if not is_migration_safe(prop):
                    warnings.append(
                        f"{class_name}.{name}: {prop['type']} —— 新表里这个字段非可选且无默认值。"
                        "这次没问题，但**以后**给这张表加字段时同样会踩坑，建议现在就补默认值"
                    )
            continue

        for name, prop in sorted(props.items()):
            base = base_props.get(name)
            if base is None:
                if not is_migration_safe(prop):
                    errors.append(
                        f"{class_name}.{name}: {prop['type']}  ← 新增的非可选、无默认值字段，"
                        "会导致轻量迁移失败、整个 store 打不开（真实事故过）"
                    )
            elif base["type"] != prop["type"]:
                errors.append(
                    f"{class_name}.{name}: 类型从 {base['type']} 改成 {prop['type']}"
                    "  ← 轻量迁移做不了类型变更"
                )
        for name in sorted(base_props):
            if name not in props:
                warnings.append(f"{class_name}.{name}: 已删除（确认没有旧数据依赖它）")

    print("==> 数据模型迁移安全检查")
    print(f"@Model 实体 {len(current)} 个，基线 {len(baseline)} 个")

    for warning in warnings:
        print(f"  ⚠️  {warning}")
    for error in errors:
        print(f"  ❌ {error}")

    if errors:
        print()
        print("  规则：给已有的 @Model 加字段，只能是 `T?` 或 `= 默认值`。")
        print("  改完模型并确认能正常打开旧数据后，跑 `--update` 更新基线。")
        return 1

    print("  ✅ 没有破坏迁移的模型改动")
    if warnings:
        print("  （上面的警告需要你确认一下，不算失败）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
