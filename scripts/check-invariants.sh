#!/bin/bash
# GzhWriter 一期不变量断言（回归清单）
# 用途：这些约束构建不会报错，只有本脚本会失败。
# 二期若复用死代码（LibraryView/AutoSettingsView/MaterialsView/PlanView），
# 必须先改本脚本并写明原因，否则功能会静默复活。
# 用法：./scripts/check-invariants.sh   退出码 0=全过，1=有失败
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=1; }

echo "【A1】死代码无挂载点（侧栏只有 工作台/稿件/设置）"
for s in LibraryView AutoSettingsView MaterialsView PlanView; do
  n=$(grep -rn "$s(" Sources/GzhWriter/ 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" == "0" ]]; then pass "$s 无挂载点"; else fail "$s 出现 $n 处挂载点，死代码链已复活，请先删「排进日历」与「定时生产」"; fi
done

echo "【A2】Batch「排进日历」按钮仍在（A1 若失败，此按钮会真写 scheduled）"
if grep -q 'Label("排进日历"' Sources/GzhWriter/Batch.swift; then
  pass "Batch.swift 存在「排进日历」按钮"
else
  fail "「排进日历」按钮已消失，A1/A2 的防护语义需重写（说明有人动过这条链）"
fi

echo "【A3】Pipeline 生成完稿不写 scheduled（一期红线）"
if grep -qE 'scheduled *= *[^=]' Sources/GzhWriter/Pipeline.swift; then
  fail "Pipeline.swift 出现 scheduled 赋值：$(grep -nE 'scheduled *= *[^=]' Sources/GzhWriter/Pipeline.swift)"
else
  pass "Pipeline.swift 无 scheduled 赋值"
fi

echo "【A4】全仓 scheduled 赋值只允许出现在不可达链内"
BAD=$(grep -rnE '\$0\.scheduled *=|\.scheduled *= *[^=]' Sources/GzhWriter/ 2>/dev/null | grep -v '== nil' | grep -v 'decodeIfPresent' | grep -v 'MaterialsPlan.swift')
if [[ -z "$BAD" ]]; then pass "除 MaterialsPlan.swift（MaterialsView/PlanView 均无挂载）外无 scheduled 赋值"
else fail "发现 MaterialsPlan.swift 之外的 scheduled 赋值：$BAD"; fi

echo "【A5】published = true 全仓只一处（V11）"
n=$(grep -rn "published = true" Sources/GzhWriter | wc -l | tr -d ' ')
if [[ "$n" == "1" ]]; then pass "published = true 共 1 处：$(grep -rn "published = true" Sources/GzhWriter/)"
else fail "published = true 有 $n 处（应为 1）：$(grep -rn "published = true" Sources/GzhWriter/)"; fi

echo
if [[ "$FAIL" == "0" ]]; then echo "全部通过"; else echo "有失败项，见上"; fi
exit $FAIL
