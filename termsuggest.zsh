# termsuggest — Fig-style command suggestions for zsh.
#
# Source this file at the END of ~/.zshrc. It starts a small node daemon in the
# background (src/daemon.js) and shows its suggestions in a dropdown under the
# cursor while you type.
#
#   ↑/↓     move through the suggestions
#   Tab     insert the selected suggestion
#   Enter   insert the selected suggestion if you moved through the list,
#           otherwise run the command as usual
#   Esc     hide the dropdown until you type again
#
# Settings (set before sourcing):
#   TERMSUGGEST_MAX_ROWS=8        rows visible at once
#   TERMSUGGEST_MAX_WIDTH=90      max dropdown width
#   TERMSUGGEST_ENTER=navigated   navigated | always | never: when Enter inserts
#   TERMSUGGEST_NODE=/path/node   node binary (default: node on $PATH)
#   TERMSUGGEST_SHOW_HIDDEN=1     also list dotfiles without typing a "."
#   TERMSUGGEST_UI=overlay        overlay (floating macOS window) | inline (drawn in the terminal)
#   TERMSUGGEST_COLOR_*           colors of the inline dropdown, see _ts_colors below

[[ -o interactive ]] || return 0
zmodload zsh/net/socket zsh/datetime 2>/dev/null || return 0
(( ${+_TS_LOADED} )) && return 0
typeset -g _TS_LOADED=1

typeset -g _TS_ROOT=${${(%):-%x}:A:h}
typeset -g _TS_NODE=${TERMSUGGEST_NODE:-${commands[node]}}
typeset -g _TS_SOCK=${TMPDIR:-/tmp}
_TS_SOCK=${_TS_SOCK%/}/termsuggest-$UID.sock
typeset -g _TS_LOG=${XDG_STATE_HOME:-$HOME/.local/state}/termsuggest/daemon.log

typeset -gi _TS_FD=-1 _TS_REQ=0 _TS_QID=0 _TS_SEL=0 _TS_NAV=0 _TS_HIDDEN=0 _TS_TOP=0
typeset -gi _TS_RLEN=0 _TS_TSTART=0 _TS_PROMPTW=0 _TS_SPAWNED=0
typeset -gi _TS_OVERLAY=0 _TS_OVL_SHOWN=0 _TS_P0=-1
typeset -g _TS_CELLW=0 _TS_CELLH=0
typeset -g _TS_LAST=
typeset -ga _TS_INS _TS_DISP _TS_DESC _TS_KIND
typeset -gA _TS_ORIG

typeset -gA _ts_colors=(
  bg        ${TERMSUGGEST_COLOR_BG:-236}
  fg        ${TERMSUGGEST_COLOR_FG:-252}
  sel_bg    ${TERMSUGGEST_COLOR_SEL_BG:-25}
  sel_fg    ${TERMSUGGEST_COLOR_SEL_FG:-255}
  desc      ${TERMSUGGEST_COLOR_DESC:-245}
  subcommand ${TERMSUGGEST_COLOR_SUBCOMMAND:-117}
  option    ${TERMSUGGEST_COLOR_OPTION:-180}
  folder    ${TERMSUGGEST_COLOR_FOLDER:-111}
  file      ${TERMSUGGEST_COLOR_FILE:-252}
  command   ${TERMSUGGEST_COLOR_COMMAND:-114}
  arg       ${TERMSUGGEST_COLOR_ARG:-222}
)

# ------------------------------------------------------------------ daemon

_ts_disconnect() {
  if (( _TS_FD >= 0 )); then
    zle -F $_TS_FD 2>/dev/null
    exec {_TS_FD}>&- 2>/dev/null
  fi
  _TS_FD=-1
}

