/// DSH 工作台 —— 「我的」页（账号 + 余额 + 快捷入口）。
///
/// 数据源：宿主 `POST /rw/api/account.overview`，一次取齐三块
/// （`state` / `profile` / `balance`），三块**各自可能失败**，
/// 解析在 `data/account_api.dart`，这里只管画。
///
/// 界面规矩（和其余页面一致）：
///   - 配色全走 `DshColors`，不硬编码颜色；
///   - 卡片用圆角 + 1px 描边分层（纯黑上不能靠灰块堆层次）；
///   - 点击类元素一律用 `FluentCard(onTap:)` 或 `InkWell`，不做系统 ListTile 默认外观。
///
/// 外链一律**直接跳浏览器**（`url_launcher` 的 externalApplication）：
/// 充值 / 用量明细 / 仓库地址都是网页流程，多一步复制粘贴纯属添乱。
/// 只有跳转失败时才退回复制到剪贴板 —— 那样至少还能用。

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/account_api.dart';
import '../data/ds_api.dart';
import 'icons.dart';
import 'theme.dart';

class ProfilePage extends StatefulWidget {
  final DshApi api;
  final bool dark;

  const ProfilePage({
    super.key,
    required this.api,
    required this.dark,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  AccountOverview? _data;
  String? _error;
  bool _loading = true;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final pi = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = pi.version);
    } catch (_) {
      // 拿不到版本号不影响这一页的主要用途
    }
  }

  Future<void> _load() async {
    if (_data == null) setState(() => _loading = true);
    final r = await widget.api.api('account.overview');
    if (!mounted) return;

    if (!r.ok) {
      setState(() {
        _loading = false;
        _error = r.friendlyError;
      });
      return;
    }
    setState(() {
      _loading = false;
      _error = null;
      _data = AccountOverview.fromValue(r.value?['value'] as Map<String, dynamic>?);
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg, maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 3),
      ));
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('$label已复制：$text');
  }

  /// 打开外链。
  ///
  /// 优先**直接跳浏览器**（`externalApplication`）：充值/用量本来就是网页流程，
  /// 复制粘贴那一步纯属多余（用户当场指出「充值不应该直接跳转吗」）。
  /// 只有在系统里没有可用浏览器/跳转失败时才退回复制 —— 那样至少还能用。
  Future<void> _open(String label, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      await _copy(label, url);
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) await _copy(label, url);
    } catch (e) {
      await _copy(label, url);
      _toast('打不开浏览器，$label已复制');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);

    if (_loading) {
      return Center(child: CircularProgressIndicator(color: c.accent));
    }
    if (_error != null || (_data?.allFailed ?? false)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(DshGlyph.account, size: 34, color: c.danger),
              const SizedBox(height: 12),
              Text(
                _error ?? '账号信息读取失败',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final d = _data!;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        children: [
          _accountCard(c, d),
          const SizedBox(height: 10),
          _balanceCard(c, d),
          const SizedBox(height: 10),
          _actionsCard(c, d),
          const SizedBox(height: 10),
          _aboutCard(c),
        ],
      ),
    );
  }

  /* ---------------- 账号 ---------------- */

  Widget _accountCard(DshColors c, AccountOverview d) {
    return FluentCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        children: [
          _avatar(c, d),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        d.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(c, d),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _subtitle(d),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.textTertiary),
                ),
                if (d.profileError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '资料未取到：${d.profileError}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: c.danger),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: DshIcon(DshGlyph.refresh, size: 16, color: c.textSecondary),
            onPressed: _load,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: const EdgeInsets.all(6),
            tooltip: '刷新',
          ),
        ],
      ),
    );
  }

  Widget _avatar(DshColors c, AccountOverview d) {
    // 没头像就不联网加载图片（宿主给的是 null），直接画首字。
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.accent.withValues(alpha: 0.16),
        border: Border.all(color: c.accent.withValues(alpha: 0.45)),
      ),
      child: Text(
        d.initial,
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.bold,
          color: c.accent,
        ),
      ),
    );
  }

  /// 副行文案：**不要和标题重复**。
  ///
  /// 宿主没给 `name` 时标题会退化成打码手机号，这时候副行再写一遍手机号
  /// 就是一模一样的两行（第一版就是这样）。按可用信息挑：
  ///   有名字 → 手机号；没名字 → ID 短码；都没有 → 兜底文案。
  String _subtitle(AccountOverview d) {
    final id = d.id;
    if (d.name != null && d.contact != null) return d.contact!;
    if (id != null && id.isNotEmpty) {
      return 'ID ${id.length <= 8 ? id : id.substring(0, 8)}';
    }
    return d.contact ?? '未绑定手机号';
  }

  Widget _statusChip(DshColors c, AccountOverview d) {
    final ok = d.signedIn;
    final label = d.status == null
        ? '状态未知'
        : (ok ? '已登录' : '未登录');
    final color = ok ? c.success : c.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  /* ---------------- 余额 ---------------- */

  Widget _balanceCard(DshColors c, AccountOverview d) {
    final w = d.primaryWallet;
    final bonus = d.primaryBonus;

    return FluentCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DshIcon(DshGlyph.payments, size: 15, color: c.textSecondary),
              const SizedBox(width: 6),
              Text(
                '账户余额',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
              const Spacer(),
              if (d.balanceError != null)
                Text(
                  '读取失败',
                  style: TextStyle(fontSize: 10.5, color: c.danger),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                w?.display ?? '—',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                w?.currency ?? '',
                style: TextStyle(fontSize: 11.5, color: c.textTertiary),
              ),
            ],
          ),
          if (bonus != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '赠金 ${bonus.display}',
                  style: TextStyle(fontSize: 11.5, color: c.textTertiary),
                ),
                const SizedBox(width: 8),
                Text(
                  bonus.amount > 0 ? '可抵扣' : '暂无赠金',
                  style: TextStyle(fontSize: 10.5, color: c.textTertiary),
                ),
              ],
            ),
          ],
          if (d.balanceError != null) ...[
            const SizedBox(height: 6),
            Text(
              d.balanceError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: c.danger),
            ),
          ],
        ],
      ),
    );
  }

  /* ---------------- 账户动作 ---------------- */

  /// 只有**账户相关**的动作留在这里。
  ///
  /// 为什么去掉「文件管理 / 连接设置 / 检查更新」：那三个在别处都已经有唯一入口了
  /// （☰ 抽屉里是文件管理 / 检查更新，标题栏 ⚙ 是连接设置），
  /// 在这儿再放一遍就是三处重复 —— 用户原话「很多按键都冗余了」。
  /// 一个功能只留一个入口，「我的」只放账号/钱/关于。
  Widget _actionsCard(DshColors c, AccountOverview d) {
    final rows = <Widget>[
      if (d.usageUrl != null)
        _row(
          c,
          glyph: DshGlyph.trace,
          title: '用量明细',
          subtitle: '在浏览器里查看调用记录',
          onTap: () => _open('用量链接', d.usageUrl!),
        ),
      if (d.topUpUrl != null)
        _row(
          c,
          glyph: DshGlyph.payments,
          title: '充值',
          subtitle: '打开浏览器，去 DeepSeek 平台充值',
          onTap: () => _open('充值链接', d.topUpUrl!),
        ),
    ];

    if (rows.isEmpty) return const SizedBox.shrink();

    return FluentCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: rows),
    );
  }

  Widget _row(
    DshColors c, {
    required DshGlyph glyph,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          child: Row(
            children: [
              DshIcon(glyph, size: 18, color: c.textPrimary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 13.5, color: c.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.textTertiary),
                    ),
                  ],
                ),
              ),
              Transform.rotate(
                angle: -math.pi / 2,
                child: DshIcon(DshGlyph.expandMore, size: 14, color: c.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ---------------- 关于 ---------------- */

  Widget _aboutCard(DshColors c) {
    return FluentCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'DSH 工作台',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _version.isEmpty ? '' : 'v$_version',
                style: TextStyle(fontSize: 11.5, color: c.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '手机端远控 DeepSeek Harness —— 看实时输出、回消息、传文件',
            style: TextStyle(fontSize: 11, height: 1.4, color: c.textTertiary),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _open(
              '仓库地址',
              'https://github.com/ht34robot-173000/dsh-flutter-workbench',
            ),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DshIcon(DshGlyph.openInNew, size: 13, color: c.accent),
                  const SizedBox(width: 5),
                  Text(
                    'github.com/ht34robot-173000/dsh-flutter-workbench',
                    style: TextStyle(fontSize: 11, color: c.accent),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
