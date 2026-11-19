/// DSH 工作台 —— 配对二维码的解析。
///
/// 单独抽成纯函数，因为这是**最容易出错、又最值得测试**的一环：
/// 解析错了表现为「扫码后连不上」，而界面上什么都看不出来。
///
/// 二维码内容格式（照桌面端 `client.js:918`）：
///
///     <baseUrl>/rw/pair?code=123456
///
/// ⚠️ 必须**同时**拿到 baseUrl 和 code。
/// 只取 code、baseUrl 沿用上一个值，是「扫了码却连到旧机器」的典型原因。
library;

/// 一次成功解析的结果。
class PairScanResult {
  /// 从二维码里读到的基础地址，例如 `https://dsh.example.com`。
  /// 已去掉末尾斜杠和 `/rw/pair` 那段路径。
  final String baseUrl;

  /// 6 位配对码（或 nonce）。
  final String code;

  const PairScanResult({required this.baseUrl, required this.code});

  @override
  bool operator ==(Object other) =>
      other is PairScanResult &&
      other.baseUrl == baseUrl &&
      other.code == code;

  @override
  int get hashCode => Object.hash(baseUrl, code);

  @override
  String toString() => 'PairScanResult($baseUrl, $code)';
}

/// 解析一条扫描到的文本。认不出就返回 null（调用方据此提示「不是配对码」）。
///
/// 兼容以下几种写法，都是实际可能出现的：
///
/// | 输入 | 说明 |
/// |---|---|
/// | `https://x/rw/pair?code=123456` | 桌面端面板生成的标准格式 |
/// | `http://127.0.0.1:19387/rw/pair?code=123456` | 局域网 / 本机调试 |
/// | `https://x/rw/pair?code=123456&foo=bar` | 参数顺序变化、带额外参数 |
/// | `123456` | 纯 6 位码（用户手输或自制二维码），此时 baseUrl 为空 |
///
/// 认不出的情况：不是 URL 且不是 6 位数字、URL 里没有 code 参数、
/// code 长度不对。
PairScanResult? parsePairQr(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;

  /*
   * 1) 纯 6 位数字：当作只有码、没有地址。
   *    调用方会用当前已保存的地址 —— 这是「同一个服务器、只换了码」的场景。
   */
  if (RegExp(r'^\d{6}$').hasMatch(text)) {
    return PairScanResult(baseUrl: '', code: text);
  }

  // 2) 必须是 http(s) URL
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }

  final code = uri.queryParameters['code']?.trim() ?? '';
  if (code.isEmpty) return null;

  /*
   * code 可以是 6 位数字，也可以是 nonce 串（宿主 auth.accept 两者都收）。
   * 这里只做长度下限校验，不强制纯数字 —— 将来换 nonce 也能用。
   */
  if (code.length < 6) return null;

  /*
   * baseUrl 要**丢掉 /rw/pair 那段路径**。
   *
   * `uri.origin` 只给 scheme://host:port，正好是我们要的。
   * 但它对某些 scheme 返回 'null' 字符串，所以兜底手工拼。
   */
  String base;
  final origin = uri.origin;
  if (origin.isNotEmpty && origin != 'null') {
    base = origin;
  } else {
    final port = uri.hasPort ? ':${uri.port}' : '';
    base = '${uri.scheme}://${uri.host}$port';
  }
  // 去掉末尾斜杠，避免拼出 `//rw/api/...` 这种双斜杠
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }

  return PairScanResult(baseUrl: base, code: code);
}