_ts_connect() {
  (( _TS_FD >= 0 )) && return 0
  if ! zsocket $_TS_SOCK 2>/dev/null; then
    [[ -n $_TS_NODE && -x $_TS_NODE ]] || return 1
    # Don't keep spawning daemons if one is still starting or failed.
    (( EPOCHSECONDS - _TS_SPAWNED < 5 )) && return 1
    _TS_SPAWNED=$EPOCHSECONDS
    mkdir -p ${_TS_LOG:h} 2>/dev/null
    ( cd / && exec $_TS_NODE $_TS_ROOT/src/daemon.js $_TS_SOCK >>$_TS_LOG 2>&1 </dev/null ) &!
    local -i i
    for (( i = 0; i < 40; i++ )); do
      sleep 0.05
      zsocket $_TS_SOCK 2>/dev/null && break
    done
    (( i < 40 )) || return 1
  fi
  _TS_FD=$REPLY
  zle -F -w $_TS_FD _ts_on_reply 2>/dev/null
  # Every (re)connect tells the daemon about this shell's aliases.
  local -a lines
  local k
  for k in ${(k)aliases}; do lines+=( "$k=$aliases[$k]" ); done
  lines=( ${lines//$'\n'/ } )
  print -rnu $_TS_FD -- "0"$'\x1f'"a"$'\x1f'"$PWD"$'\x1f'"${(pj:\x1e:)lines}"$'\n' 2>/dev/null
  return 0
}

# _ts_send <type> <payload>
_ts_send() {
  _ts_connect || return 1
  local msg="$(( ++_TS_REQ ))"$'\x1f'"$1"$'\x1f'"$PWD"$'\x1f'"${2//$'\n'/$'\x1e'}"
  if ! print -rnu $_TS_FD -- "$msg"$'\n' 2>/dev/null; then
    # Daemon went away: reconnect (restarting it) once and retry.
    _ts_disconnect
    _ts_connect || return 1
    print -rnu $_TS_FD -- "$msg"$'\n' 2>/dev/null || { _ts_disconnect; return 1 }
  fi
  return 0
}

_ts_on_reply() {
  local fd=$1 line
  if [[ -n $2 ]] || ! IFS= read -r -u $fd line; then
    _ts_disconnect
    return
  fi
  local -a f
  f=( "${(@ps:\x1f:)line}" )
  if [[ $f[2] == accept ]]; then
    # A suggestion was clicked in the overlay window.
    if _ts_visible && (( f[3] >= 1 && f[3] <= ${#_TS_INS} )); then
      _TS_SEL=$f[3]
      _ts_accept
      zle -R
    fi
    return
  fi
  (( f[1] == _TS_QID )) || return
  [[ $f[2] == pong ]] && return

  _TS_RLEN=$f[2]
  _TS_TSTART=$f[3]
  _TS_OVERLAY=0
  [[ $f[4] == 1 && ${TERMSUGGEST_UI:-overlay} != inline ]] && _TS_OVERLAY=1
  local -i n=$f[5] i b
  _TS_INS=() _TS_DISP=() _TS_DESC=() _TS_KIND=()
  for (( i = 0; i < n; i++ )); do
    b=$(( 6 + i * 4 ))
    _TS_INS+=( "$f[b]" )
    _TS_DISP+=( "$f[b+1]" )
    _TS_DESC+=( "$f[b+2]" )
    _TS_KIND+=( "$f[b+3]" )
  done
  _TS_SEL=1 _TS_TOP=0 _TS_NAV=0
  _ts_render
  zle -R
}
zle -N _ts_on_reply

# ------------------------------------------------------------------ render

_ts_visible() { (( ${#_TS_INS} > 0 && ! _TS_HIDDEN )) }

_ts_clear() {
  _TS_INS=() _TS_DISP=() _TS_DESC=() _TS_KIND=()
  _TS_SEL=0 _TS_NAV=0
  POSTDISPLAY=
  region_highlight=( ${region_highlight:#*memo=termsuggest} )
  _ts_overlay_hide
}

_ts_overlay_hide() {
  if (( _TS_OVL_SHOWN )); then
    _TS_OVL_SHOWN=0
    _ts_send v "0:0"
  fi
}

# Asks the terminal where the cursor is (and, in iTerm2, how big a cell is)
# so the overlay window can be placed right under the word being typed.
# Sets _TS_P0: screen position where the edit buffer starts, as row*COLUMNS+col.
_ts_probe() {
  emulate -L zsh
  setopt extendedglob
  local resp= c
  local -i want_cell=0
  if [[ $TERM_PROGRAM == iTerm.app && $_TS_CELLW == 0 ]]; then
    want_cell=1
    print -rn -- $'\e]1337;ReportCellSize\a' >/dev/tty
  fi
  print -rn -- $'\e[6n' >/dev/tty
  while IFS= read -rs -k 1 -t 0.3 c </dev/tty; do
    resp+=$c
    [[ $resp == *$'\e['[0-9]##\;[0-9]##R ]] && break
  done
  # Keys typed while we waited for the answer go back to zle.
  local typed=${resp//$'\e]'[^$'\a\e']#($'\a'|$'\e\\')/}
  typed=${typed%$'\e['[0-9]##\;[0-9]##R}
  [[ -n $typed ]] && zle -U -- "$typed"

  if (( want_cell )) && [[ $resp == (#b)*ReportCellSize=([0-9.]##)\;([0-9.]##)* ]]; then
    _TS_CELLH=$match[1] _TS_CELLW=$match[2]
  fi
  if [[ $resp == (#b)*$'\e['([0-9]##)\;([0-9]##)R ]]; then
    local -i row=$match[1] col=$match[2]
    _TS_P0=$(( (row - 1) * COLUMNS + col - 1 - ${(m)#LBUFFER} ))
  fi
}

_ts_overlay_show() {
  (( _TS_P0 < 0 )) && _ts_probe
  (( _TS_P0 < 0 )) && return 1
  local before=${LBUFFER[1,_TS_TSTART]}
  local -i a=$(( _TS_P0 + ${(m)#before} )) c=$(( _TS_P0 + ${(m)#LBUFFER} ))
  _TS_OVL_SHOWN=1
  _ts_send v "$_TS_SEL:1:$(( a / COLUMNS + 1 )):$(( a % COLUMNS + 1 )):$(( c / COLUMNS + 1 )):$(( c % COLUMNS + 1 )):$COLUMNS:$LINES:$_TS_CELLW:$_TS_CELLH"
}

# _ts_fit <text> <width>: truncate/pad text to exactly <width> columns -> REPLY
_ts_fit() {
  local s=$1
  local -i w=$2 sw=${(m)#1}
  if (( sw > w )); then
    s=${s[1,w]}
    while (( ${(m)#s} > w - 1 )); do s=${s[1,-2]}; done
    s+='…'
    sw=${(m)#s}
  fi
  REPLY=$s${(l:w-sw:: :)}
}

# Width of the last line of the prompt, so the dropdown lines up with the word
# being completed (like Fig's popup did).
_ts_measure_prompt() {
  emulate -L zsh
  setopt extendedglob
  local p
  if [[ -o promptsubst ]]; then
    p=${(%)${(e)PS1}} 2>/dev/null
  else
    p=${(%)PS1}
  fi
  p=${p##*$'\n'}
  p=${p//$'\e'\[[0-9;]#[a-zA-Z]/}
  p=${p//$'\e'\][^$'\a']#$'\a'/}
  _TS_PROMPTW=${(m)#p}
}

_ts_render() {
  emulate -L zsh
  region_highlight=( ${region_highlight:#*memo=termsuggest} )
  if ! _ts_visible; then
    POSTDISPLAY=
    _ts_overlay_hide
    return
  fi
  if (( _TS_OVERLAY )); then
    POSTDISPLAY=
    _ts_overlay_show && return
  fi

  local -i n=${#_TS_INS} rows=${TERMSUGGEST_MAX_ROWS:-8} cols=$(( COLUMNS - 1 )) i
  (( rows > n )) && rows=n
  (( _TS_SEL <= _TS_TOP )) && _TS_TOP=$(( _TS_SEL - 1 ))
  (( _TS_SEL > _TS_TOP + rows )) && _TS_TOP=$(( _TS_SEL - rows ))

  # Column widths for the visible window.
  local -i nw=0 dw=0 w
  for (( i = _TS_TOP + 1; i <= _TS_TOP + rows; i++ )); do
    w=${(m)#_TS_DISP[i]}; (( w > nw )) && nw=w
    w=${(m)#_TS_DESC[i]}; (( w > dw )) && dw=w
  done
  (( nw > 40 )) && nw=40
  local -i maxw=${TERMSUGGEST_MAX_WIDTH:-90}
  (( maxw > cols )) && maxw=cols
  (( nw + 2 > maxw )) && nw=$(( maxw - 2 ))
  local -i total=$(( nw + 2 ))
  (( dw > 0 )) && total+=$(( dw + 2 ))
  (( total > maxw )) && total=maxw
  local -i descw=$(( total - nw - 4 ))
  (( n > rows )) && (( total < nw + 9 )) && total=$(( nw + 9 )) && descw=$(( total - nw - 4 ))

  # Indent to the start of the current word.
  (( _TS_PROMPTW < 0 )) && _ts_measure_prompt
  local before=${LBUFFER[1,_TS_TSTART]}
  local -i indent
  if [[ $before == *$'\n'* ]]; then
    before=${before##*$'\n'}
    indent=${(m)#before}
  else
    indent=$(( _TS_PROMPTW + ${(m)#before} ))
  fi
  (( indent > 0 )) && indent=$(( indent - 1 ))
  (( indent + total > cols )) && indent=$(( cols - total ))
  (( indent < 0 )) && indent=0
  local pad=${(l:indent:: :)}

  local out= name desc kindc line
  local -i base=$(( ${#PREDISPLAY} + ${#BUFFER} )) off start
  local -a hl
  local bgc="bg=$_ts_colors[bg]" selc="bg=$_ts_colors[sel_bg],fg=$_ts_colors[sel_fg],bold"
  for (( i = _TS_TOP + 1; i <= _TS_TOP + rows; i++ )); do
    _ts_fit "$_TS_DISP[i]" $nw; name=$REPLY
    desc=$_TS_DESC[i]
    # Scroll position hint on the last row when there are more items.
    if (( i == _TS_TOP + rows && n > rows )); then
      local hint="${_TS_SEL}/${n}"
      _ts_fit "$desc" $(( descw - ${#hint} - 1 )); desc="$REPLY ${hint}"
    elif (( descw > 0 )); then
      _ts_fit "$desc" $descw; desc=$REPLY
    else
      desc=
    fi
    line=" $name"
    (( descw > 0 )) && line+="  $desc"
    line+=" "

    out+=$'\n'$pad
    off=$(( ${#out} ))
    out+=$line
    start=$(( base + off ))
    if (( i == _TS_SEL )); then
      hl+=( "$start $(( start + ${#line} )) $selc memo=termsuggest" )
    else
      kindc=${_ts_colors[$_TS_KIND[i]]:-$_ts_colors[fg]}
      hl+=( "$start $(( start + ${#line} )) $bgc,fg=$_ts_colors[fg] memo=termsuggest" )
      hl+=( "$(( start + 1 )) $(( start + 1 + ${#name} )) fg=$kindc memo=termsuggest" )
      (( descw > 0 )) && hl+=( "$(( start + 3 + ${#name} )) $(( start + ${#line} )) fg=$_ts_colors[desc] memo=termsuggest" )
    fi
  done
  POSTDISPLAY=$out
  region_highlight+=( $hl )
}

# ------------------------------------------------------------------ hooks

_ts_query() {
  _TS_QID=$(( _TS_REQ + 1 ))
  _ts_send q "$LBUFFER" || _ts_clear
}

# Widgets after which the line counts as "typed" and suggestions refresh.
typeset -g _TS_TYPING='*self-insert*|*delete-char*|*kill-word|backward-kill-line|*magic-space|yank|*bracketed-paste*|_ts_tab|_ts_enter|_ts_on_reply|undo|redo'

_ts_line_pre_redraw() {
  [[ $LBUFFER == $_TS_LAST ]] && return
  _TS_LAST=$LBUFFER
  _TS_HIDDEN=0
  if (( ${ISEARCHMATCH_ACTIVE:-0} )) || [[ -z ${LBUFFER//[[:space:]]/} ]] || [[ $LASTWIDGET != ${~_TS_TYPING} ]]; then
    _ts_clear
    return
  fi
  _ts_query
}

_ts_line_init() {
  _TS_LAST=
  _TS_HIDDEN=0
  _TS_PROMPTW=-1  # measured on first render: async prompts may not be done yet
  _TS_P0=-1
  _ts_clear
}

_ts_line_finish() {
  _ts_clear
  _TS_QID=-1
  zle -R
}

_ts_preexec() { [[ -n $1 ]] && _ts_send r "$1" }
_ts_chpwd() { _ts_send d "$PWD" }

# ------------------------------------------------------------------ keys

_ts_orig() {
  zle ${_TS_ORIG[$KEYS]:-$1}
}

_ts_accept() {
  local ins=$_TS_INS[_TS_SEL]
  LBUFFER=${LBUFFER[1,-(_TS_RLEN + 1)]}
  if [[ $ins == *$'\x01'* ]]; then
    LBUFFER+=${ins%%$'\x01'*}
    RBUFFER=${ins#*$'\x01'}$RBUFFER
  else
    LBUFFER+=$ins
  fi
  _ts_clear
}

_ts_up() {
  if _ts_visible; then
    (( _TS_SEL = _TS_SEL > 1 ? _TS_SEL - 1 : ${#_TS_INS} ))
    _TS_NAV=1
    _ts_render
  else
    _ts_orig up-line-or-history
  fi
}

_ts_down() {
  if _ts_visible; then
    (( _TS_SEL = _TS_SEL < ${#_TS_INS} ? _TS_SEL + 1 : 1 ))
    _TS_NAV=1
    _ts_render
  else
    _ts_orig down-line-or-history
  fi
}

_ts_tab() {
  if _ts_visible; then
    _ts_accept
  else
    _ts_orig expand-or-complete
  fi
}

_ts_enter() {
  local mode=${TERMSUGGEST_ENTER:-navigated}
  if _ts_visible && [[ $mode == always || ( $mode == navigated && _TS_NAV -eq 1 ) ]]; then
    _ts_accept
  else
    _ts_clear
    _ts_orig accept-line
  fi
}

_ts_escape() {
  if _ts_visible; then
    _TS_HIDDEN=1
    _ts_render
  fi
}

_ts_bind() {
  local key=$1 widget=$2 km cur
  cur=${${(z)"$(bindkey -M main -- $key 2>/dev/null)"}[2]}
  [[ -n $cur && $cur != undefined-key && $cur != _ts_* ]] && _TS_ORIG[${(g:c:)key}]=$cur
  for km in main emacs viins; do bindkey -M $km -- $key $widget; done
}

termsuggest() {
  case $1 in
    restart)
      _ts_disconnect
      pkill -f "$_TS_ROOT/src/daemon.js" 2>/dev/null
      rm -f $_TS_SOCK
      _ts_connect && print "termsuggest: daemon restarted"
      ;;
    stop)
      _ts_disconnect
      pkill -f "$_TS_ROOT/src/daemon.js" 2>/dev/null
      rm -f $_TS_SOCK
      print "termsuggest: daemon stopped (it starts again with the next suggestion)"
      ;;
    status)
      if zsocket $_TS_SOCK 2>/dev/null; then
        exec {REPLY}>&-
        print "termsuggest: daemon running ($_TS_SOCK)"
      else
        print "termsuggest: daemon not running"
      fi
      print "log: $_TS_LOG"
      ;;
    off) _TS_HIDDEN=1; add-zle-hook-widget -d line-pre-redraw _ts_line_pre_redraw; print "termsuggest: off" ;;
    on) add-zle-hook-widget line-pre-redraw _ts_line_pre_redraw; print "termsuggest: on" ;;
    *) print "usage: termsuggest restart|stop|status|on|off" ;;
  esac
}

# ------------------------------------------------------------------ setup

autoload -Uz add-zle-hook-widget add-zsh-hook
zle -N _ts_line_pre_redraw
zle -N _ts_line_init
zle -N _ts_line_finish
add-zle-hook-widget line-pre-redraw _ts_line_pre_redraw
add-zle-hook-widget line-init _ts_line_init
add-zle-hook-widget line-finish _ts_line_finish
add-zsh-hook preexec _ts_preexec
add-zsh-hook chpwd _ts_chpwd

for _ts_w in _ts_up _ts_down _ts_tab _ts_enter _ts_escape; do zle -N $_ts_w; done
unset _ts_w
_ts_bind '^[[A' _ts_up
_ts_bind '^[OA' _ts_up
_ts_bind '^[[B' _ts_down
_ts_bind '^[OB' _ts_down
_ts_bind '^I' _ts_tab
_ts_bind '^M' _ts_enter
_ts_bind '^[' _ts_escape

# Start the daemon (if needed) right away so the first suggestion is quick.
_ts_connect 2>/dev/null
