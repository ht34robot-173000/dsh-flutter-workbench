// 主题切换「零加载」相关的纯逻辑测试。
//
// 背景：上一版主题揭示把同一棵 widget 子树放进 Stack 两个格子，
// Flutter 按「位置 + 类型」认 Element → 建了两份 State → 每次切主题
// 会话列表被销毁重建三次（两次切进切换态 + 一次切出），于是打了三次
// session.list、闪了两次转圈。改成「抓一帧快照 + 固定结构的 Stack」之后，
// 活着的树只有一份，State 不重建。
//
// 这里测两件能脱离 UI 验证的事：
//   1. 反向圆形裁剪的几何（洞口在圆心、四角保留快照）
//   2. SessionStore 的缓存策略（新鲜期内短路、reset 清空）
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_workbench/data/ds_api.dart';
import 'package:dsh_workbench/data/prefs.dart';
import 'package:dsh_workbench/data/session_data.dart';
import 'package:dsh_workbench/data/session_store.dart';
import 'package:dsh_workbench/ui/theme_reveal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InverseCircleClipper', () {
    const size = ui.Size(400, 800);
    const center = ui.Offset(200, 400);

    test('圆心在洞里（那里露出新界面，不画快照）', () {
      final p = InverseCircleClipper(center, 100).getClip(size);
      expect(p.contains(center), isFalse);
      // 洞边缘内侧
      expect(p.contains(const ui.Offset(290, 400)), isFalse);
    });

    test('圆外仍然被快照盖住', () {
      final p = InverseCircleClipper(center, 100).getClip(size);
      expect(p.contains(const ui.Offset(10, 10)), isTrue);
      expect(p.contains(const ui.Offset(390, 790)), isTrue);
      // 洞外一点点
      expect(p.contains(const ui.Offset(200, 520)), isTrue);
    });

    test('半径 0 = 整屏都被盖住（动画起点）', () {
      final p = InverseCircleClipper(center, 0).getClip(size);
      expect(p.contains(center), isTrue);
      expect(p.contains(const ui.Offset(399, 799)), isTrue);
    });

    test('半径足够大 = 整屏都是洞（动画终点）', () {
      final p = InverseCircleClipper(center, 2000).getClip(size);
      expect(p.contains(const ui.Offset(10, 10)), isFalse);
    });

    test('圆心或半径变了才需要重裁', () {
      final a = InverseCircleClipper(center, 100);
      expect(a.shouldReclip(InverseCircleClipper(center, 100)), isFalse);
      expect(a.shouldReclip(InverseCircleClipper(center, 101)), isTrue);
      expect(a.shouldReclip(InverseCircleClipper(Offset.zero, 100)), isTrue);
    });
  });

  group('SessionStore 缓存策略', () {
    late DshApi api;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await Prefs.load();
      api = DshApi(prefs);
      SessionStore.instance.reset();
    });

    test('首屏前没有数据 → hasData 为 false（这时才允许转圈）', () {
      expect(SessionStore.instance.hasData, isFalse);
      expect(SessionStore.instance.data, isNull);
    });

    test('新鲜期内重复 load 直接短路，不发请求也不改状态', () async {
      final store = SessionStore.instance;
      // 手工塞一份「刚拿到」的缓存
      store.data = const SessionListData([]);
      store.fetchedAt = DateTime.now();

      final before = store.fetchedAt;
      await store.load(api); // 不该打网络（打了会连 127.0.0.1 超时）
      expect(store.fetchedAt, before, reason: '没刷新就不该改时间戳');
      expect(store.loading, isFalse);
    });

    test('过了新鲜期就不再短路（把 fetchedAt 拨回 1 分钟前）', () async {
      final store = SessionStore.instance;
      store.data = const SessionListData([]);
      store.fetchedAt = DateTime.now().subtract(const Duration(minutes: 1));
      // 这里会真的去请求（测试环境连不上，最终落成 error），
      // 但重点验证的是「不再短路」这条分支被执行到了
      await store.load(api);
      expect(store.loading, isFalse);
      expect(store.error, isNotNull, reason: '连不上时应该把错误记下来');
      expect(store.data, isNotNull, reason: '有旧数据时必须保留，界面不能变空');
    });

    test('reset 把缓存和错误一起清掉（换服务器 / 换配对后必须调）', () {
      final store = SessionStore.instance;
      store.data = const SessionListData([]);
      store.fetchedAt = DateTime.now();
      store.error = '旧错误';
      store.reset();
      expect(store.data, isNull);
      expect(store.fetchedAt, isNull);
      expect(store.error, isNull);
    });
  });
}
