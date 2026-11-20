// 「我的」页数据解析测试。
//
// 样本就是本机宿主真实返回的那一份（2026-11-20 抓的 account.overview），
// 重点固定三件事：
//   1. balance 里金额是**字符串**，不是数字；
//   2. 三块（state/profile/balance）各自可能失败，不能整体报错；
//   3. signed-out 时没有 profile/balance 的 value。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/account_api.dart';

Map<String, dynamic> _j(String s) => jsonDecode(s) as Map<String, dynamic>;

const _real = '''
{
  "state": {"value": {"status": "credential-stored", "attempt": null,
    "links": {"usageUrl": "https://platform.deepseek.com/usage",
              "topUpUrl": "https://platform.deepseek.com/top_up"}}},
  "profile": {"value": {"status": "ready",
    "value": {"id": "49cfe869-a52a-4928-b75d-fda799e8126c",
              "avatarUrl": null, "name": null, "contact": "191******92"}}},
  "balance": {"value": {"status": "ready",
    "value": [{"currency": "CNY", "balance": "7.23"}],
    "bonusWallets": [{"currency": "CNY", "balance": "0.00"}]}}
}
''';

void main() {
  group('AccountOverview.fromValue', () {
    test('真实返回：已登录 / 打码手机号 / 余额 7.23 / 赠金 0', () {
      final d = AccountOverview.fromValue(_j(_real));
      expect(d.signedIn, isTrue);
      expect(d.displayName, '191******92'); // name 是 null，退化到 contact
      expect(d.contact, '191******92');
      expect(d.initial, '1');
      expect(d.primaryWallet?.currency, 'CNY');
      expect(d.primaryWallet?.display, '¥7.23');
      expect(d.primaryBonus?.display, '¥0.00');
      expect(d.usageUrl, contains('platform.deepseek.com'));
      expect(d.topUpUrl, contains('top_up'));
      expect(d.allFailed, isFalse);
    });

    test('金额是字符串，不能当 num 用', () {
      final d = AccountOverview.fromValue(_j(_real));
      // 直接 double.tryParse('7.23') 才有值；如果是 num 早就崩了
      expect(d.primaryWallet!.amount, closeTo(7.23, 1e-9));
    });

    test('signed-out：没登录时没有 profile/balance 的 value', () {
      final d = AccountOverview.fromValue(_j('''
        {"state": {"value": {"status": "signed-out", "attempt": null,
                              "links": {"usageUrl": "u", "topUpUrl": "t"}}},
         "profile": {"value": {"status": "signed-out"}},
         "balance": {"value": {"status": "signed-out"}}}
      '''));
      expect(d.signedIn, isFalse);
      expect(d.displayName, '未登录');
      expect(d.wallets, isEmpty);
      expect(d.primaryWallet, isNull);
      // 不算失败：状态明确是「未登录」，页面要引导去电脑上登录
      expect(d.allFailed, isFalse);
    });

    test('某一块挂了（profile 报错）不影响其它两块', () {
      final d = AccountOverview.fromValue(_j('''
        {"state": {"value": {"status": "credential-stored", "links": {}}},
         "profile": {"error": "profile-failed", "message": "timeout"},
         "balance": {"value": {"status": "ready",
            "value": [{"currency": "CNY", "balance": "1.00"}], "bonusWallets": []}}}
      '''));
      expect(d.profileError, contains('profile-failed'));
      expect(d.primaryWallet?.display, '¥1.00');
      expect(d.allFailed, isFalse, reason: '只有一块失败时不该整页报错');
    });

    test('三块全挂才算整页失败', () {
      final d = AccountOverview.fromValue(_j('''
        {"state": {"error": "x"}, "profile": {"error": "y"}, "balance": {"error": "z"}}
      '''));
      expect(d.allFailed, isTrue);
      expect(d.signedIn, isFalse);
    });

    test('空 / 缺字段不抛', () {
      expect(AccountOverview.fromValue(null).allFailed, isTrue);
      final d = AccountOverview.fromValue(_j('{}'));
      expect(d.status, isNull);
      expect(d.wallets, isEmpty);
      expect(d.displayName, '未登录');
    });
  });

  group('AccountWallet', () {
    test('币种符号映射', () {
      expect(const AccountWallet(currency: 'CNY', balance: '1').symbol, '¥');
      expect(const AccountWallet(currency: 'USD', balance: '1').symbol, r'$');
      expect(const AccountWallet(currency: 'JPY', balance: '1').symbol, 'JPY');
    });

    test('异常金额不崩，显示 0.00', () {
      expect(const AccountWallet(currency: 'CNY', balance: 'abc').display, '¥0.00');
      expect(const AccountWallet(currency: 'CNY', balance: '').display, '¥0.00');
    });

    test('listFrom 跳过没有 currency 的项', () {
      final l = AccountWallet.listFrom([
        {'currency': 'CNY', 'balance': '2.00'},
        {'balance': '9.00'},
        'garbage',
      ]);
      expect(l, hasLength(1));
      expect(l.first.display, '¥2.00');
    });

    test('多币种时取第一个当主钱包', () {
      final d = AccountOverview.fromValue(_j('''
        {"state": {"value": {"status": "credential-stored"}},
         "profile": {"value": {"status": "ready", "value": {"id": "x"}}},
         "balance": {"value": {"status": "ready",
            "value": [{"currency": "USD", "balance": "3.00"},
                      {"currency": "CNY", "balance": "8.00"}], "bonusWallets": []}}}
      '''));
      expect(d.primaryWallet?.currency, 'USD');
      expect(d.primaryWallet?.display, r'$3.00');
    });
  });
}
