# fushicho

Keeps **Remote Control** alive in the Claude desktop app on macOS.

*fushicho* (不死鳥) is Japanese for phoenix: when the connection dies, it comes back.

[日本語の説明は下にあります](#日本語)

## The problem

You start a Claude Code session in the desktop app, switch on Remote Control (`/rc`) and drive it from your
phone. Later the desktop app updates itself and relaunches. The session comes back, but its Remote Control
bridge does not — and it stays down until someone types into that session **on the Mac**. From the phone there
is nothing you can do.

## What fushicho does

A small background agent on the Mac:

1. follows the app's log (`~/Library/Logs/Claude/main.log`), reading only what was appended since the last look;
2. notices *"Remote Control was on, then the app relaunched"*;
3. waits until the app has settled and the Mac has been idle for 30 seconds (it never interrupts you while you
   are typing, and it does nothing while the screen is locked);
4. brings the Claude app forward, reopens that session with the app's own `claude://code/continue?session=…`
   link, types `/rc` and presses Return;
5. checks the log for the result. `/rc` is a toggle, so if that switched it *off*, it sends it once more.

If you switched Remote Control off yourself, fushicho leaves it off. If you quit the app, it does not start it.

Typical time from relaunch to reconnected: about a minute.

## Install

Requirements: macOS 12 or later, the Xcode Command Line Tools, the Claude desktop app.

1. Download this folder.
2. Double-click **`install.command`**.
3. macOS asks for your password once (to trust a signing certificate that is created on, and never leaves,
   your Mac). If a keychain prompt appears during the build, choose **Always Allow**.
4. System Settings opens at *Privacy & Security → Accessibility*. Switch **fushicho** on, go back to the
   Terminal window and press Return.

To update, replace the folder and double-click `install.command` again; the permission is kept.
To remove, double-click `uninstall.command`.
The signing certificate stays in your keychain after uninstalling. To delete it as well:
`security delete-identity -c "fushicho Local Signing" ~/Library/Keychains/login.keychain-db`

## Use

Nothing to do — it runs at login.

```
"~/Library/Application Support/fushicho/fushicho" --status   # what it last saw
"~/Library/Application Support/fushicho/fushicho" --now      # reconnect right now
touch "~/Library/Application Support/fushicho/paused"         # pause (delete the file to resume)
tail ~/Library/Logs/fushicho.log                              # what it did
```

## What you should know before trusting it

- **It types into your Mac.** That is why it needs the Accessibility permission. When it reconnects, the Claude
  app comes to the front and any unsent draft in that session's input box is cleared.
- **It depends on undocumented behaviour**: the wording of the app's log lines and the `claude://code/continue`
  link. Neither is a promised interface. An app update can break fushicho at any time; if Remote Control stops
  coming back, look at the log.
- **It is local only.** No network listener, no telemetry, nothing is sent anywhere. It reads one log file and
  writes its own log and a small status file.
- **It restores one session**: the one whose Remote Control was switched most recently. If you keep several
  sessions bridged at the same time, the others stay down.
- It is a workaround. If the app starts restoring Remote Control by itself after a relaunch, you no longer need
  this — uninstall it.
- Tested with Claude desktop 2.31226.1 on macOS 26 (Intel and Apple silicon). Confirmed: reconnecting after a
  manual quit and reopen, and after a full restart of the Mac (it starts at login and keeps its permission).
  Reconnecting after a real auto-update relaunch is expected to work the same way, but check your own log the
  first time it happens.

MIT License (see `LICENSE`). Provided as is, without warranty of any kind; use it at your own risk.

Not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic, PBC.

---

## 日本語

Claude のデスクトップアプリ（macOS）の **リモートコントロール** を、切れたら自動でつなぎ直す小さな常駐プログラムです。

名前は「不死鳥」から。切れても、戻ってきます。

### 何に困っていたか

デスクトップアプリで Claude Code のやり取りを始め、`/rc` でリモートコントロールをオンにして、スマホから続きをやる。
ところが、アプリが自分でアップデートして立ち上げ直すと、やり取りは戻るのにリモートコントロールだけが切れたままになり、
**Mac の前で** そのやり取りに何か打ち込むまで戻りません。スマホからは打つ手がありません。

### fushicho がやること

1. アプリのログ（`~/Library/Logs/Claude/main.log`）を、前回から増えた分だけ読む
2. 「オンだったのに、アプリが立ち上がり直して切れた」のを見つける
3. アプリが落ち着き、Mac が 30 秒以上触られていないのを待つ（使っている最中には割り込まない。画面ロック中は何もしない）
4. Claude のアプリを前に出し、アプリ自身のリンク `claude://code/continue?session=…` でそのやり取りを開き、`/rc` を打って Return
5. ログで結果を確かめる。`/rc` は切り替えなので、それで切れてしまったらもう一度送る

自分でオフにしたときは、オフのままにします。アプリを終了したときに、勝手に立ち上げることもしません。
立ち上がり直してから戻るまで、だいたい 1 分です。

### 入れ方

必要なもの: macOS 12 以上、Xcode Command Line Tools、Claude のデスクトップアプリ。

1. このフォルダを手元に置く
2. **`install.command`** をダブルクリック
3. macOS がパスワードを 1 回聞きます（この Mac の中だけに作る署名用の証明書を信頼するため）。
   ビルド中にキーチェーンの確認が出たら「常に許可」
4. システム設定の「プライバシーとセキュリティ → アクセシビリティ」が開くので、**fushicho** をオンにして、
   ターミナルの窓に戻って Enter

新しい版にするときは、フォルダを置き換えてもう一度 `install.command`（許可は残ります）。
外すときは `uninstall.command`。
外したあとも、署名用の証明書はキーチェーンに残ります。それも消すなら:
`security delete-identity -c "fushicho Local Signing" ~/Library/Keychains/login.keychain-db`

### 使い方

何もしなくて大丈夫です。ログイン時に自動で立ち上がります。

```
"~/Library/Application Support/fushicho/fushicho" --status   # 最後に見た状態
"~/Library/Application Support/fushicho/fushicho" --now      # 今すぐつなぎ直す
touch "~/Library/Application Support/fushicho/paused"         # 止める（このファイルを消すと再開）
tail ~/Library/Logs/fushicho.log                              # やったことの記録
```

### 入れる前に知っておくこと

- **Mac に文字を打ち込みます。** そのためにアクセシビリティの許可が要ります。つなぎ直すとき、Claude のアプリが前に出て、
  そのやり取りの入力欄の書きかけは消えます
- **公式に約束されていない動きに頼っています**（ログの書き方と `claude://code/continue` のリンク）。
  アプリの更新で、いつ動かなくなってもおかしくありません。戻らなくなったら、ログを見てください
- **Mac の中だけで動きます。** 外からの待ち受けも、外への送信もありません
- **戻すのは 1 つのやり取りだけです。** 最後にリモートコントロールを切り替えたやり取りを戻します。
  複数のやり取りを同時につないでいる場合、ほかは切れたままです
- これは回避策です。アプリが自分でリモートコントロールを戻すようになったら、もう要りません。外してください
- 確かめた環境: Claude デスクトップ 2.31226.1、macOS 26（Intel と Apple シリコン）。手で終了して開き直した場合と、
  Mac 本体を再起動した場合（ログイン時に自分で立ち上がり、許可も残る）に、つなぎ直すことは確認済み。
  自動アップデートでの立ち上げ直しも同じ動きになるはずですが、最初の 1 回は自分のログで確かめてください

MIT ライセンスです（`LICENSE`）。無保証で、使って起きた不具合や損害について作者は責任を負いません。自分の判断で使ってください。

Anthropic とは無関係の、非公式の道具です。
