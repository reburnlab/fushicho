#!/bin/bash
# fushicho installer (also the updater: run it again after pulling a new version).
# Double-click it in Finder, or run it in Terminal.
#   1. makes a signing certificate that lives only on this Mac (first time only; macOS asks for your password once)
#   2. builds fushicho and puts it in ~/Library/Application Support/fushicho/
#   3. registers a login agent (local.fushicho) so it starts by itself
#   4. opens the Accessibility settings so you can switch it on
# Signing with the same local certificate every time means the Accessibility permission survives updates.
cd "$(dirname "$0")" || exit 1
CERT="fushicho Local Signing"
ID="local.fushicho"
APPDIR="$HOME/Library/Application Support/fushicho"
BIN="$APPDIR/fushicho"
PLIST="$HOME/Library/LaunchAgents/$ID.plist"
LOG="$HOME/Library/Logs/fushicho.log"
KC="$HOME/Library/Keychains/login.keychain-db"

if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"ja'; then JA=1; else JA=0; fi
t() { if [ $JA = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
say() { printf '\n\033[1m%s\033[0m\n' "$(t "$1" "$2")"; }
stop() { printf '\n\033[31m%s\033[0m\n\n' "$(t "$1" "$2")"; read -r -p "$(t 'Enter でこの窓を閉じる ' 'Press Return to close ')" _; exit 1; }

say "fushicho を入れます。" "Installing fushicho."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1
  stop "開発ツールが入っていません。今出たダイアログで「インストール」を押して、終わったらもう一度これを実行してください。" \
       "The Xcode Command Line Tools are missing. Click Install in the dialog that just appeared, then run this again."
fi
[ -d /Applications/Claude.app ] || say "（注意）/Applications に Claude のアプリが見つかりません。入れてから使ってください。" \
                                        "(Note) Claude.app was not found in /Applications. Install it before relying on fushicho."

# 1. local signing certificate (once per Mac)
if ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CERT"; then
  say "署名用の証明書をこの Mac の中に作ります。このあと macOS がパスワードを聞きます。" \
      "Creating a signing certificate on this Mac. macOS will ask for your password next."
  T=$(mktemp -d) || stop "一時フォルダを作れませんでした。" "Could not create a temporary folder."
  cat > "$T/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  P=$(openssl rand -hex 16)
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/cert.cnf" 2>/dev/null \
    && openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$P" -name "$CERT" 2>/dev/null \
    && security import "$T/id.p12" -k "$KC" -P "$P" -T /usr/bin/codesign >/dev/null \
    && security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$T/cert.pem"
  OK=$?
  rm -rf "$T"                                   # the private key stays only in the keychain
  [ $OK = 0 ] || stop "証明書を作れませんでした。" "Could not create the certificate."
fi

# 2. build + sign + install
say "ビルドします（1 分ほど）。キーチェーンの確認が出たら、パスワードを打って「常に許可」を押してください。" \
    "Building (about a minute). If a keychain prompt appears, enter your password and choose Always Allow."
mkdir -p build "$APPDIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
swiftc -O fushicho.swift -o build/fushicho || stop "ビルドに失敗しました。" "The build failed."
codesign -f -s "$CERT" -i "$ID" build/fushicho || stop "署名に失敗しました。" "Signing failed."
launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null
cp build/fushicho "$BIN" || stop "プログラムを置けませんでした。" "Could not install the binary."

# 3. login agent
cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ID</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
XML
ok=0
for i in 1 2 3 4 5; do
  sleep 2
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then ok=1; break; fi
done
[ $ok = 1 ] || stop "自動起動に登録できませんでした。" "Could not register the login agent."
sleep 3

# 4. Accessibility
if ! tail -3 "$LOG" 2>/dev/null | grep -q "Accessibility: granted"; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  say "システム設定の「アクセシビリティ」を開きました。一覧の fushicho をオンにしてください。" \
      "Opened System Settings → Accessibility. Switch on fushicho in the list."
  echo "$(t "（一覧に無ければ「＋」を押して、次のファイルを足す）" "(If it is not listed, press + and add this file:)")"
  echo "  $BIN"
  read -r -p "$(t 'オンにしたら Enter ' 'Press Return when it is on ')" _
  launchctl kickstart -k "gui/$(id -u)/$ID"
  sleep 4
fi
echo; tail -3 "$LOG"
if tail -3 "$LOG" | grep -q "Accessibility: granted"; then
  say "入りました。Claude のアプリが立ち上がり直してリモートコントロールが切れたら、1 分ほどで自動でつなぎ直します。" \
      "Installed. When the Claude app relaunches and drops Remote Control, fushicho reconnects it within about a minute."
else
  say "入りましたが、アクセシビリティの許可がまだです。オンにしてから、もう一度これを実行してください。" \
      "Installed, but the Accessibility permission is still off. Switch it on and run this again."
fi
echo "$(t '記録' 'Log'): $LOG"
echo "$(t '状態を見る' 'Status'): \"$BIN\" --status"
echo; read -r -p "$(t 'Enter でこの窓を閉じる ' 'Press Return to close ')" _
