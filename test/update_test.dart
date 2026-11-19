// 应用内更新的纯逻辑测试。
//
// 重点覆盖两处极易出错的地方：
//   1. 版本比较 —— 字符串比较会让 "2.10" < "2.9"，判断反了会「永远提示已最新」
//   2. 镜像展开 —— 只对 github 域名套镜像，自己搭的服务器不能套
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/update_api.dart';

void main() {
  group('compareVersion', () {
    test('按数字段比，不是字符串比', () {
      // 这是最典型的陷阱：字符串比较 "2.10" < "2.9"
      expect(compareVersion('2.10', '2.9'), greaterThan(0));
      expect(compareVersion('2.9', '2.10'), lessThan(0));
    });

    test('相同版本返回 0', () {
      expect(compareVersion('1.2.3', '1.2.3'), 0);
    });

    test('段数不同时短的补 0', () {
      expect(compareVersion('2.1', '2.1.0'), 0);
      expect(compareVersion('2.1.0', '2.1'), 0);
      expect(compareVersion('2.1.1', '2.1'), greaterThan(0));
    });

    test('主版本号优先', () {
      expect(compareVersion('3.0', '2.99.99'), greaterThan(0));
    });

    test('非法段当 0，不崩', () {
      expect(compareVersion('abc', '0.0.0'), 0);
      expect(compareVersion('1.x.3', '1.0.3'), 0);
    });

    test('本项目真实版本序列', () {
      // 0.5.1 -> 0.6.0 应该是升级
      expect(compareVersion('0.6.0', '0.5.1'), greaterThan(0));
      // 0.5.1 -> 0.5.0 是降级
      expect(compareVersion('0.5.0', '0.5.1'), lessThan(0));
      // 0.10.0 > 0.9.0（字符串比较会判反）
      expect(compareVersion('0.10.0', '0.9.0'), greaterThan(0));
    });
  });

  group('downloadCandidates', () {
    test('github 地址：镜像优先，直连兜底', () {
      const url = 'https://github.com/a/b/releases/download/v1/x.apk';
      final list = downloadCandidates(url);
      // 最后一个必须是原始地址（兜底）
      expect(list.last, url);
      // 至少有一个镜像在前
      expect(list.length, greaterThan(1));
      expect(list.first.startsWith('https://gh-'), isTrue);
      // 每个镜像都是「镜像域名 + 原始地址」
      for (final c in list.take(list.length - 1)) {
        expect(c.endsWith(url), isTrue);
      }
    });

    test('githubusercontent 也算 github 域名', () {
      const url = 'https://objects.githubusercontent.com/x/y.apk';
      expect(downloadCandidates(url).length, greaterThan(1));
    });

    test('非 github 地址不套镜像（自己搭的服务器不能被代理）', () {
      const url = 'https://my-server.example.com/app.apk';
      final list = downloadCandidates(url);
      expect(list, [url]);
    });

    test('所有官方镜像都在列表里', () {
      const url = 'https://github.com/a/b/c.apk';
      final list = downloadCandidates(url);
      for (final m in githubMirrors) {
        expect(list.any((x) => x.startsWith(m)), isTrue, reason: '缺镜像 $m');
      }
    });
  });

  group('UpdateApi 默认值', () {
    test('token 必须为空 —— 源码里绝不能有凭据', () {
      // 2026-11-16 事故：硬编码 token 随 APK 分发，账号被停用。
      // 这条断言把「不许写死凭据」变成可执行的检查。
      expect(UpdateApi.token, isEmpty);
    });

    test('默认仓库名', () {
      expect(UpdateApi.defaultRepo, 'ht34robot-173000/dsh-flutter-workbench');
    });

    test('apiBase 可注入（国内 api.github.com 常不可达）', () {
      final api = UpdateApi(apiBase: 'https://my-mirror.example.com');
      expect(api.apiBase, 'https://my-mirror.example.com');
    });

    test('repo 可注入（账号被停用后能换仓库，不必重发版）', () {
      final api = UpdateApi(repo: 'someone/else');
      expect(api.repo, 'someone/else');
    });

    test('默认仓库名格式合法', () {
      expect(UpdateApi.defaultRepo.contains('/'), isTrue);
      final parts = UpdateApi.defaultRepo.split('/');
      expect(parts.length, 2);
      expect(parts[0].isNotEmpty && parts[1].isNotEmpty, isTrue);
    });
  });

  group('配置生效：api 必须用输入框的值，不是初始值', () {
    /*
     * 回归测试：早先 `_rebuildApi()` 读的是 `widget.repo` / `widget.apiBase`，
     * 那是 initState 时传进来的**初始值**，用户改了输入框它不会变。
     *
     * 表现：配置区显示新仓库，点「检查更新」却还在查旧仓库 ——
     * 用户看到的是「保存没生效」。
     *
     * 这里测的是 UpdateApi 构造本身：给它什么就用什么。
     * 真正的「输入框 → api」绑定在 UI 层，靠模拟器验证。
     */
    test('构造时传入的 repo/api 被如实保留', () {
      final a = UpdateApi(repo: 'new-owner/new-repo', apiBase: 'https://mirror.example.com');
      expect(a.repo, 'new-owner/new-repo');
      expect(a.apiBase, 'https://mirror.example.com');
    });

    test('两个实例互不影响（不共享状态）', () {
      final a = UpdateApi(repo: 'a/b');
      final b = UpdateApi(repo: 'c/d');
      expect(a.repo, 'a/b');
      expect(b.repo, 'c/d');
    });
  });

  group('仓库不可用时必须报错，不能显示「已是最新」', () {
    /*
     * 这一组是回归测试：GitHub 对「仓库不存在」和「没有 release」
     * **都返回 404**。早先代码只看 releases/latest 的 404，
     * 一律当成「没发布过」→ 界面显示「已是最新版本」，
     * 而实际上更新通道整个断了。
     *
     * 现实案例：2026-11-16 硬编码 token 事故后账号被停用，仓库 404。
     *
     * 修复方式：先探 /repos/{repo}，能区分两种情况。
     * 这里只测「错误信息不该为空」这个契约 —— 真实网络行为
     * 在模拟器上验。
     */
    test('error 非空的 UpdateInfo 不算「已是最新」', () {
      const bad = UpdateInfo(currentVersion: '0.5.1', error: '仓库不存在');
      expect(bad.ok, isFalse);
      // 调用方应该走 if (!info.ok) 报错分支，而不是 if (!info.hasUpdate)
      expect(bad.hasUpdate, isFalse);
    });

    test('正常无更新：error 为 null、hasUpdate 为 false', () {
      const fine = UpdateInfo(currentVersion: '0.5.1', latestVersion: '0.5.1');
      expect(fine.ok, isTrue);
      expect(fine.hasUpdate, isFalse);
    });
  });
}


