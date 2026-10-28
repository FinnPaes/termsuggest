#!/bin/zsh
# Installs termsuggest from this folder:
#   1. checks node (>= 20)
#   2. builds the floating window app (overlay/TermSuggest.app) when Xcode
#      command line tools are available
#   3. adds the plugin to ~/.zshrc
#   4. restarts a running daemon / window so the new version is used
#
# Usage: ./install.sh
emulate -L zsh
setopt err_return

dir=${0:A:h}
rc=${ZDOTDIR:-$HOME}/.zshrc
ok()   { print -P "%F{green}✓%f $1" }
warn() { print -P "%F{yellow}!%f $1" }
fail() { print -P "%F{red}✗%f $1"; exit 1 }

print -P "%BInstalling termsuggest%b from $dir\n"

# 1. node
local node=${TERMSUGGEST_NODE:-${commands[node]}}
[[ -n $node ]] || fail "node not found. Install it first (e.g. 'brew install node') and run this again."
local -i major=${${$($node --version)#v}%%.*}
(( major >= 20 )) || fail "node $($node --version) is too old, termsuggest needs node 20 or newer."
ok "node $($node --version)"

[[ -f $dir/specs/index.json ]] || fail "specs/ is missing: run 'npm install && npm run build-specs' first (see README)."
ok "$(( $(print -l $dir/specs/**/*.js(N) | wc -l) )) completion specs"

# 2. floating window (macOS)
if [[ $OSTYPE == darwin* ]]; then
  if [[ -n ${commands[swiftc]} ]] && swiftc --version >/dev/null 2>&1; then
    local bin=$dir/overlay/TermSuggest.app/Contents/MacOS/TermSuggest
    # Only rebuild when needed: a rebuilt app needs Accessibility access again.
    if [[ -x $bin && ! $dir/overlay/main.swift -nt $bin ]]; then
      ok "floating window app is up to date"
    elif $dir/overlay/build.sh >/dev/null 2>&1; then
      ok "built overlay/TermSuggest.app (floating window)"
    else
      warn "building the floating window failed; suggestions will be shown inside the terminal"
    fi
  else
    warn "Xcode command line tools not found, so no floating window (suggestions are shown inside the terminal)."
    warn "Run 'xcode-select --install' and then ./install.sh again to get the window."
  fi
fi

# 3. ~/.zshrc
if grep -qF "$dir/termsuggest.zsh" $rc 2>/dev/null; then
  ok "already in $rc"
else
  # Drop a line from an install in another location, if any.
  if grep -q '/termsuggest.zsh"$' $rc 2>/dev/null; then
    sed -i '' '/^# termsuggest: Fig-style command suggestions$/d; /\/termsuggest\.zsh"$/d' $rc
  fi
  print -r -- $'\n# termsuggest: Fig-style command suggestions\nsource "'$dir'/termsuggest.zsh"' >> $rc
  ok "added to $rc"
fi

# 4. restart running parts
pkill -f "$dir/src/daemon.js" 2>/dev/null || true
pkill -x TermSuggest 2>/dev/null || true
rm -f ${TMPDIR:-/tmp}/termsuggest-$UID.sock(N) ${TMPDIR%/}/termsuggest-$UID.sock(N) 2>/dev/null || true
ok "stopped old daemon/window (they start again automatically)"

print
print -P "%BDone.%b Open a new terminal tab and start typing, e.g. %Bgit %b or %Bcd %b."
if [[ $OSTYPE == darwin* && -d $dir/overlay/TermSuggest.app ]]; then
  print "For exact placement under the cursor, allow TermSuggest under"
  print "System Settings → Privacy & Security → Accessibility (macOS asks the first time)."
fi
