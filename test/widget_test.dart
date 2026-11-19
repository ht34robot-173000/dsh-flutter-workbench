// 冒烟测试：验证 App 能构建、首屏能渲染。
//
// ⚠️ 不要用 `pumpAndSettle` —— 首屏是 CircularProgressIndicator（无限动画），
// `pumpAndSettle` 会一直等到超时失败。用固定次数的 `pump` 即可。
//
// 解析层的真实测试在 live_parse_test.dart（9 个用例，覆盖本阶段踩过的坑）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/main.dart';

void main() {
  testWidgets('应用能构建，首屏出现加载态', (WidgetTester tester) async {
    await tester.pumpWidget(const DshWorkbenchApp());

    // boot() 是异步读 SharedPreferences，第一帧必定是加载圈
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 推进几帧让异步任务跑完，绝不要 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  });
}
