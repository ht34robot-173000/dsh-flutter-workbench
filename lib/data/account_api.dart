/// DSH 工作台 —— 「我的」页数据层（账号 + 余额）。
///
/// 对接宿主 `POST /rw/api/account.overview`（一次取齐三类信息）：
///
/// ```jsonc
/// { "ok": true, "value": {
///     "state":   { "value": { "status": "credential-stored"|"signed-out",
///                             "attempt": null,
///                             "links": { "usageUrl": "...", "topUpUrl": "..." } } },
///     "profile": { "value": { "status": "ready",
///                             "value": { "id": "...", "name": null,
///                                        "contact": "191******92", "avatarUrl": null } } },
///     "balance": { "value": { "status": "ready",
///                             "value":        [ {"currency":"CNY","balance":"7.23"} ],
///                             "bonusWallets": [ {"currency":"CNY","balance":"0.00"} ] } }
/// } }
/// ```
///
/// ⚠️ 三块**各自可能失败**，而且是 `{ error, message }` 而不是 `{ value }` ——
/// 宿主那边 `settle()` 是 Promise.all 里逐项兜的，某一项挂了不该把整页打成错误。
/// 所以这里逐块解包，各自留一个 `xxxError`。
///
/// 还有一层：`profile` / `balance` 的 `value.status` 可能是 `'ready'` 以外的值
/// （未登录、凭据换掉），此时没有 `value.value`。
library;

/// 一个钱包。
class AccountWallet {
  final String currency;

  /// 宿主给的是**字符串**（`"7.23"`），不是数字 —— 别直接当 num 用。
  final String balance;

  const AccountWallet({required this.currency, required this.balance});

  double get amount => double.tryParse(balance) ?? 0;

  /// CNY→¥，USD→$，其余用币种代码本身。
  String get symbol {
    switch (currency.toUpperCase()) {
      case 'CNY':
        return '¥';
      case 'USD':
        return r'$';
      default:
        return currency.toUpperCase();
    }
  }

  /// 金额显示：整数部分不动，小数保留两位（宿主本身是两位，这里兜异常值）。
  String get display {
    final v = amount;
    final s = v.toStringAsFixed(2);
    return '$symbol$s';
  }

  static List<AccountWallet> listFrom(Object? raw) {
    final out = <AccountWallet>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final cur = (e['currency'] ?? '').toString();
        final bal = (e['balance'] ?? '').toString();
        if (cur.isEmpty) continue;
        out.add(AccountWallet(currency: cur, balance: bal.isEmpty ? '0' : bal));
      }
    }
    return out;
  }
}

/// 「我的」页的一次快照。
class AccountOverview {
  /// `credential-stored` / `signed-out`；拿不到就是 null。
  final String? status;

  final String? id;
  final String? name;
  final String? contact;
  final String? avatarUrl;

  final List<AccountWallet> wallets;
  final List<AccountWallet> bonuses;

  final String? usageUrl;
  final String? topUpUrl;

  /// 三块各自的失败原因（有值就说明那一块没取到）。
  final String? stateError;
  final String? profileError;
  final String? balanceError;

  const AccountOverview({
    this.status,
    this.id,
    this.name,
    this.contact,
    this.avatarUrl,
    this.wallets = const [],
    this.bonuses = const [],
    this.usageUrl,
    this.topUpUrl,
    this.stateError,
    this.profileError,
    this.balanceError,
  });

  /// 凭据已存（= 已登录）。`signed-out` 时页面要引导去电脑上登录。
  bool get signedIn => status == 'credential-stored';

  /// 整页都失败（三块全挂）—— 此时才显示错误页。
  bool get allFailed =>
      stateError != null && profileError != null && balanceError != null;

  /// 标题：有名字用名字，没有就用打码的手机号，再没有就兜底文案。
  String get displayName {
    final n = (name ?? '').trim();
    if (n.isNotEmpty) return n;
    final ct = (contact ?? '').trim();
    if (ct.isNotEmpty) return ct;
    return signedIn ? 'DSH 账号' : '未登录';
  }

  /// 头像里显示的首字（没头像时）。
  String get initial {
    final n = displayName.trim();
    if (n.isEmpty) return 'D';
    return n.firstChar;
  }

  AccountWallet? get primaryWallet => wallets.isEmpty ? null : wallets.first;
  AccountWallet? get primaryBonus => bonuses.isEmpty ? null : bonuses.first;

  static AccountOverview fromValue(Map<String, dynamic>? value) {
    final stateBlk = _asMap(value?['state']);
    final profileBlk = _asMap(value?['profile']);
    final balanceBlk = _asMap(value?['balance']);

    /*
     * ⚠️ 三层嵌套，剥的层数不一样：
     *
     *   state   : { value: { status, attempt, links } }        ← 只包一层
     *   profile : { value: { status, value: { id, name, …} } } ← 包两层
     *   balance : { value: { status, value: [...], bonusWallets: [...] } }
     *
     * 少剥一层的话 `profileV?['contact']` 永远是 null，
     * 界面上就会一直显示「DSH 账号」而看不到手机号（第一版就是这么错的）。
     */
    final stateV = _unwrap(stateBlk);
    // profile 内层还是对象 → 剥两次
    final profileV = _unwrap(_unwrap(profileBlk));
    // balance 内层的 `value` 是**数组**（钱包列表），只剥一次，
    // 再剥就变成「拿数组当 Map」→ null（第一版就栽在这）。
    final balanceV = _unwrap(balanceBlk);

    final links = _asMap(stateV?['links']);

    return AccountOverview(
      status: _str(stateV?['status']),
      id: _str(profileV?['id']),
      name: _str(profileV?['name']),
      contact: _str(profileV?['contact']),
      avatarUrl: _str(profileV?['avatarUrl']),
      wallets: AccountWallet.listFrom(balanceV?['value']),
      bonuses: AccountWallet.listFrom(balanceV?['bonusWallets']),
      usageUrl: _str(links?['usageUrl']),
      topUpUrl: _str(links?['topUpUrl']),
      stateError: _errOf(stateBlk),
      profileError: _errOf(profileBlk),
      balanceError: _errOf(balanceBlk),
    );
  }

  /// `{ value: {...} }` → `{...}`；`{ error }` → null。
  static Map<String, dynamic>? _unwrap(Map<String, dynamic>? blk) {
    if (blk == null || blk['error'] != null) return null;
    final v = blk['value'];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  static String? _errOf(Map<String, dynamic>? blk) {
    if (blk == null) return 'missing';
    final e = blk['error'];
    if (e == null) return null;
    final msg = (blk['message'] ?? '').toString();
    return msg.isEmpty ? e.toString() : '$e：$msg';
  }

  static Map<String, dynamic>? _asMap(Object? raw) =>
      raw is Map ? raw.cast<String, dynamic>() : null;

  static String? _str(Object? raw) {
    if (raw == null) return null;
    final s = raw.toString().trim();
    return s.isEmpty ? null : s;
  }
}

extension on String {
  /// 取第一个「字符」（避免把 emoji / 代理对劈开）。
  String get firstChar =>
      runes.isEmpty ? '' : String.fromCharCode(runes.first);
}
