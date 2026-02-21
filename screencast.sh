#!/usr/bin/env bash
# ============================================================================
# screencast.sh — Professional X11 Screen Recorder for Linux
# Version : 2.5.0
# License : MIT
# Requires: bash ≥ 4.0, ffmpeg (x11grab + libx264 + aac)
# Optional: slop (area select), pactl (Pulse/PipeWire), arecord (ALSA)
#           xrandr / xwininfo / xdpyinfo (screen geometry)
# Compat  : Debian/Ubuntu, Fedora, Arch, openSUSE, Void, NixOS, Gentoo
# ============================================================================
# Produces YouTube-compliant MP4: H.264 High Profile + AAC-LC, yuv420p,
# movflags +faststart, closed GOP, BT.709 color, even dimensions.
# ============================================================================
set -Euo pipefail
IFS=$' \t\n'

readonly PROG_NAME="screencast"
readonly PROG_VERSION="2.5.0"
readonly PROG_DESC="Professional X11 Screen Recorder"

# ── Colors (test fd 2; all messages go to stderr) ───────────────────────────
if [[ -t 2 ]]; then
    readonly C_RED=$'\033[1;31m'    C_GREEN=$'\033[1;32m'
    readonly C_YELLOW=$'\033[1;33m' C_CYAN=$'\033[1;36m'
    readonly C_BOLD=$'\033[1m'      C_RESET=$'\033[0m'
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_RESET=""
fi

# ── Defaults (override via env) ─────────────────────────────────────────────
OUTDIR="${SCREENCAST_OUTDIR:-${HOME}/Videos}"
DISPLAY_NAME="${DISPLAY:-:0}"
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
LOGFILE="${SCREENCAST_LOG:-${RUNDIR}/${PROG_NAME}.log}"

# ── State ───────────────────────────────────────────────────────────────────
MODE=""                 # fullscreen | select | resolution | window
QUALITY=""              # youtube | light
SYS_AUDIO=false         # -a
MIC_AUDIO=false         # -v
MUTE=false              # -m
COUNTDOWN=3             # seconds before recording
FFPID=""                # ffmpeg background PID
OUTFILE=""              # final output path
REQUESTED_RES=""        # WxH string from -r

# Quality profile values (set by apply_quality_profile)
FPS=30  CRF=28  PRESET="veryfast"  ABR="128k"
MAXRATE=""  BUFSIZE=""  GOP=""

# Audio arrays (populated by setup_audio)
AUDIO_INPUTS=()  AUDIO_DESC=()

# ── Messaging (ALL to stderr — stdout reserved for data) ────────────────────
msg()     { printf '%s\n' "$*" >&2; }
info()    { printf '%s[%s]%s %s\n' "$C_CYAN"   "INFO"  "$C_RESET" "$*" >&2; }
warn()    { printf '%s[%s]%s %s\n' "$C_YELLOW"  "WARN"  "$C_RESET" "$*" >&2; }
err()     { printf '%s[%s]%s %s\n' "$C_RED"     "ERROR" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }
success() { printf '%s[%s]%s %s\n' "$C_GREEN"   " OK "  "$C_RESET" "$*" >&2; }

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<EOF
${C_BOLD}${PROG_NAME}${C_RESET} v${PROG_VERSION} — ${PROG_DESC}

${C_BOLD}USAGE${C_RESET}
    ${PROG_NAME} [OPTIONS]

${C_BOLD}CAPTURE MODE${C_RESET} (pick one — required)
    -f            Record the entire screen (fullscreen)
    -s            Select a region with the mouse (requires ${C_BOLD}slop${C_RESET})
    -w            Click a window to record it (requires ${C_BOLD}xwininfo${C_RESET})
    -r WxH        Record a centered area of exactly WxH pixels
                  (e.g. ${C_BOLD}-r 1280x720${C_RESET}, ${C_BOLD}-r 800x600${C_RESET})

${C_BOLD}QUALITY PROFILE${C_RESET} (pick one — required)
    -q1           ${C_GREEN}YouTube / Professional${C_RESET}
                  60 fps · CRF 18 · H.264 High · capped VBV · BT.709
    -q2           ${C_GREEN}Light / Tutorial${C_RESET}
                  30 fps · CRF 26 · fast encode · small files

${C_BOLD}AUDIO${C_RESET}
    -a            Capture system/desktop audio (PulseAudio / PipeWire)
    -v            Capture microphone (interactive device picker)
    -m            Mute — disable all audio (overrides -a and -v)

${C_BOLD}GENERAL${C_RESET}
    -n            No countdown — start recording immediately
    -h, --help    Show this help
    --version     Show version

${C_BOLD}STOP RECORDING${C_RESET}
    Press ${C_BOLD}Ctrl+C${C_RESET} in the terminal or send SIGINT/SIGTERM.

${C_BOLD}EXAMPLES${C_RESET}
    ${PROG_NAME} -f -q1 -a             # Fullscreen, YouTube quality, system audio
    ${PROG_NAME} -w -q1 -a             # Click a window, YouTube, system audio
    ${PROG_NAME} -s -q2                # Select area, light quality, no audio
    ${PROG_NAME} -r 1280x720 -q1 -a   # Centered 720p, YouTube, system audio
    ${PROG_NAME} -s -q1 -a -v          # Select, YouTube, system + mic
    ${PROG_NAME} -f -q2 -m             # Fullscreen, light, mute

${C_BOLD}ENVIRONMENT${C_RESET}
    SCREENCAST_OUTDIR    Output directory  (default: ~/Videos)
    SCREENCAST_LOG       Log file path     (default: \$XDG_RUNTIME_DIR/${PROG_NAME}.log)
    DISPLAY              X11 display       (default: :0)

${C_BOLD}NOTES${C_RESET}
    • -w uses xwininfo to capture the geometry of the clicked window
      (including WM decorations). If the window is partially off-screen,
      the capture area is automatically clamped to visible bounds.
    • In -s mode you can switch i3/Sway workspaces before clicking.
    • -r WxH captures a centered rectangle. Must fit within your screen.
    • Output is always YouTube-compliant MP4: H.264 High + AAC-LC, yuv420p,
      -movflags +faststart, closed GOP, BT.709 color tags.
    • Works on Debian, Ubuntu, Fedora, Arch, openSUSE, Void, NixOS, Gentoo.
EOF
}

version() { msg "${PROG_NAME} ${PROG_VERSION}"; }

# ── Argument parsing ────────────────────────────────────────────────────────
set_mode() {
    local new_mode="$1"
    if [[ -n "$MODE" && "$MODE" != "$new_mode" ]]; then
        die "Conflicting modes: -f, -s, -w, and -r are mutually exclusive."
    fi
    MODE="$new_mode"
}

parse_args() {
    if (( $# == 0 )); then usage; exit 0; fi
    while (( $# )); do
        case "$1" in
            -f)  set_mode "fullscreen" ;;
            -s)  set_mode "select" ;;
            -w)  set_mode "window" ;;
            -r)
                set_mode "resolution"
                # Validate that the next argument exists and is not a flag
                if [[ -z "${2:-}" ]]; then
                    die "-r requires a resolution argument (e.g. -r 1280x720)."
                fi
                if [[ "${2}" == -* ]]; then
                    die "-r requires a resolution value, got flag '${2}' instead. Usage: -r 1280x720"
                fi
                shift
                REQUESTED_RES="$1"
                ;;
            -a)  SYS_AUDIO=true ;;
            -v)  MIC_AUDIO=true ;;
            -m)  MUTE=true ;;
            -q1) QUALITY="youtube" ;;
            -q2) QUALITY="light" ;;
            -n)  COUNTDOWN=0 ;;
            -h|--help)  usage; exit 0 ;;
            --version)  version; exit 0 ;;
            -*)  die "Unknown option: ${1}  (try ${PROG_NAME} -h)" ;;
            *)   die "Unexpected argument: ${1}" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]]    || die "A capture mode is required: -f, -s, -w, or -r WxH"
    [[ -n "$QUALITY" ]] || die "A quality profile is required: -q1 (youtube) or -q2 (light)"
    if $MUTE; then SYS_AUDIO=false; MIC_AUDIO=false; fi
}

# ── Dependencies ────────────────────────────────────────────────────────────
check_dependencies() {
    command -v ffmpeg >/dev/null 2>&1 \
        || die "ffmpeg is not installed. Install it with your package manager."
    if [[ "$MODE" == "select" ]]; then
        command -v slop >/dev/null 2>&1 \
            || die "slop is not installed (required for -s). Install: apt/dnf/pacman install slop"
    fi
    if [[ "$MODE" == "window" ]]; then
        command -v xwininfo >/dev/null 2>&1 \
            || die "xwininfo is not installed (required for -w). Install: apt install x11-utils / dnf install xorg-x11-utils / pacman -S xorg-xwininfo"
    fi
    if $SYS_AUDIO || $MIC_AUDIO; then
        if ! command -v pactl >/dev/null 2>&1 && ! command -v arecord >/dev/null 2>&1; then
            warn "Neither pactl (PulseAudio/PipeWire) nor arecord (ALSA) found."
            warn "Audio capture may not work."
        fi
    fi
}

# ── Quality profiles ────────────────────────────────────────────────────────
apply_quality_profile() {
    case "$QUALITY" in
        youtube) FPS=60; CRF=18; PRESET="medium";   ABR="192k"; MAXRATE="8M";    BUFSIZE="16M"   ;;
        light)   FPS=30; CRF=26; PRESET="veryfast"; ABR="128k"; MAXRATE="2500k"; BUFSIZE="5000k" ;;
        *) die "Internal error: unknown quality '${QUALITY}'" ;;
    esac
    GOP=$(( FPS * 2 ))
}

# ── Detect ffmpeg -fps_mode vs -vsync ──────────────────────────────────────
detect_fps_mode_flag() {
    if ffmpeg -hide_banner -h full 2>/dev/null | grep -q -- '-fps_mode'; then
        echo "-fps_mode"
    else
        echo "-vsync"
    fi
}

# ── Screen Geometry ─────────────────────────────────────────────────────────
# Prints ONLY "X Y W H" to stdout.
get_root_geometry() {
    if command -v xrandr >/dev/null 2>&1; then
        local line result
        line="$(xrandr --current 2>/dev/null | awk '/ current /{print; exit}')" || true
        if [[ -n "${line:-}" ]]; then
            result="$(awk '/ current /{
                for(i=1;i<=NF;i++) if($i=="current"){
                    w=$(i+1); h=$(i+3); gsub(/,/,"",w); gsub(/,/,"",h)
                    print "0 0 "w" "h; exit
                }
            }' <<< "$line")" || true
            [[ -n "${result:-}" ]] && { echo "$result"; return 0; }
        fi
    fi
    if command -v xwininfo >/dev/null 2>&1; then
        local wi w h
        wi="$(xwininfo -root 2>/dev/null)" || true
        if [[ -n "${wi:-}" ]]; then
            w="$(awk -F: '/Width:/{gsub(/ /,"",$2); print $2; exit}' <<< "$wi")" || true
            h="$(awk -F: '/Height:/{gsub(/ /,"",$2); print $2; exit}' <<< "$wi")" || true
            [[ -n "${w:-}" && -n "${h:-}" ]] && { echo "0 0 $w $h"; return 0; }
        fi
    fi
    if command -v xdpyinfo >/dev/null 2>&1; then
        local dims
        dims="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2; exit}')" || true
        [[ -n "${dims:-}" ]] && { echo "0 0 ${dims%x*} ${dims#*x}"; return 0; }
    fi
    return 1
}

# ── Window capture ──────────────────────────────────────────────────────────
# Uses xwininfo interactively: user clicks a window, we parse its geometry.
# The -frame flag includes WM decorations (title bar, borders) so the full
# visible window is captured — works on floating WMs (XFCE, KDE, GNOME)
# and tiling WMs (i3, bspwm, Sway-on-XWayland) equally well.
#
# Prints "X Y W H TITLE" to stdout (title may contain spaces).
# Returns 1 on cancel or failure.
select_window_geometry() {
    info "Click on the window you want to record..."

    local wi_output
    wi_output="$(xwininfo -frame 2>/dev/null)" || true
    if [[ -z "${wi_output:-}" ]]; then
        return 1
    fi

    # Parse the four geometry fields
    local wx wy ww wh
    wx="$(awk '/Absolute upper-left X:/{print $NF; exit}' <<< "$wi_output")" || true
    wy="$(awk '/Absolute upper-left Y:/{print $NF; exit}' <<< "$wi_output")" || true
    ww="$(awk '/Width:/{print $NF; exit}' <<< "$wi_output")" || true
    wh="$(awk '/Height:/{print $NF; exit}' <<< "$wi_output")" || true

    # Parse the window title (for logging/display)
    local wtitle
    wtitle="$(awk -F'"' '/xwininfo: Window id:/{print $2; exit}' <<< "$wi_output")" || true

    # Validate all four values are integers (may be negative for off-screen windows)
    if [[ ! "${wx:-}" =~ ^-?[0-9]+$ ]] || [[ ! "${wy:-}" =~ ^-?[0-9]+$ ]] || \
       [[ ! "${ww:-}" =~ ^[0-9]+$ ]]   || [[ ! "${wh:-}" =~ ^[0-9]+$ ]]; then
        err "xwininfo returned unexpected geometry (x=${wx:-?} y=${wy:-?} w=${ww:-?} h=${wh:-?})."
        return 1
    fi

    if (( ww < 1 || wh < 1 )); then
        err "Selected window has no visible area (${ww}×${wh})."
        return 1
    fi

    echo "${wx} ${wy} ${ww} ${wh} ${wtitle:-untitled}"
}

# Clamp a window rectangle to fit within the visible screen.
# Handles windows partially dragged off-screen in any direction.
# Input:  window_x window_y window_w window_h screen_w screen_h
# Output: "X Y W H" (all non-negative, within screen bounds)
clamp_to_screen() {
    local wx="$1" wy="$2" ww="$3" wh="$4" sw="$5" sh="$6"

    # Left/top overflow: shift origin to 0, shrink dimensions
    if (( wx < 0 )); then
        ww=$(( ww + wx ))
        wx=0
    fi
    if (( wy < 0 )); then
        wh=$(( wh + wy ))
        wy=0
    fi

    # Right/bottom overflow: shrink dimensions to fit
    if (( wx + ww > sw )); then
        ww=$(( sw - wx ))
    fi
    if (( wy + wh > sh )); then
        wh=$(( sh - wy ))
    fi

    # Safety: if clamping reduced dimensions to zero or negative
    if (( ww < 1 || wh < 1 )); then
        return 1
    fi

    echo "$wx $wy $ww $wh"
}

# ── Resolution parser & validator ───────────────────────────────────────────
parse_resolution() {
    local res="$1"
    local rw rh
    if [[ "$res" =~ ^([0-9]+)[xX×]([0-9]+)$ ]]; then
        rw="${BASH_REMATCH[1]}"
        rh="${BASH_REMATCH[2]}"
    else
        die "Invalid resolution format: '${res}'. Expected WxH (e.g. 1280x720, 800x600)."
    fi
    if (( rw < 16 || rh < 16 )); then
        die "Requested resolution ${rw}×${rh} is too small. Minimum is 16x16."
    fi
    if (( rw > 7680 || rh > 4320 )); then
        die "Requested resolution ${rw}×${rh} exceeds 8K maximum (7680x4320)."
    fi
    echo "$rw $rh"
}

compute_centered_geometry() {
    local rw="$1" rh="$2" sw="$3" sh="$4"
    (( rw % 2 != 0 )) && rw=$(( rw - 1 )) || true
    (( rh % 2 != 0 )) && rh=$(( rh - 1 )) || true
    if (( rw > sw )); then die "Requested width ${rw} exceeds screen width ${sw}."; fi
    if (( rh > sh )); then die "Requested height ${rh} exceeds screen height ${sh}."; fi
    local cx cy
    cx=$(( (sw - rw) / 2 ))
    cy=$(( (sh - rh) / 2 ))
    echo "$cx $cy $rw $rh"
}

# ── slop helpers ────────────────────────────────────────────────────────────
build_slop_opts() {
    local ht
    ht="$(slop --help 2>&1 || true)"
    local -a o=()
    grep -qi -- '\-\-quiet\b'                 <<< "$ht" && o+=(--quiet)
    grep -qi -- '\-\-noopengl\|\-\-no-opengl' <<< "$ht" && o+=(--noopengl)
    if   grep -qi -- '\-\-nokeyboard' <<< "$ht"; then o+=(--nokeyboard)
    elif grep -qi -- '\-\-gracetime'  <<< "$ht"; then o+=(--gracetime=999999)
    fi
    grep -qi -- '\-\-color' <<< "$ht" && o+=(--color=0.3,0.5,1,0.4)
    (( ${#o[@]} > 0 )) && printf '%s\n' "${o[@]}"
    return 0
}

select_geometry() {
    local -a opts=()
    local opt
    while IFS= read -r opt; do
        [[ -n "$opt" ]] && opts+=("$opt")
    done < <(build_slop_opts)

    info "Click and drag to select the recording area..."
    info "(You can switch i3/Sway workspaces before clicking)"

    local sel
    if (( ${#opts[@]} > 0 )); then
        sel="$(slop "${opts[@]}" -f '%x %y %w %h' 2>/dev/null)" || true
    else
        sel="$(slop -f '%x %y %w %h' 2>/dev/null)" || true
    fi
    [[ -z "${sel:-}" ]] && return 1

    local vx vy vw vh
    read -r vx vy vw vh <<< "$sel" || true
    if [[ ! "${vx:-}" =~ ^[0-9]+$ ]] || [[ ! "${vy:-}" =~ ^[0-9]+$ ]] || \
       [[ ! "${vw:-}" =~ ^[0-9]+$ ]] || [[ ! "${vh:-}" =~ ^[0-9]+$ ]]; then
        err "slop returned invalid geometry: '${sel}'"
        return 1
    fi
    echo "$vx $vy $vw $vh"
}

enforce_even_dimensions() {
    local x="$1" y="$2" w="$3" h="$4"
    (( w % 2 != 0 )) && w=$(( w - 1 )) || true
    (( h % 2 != 0 )) && h=$(( h - 1 )) || true
    echo "$x $y $w $h"
}

# ── Audio ───────────────────────────────────────────────────────────────────
has_pactl()   { command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; }
has_arecord() { command -v arecord >/dev/null 2>&1; }
require_tty() { [[ -t 0 ]] || die "Microphone selection (-v) requires an interactive terminal."; }

choose_from_list() {
    local prompt="$1"; shift
    local -a items=("$@")
    (( ${#items[@]} > 0 )) || die "No devices found."
    printf '\n' >&2
    msg "${C_BOLD}${prompt}${C_RESET}"
    local idx=1
    for item in "${items[@]}"; do
        printf "  ${C_CYAN}%2d${C_RESET}) %s\n" "$idx" "$item" >&2
        idx=$(( idx + 1 ))
    done
    printf '\n' >&2
    local choice
    while true; do
        printf '  Select [1-%d]: ' "${#items[@]}" >&2
        read -r choice </dev/tty || die "Failed to read input."
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            echo "${items[choice-1]}"
            return 0
        fi
        warn "Invalid choice. Enter a number between 1 and ${#items[@]}."
    done
}

pulse_list_sources() { pactl list short sources 2>/dev/null | awk '{print $2}'; }

pulse_default_monitor() {
    local sink
    sink="$(pactl info 2>/dev/null | awk -F': ' '/^Default Sink:/{print $2; exit}')" || true
    [[ -n "${sink:-}" ]] || return 1
    local mon="${sink}.monitor"
    if pulse_list_sources | grep -qxF "$mon"; then echo "$mon"; return 0; fi
    local mn
    mn="$(pactl list sources 2>/dev/null \
        | awk -v s="$sink" '/Name:/{n=$2} /Monitor of Sink:/{if($NF==s){print n;exit}}')" || true
    [[ -n "${mn:-}" ]] && { echo "$mn"; return 0; }
    return 1
}

alsa_list_capture_devices() {
    arecord -l 2>/dev/null | awk '
        /^card [0-9]+:/{
            card=$2; gsub(/:/,"",card)
            cn=$0; sub(/^card [0-9]+: /,"",cn); sub(/ \[.*$/,"",cn)
        }
        /device [0-9]+:/{
            dev=$2; gsub(/:/,"",dev)
            d=$0; sub(/^.*device [0-9]+: /,"",d)
            printf "hw:%s,%s — %s (%s)\n", card, dev, d, cn
        }'
}

setup_audio() {
    AUDIO_INPUTS=()
    AUDIO_DESC=()

    if $SYS_AUDIO; then
        if has_pactl; then
            local sys_src
            sys_src="$(pulse_default_monitor)" || true
            if [[ -z "${sys_src:-}" ]]; then
                sys_src="default"
                warn "Could not detect default sink monitor; using 'default'."
            fi
            AUDIO_INPUTS+=( -thread_queue_size 2048 -f pulse -ac 2 -i "$sys_src" )
            AUDIO_DESC+=( "system(${sys_src})" )
            success "System audio: ${sys_src}"
        else
            warn "-a requested but pactl not found; skipping system audio."
        fi
    fi

    if $MIC_AUDIO; then
        require_tty
        if has_pactl; then
            local -a mic_sources=()
            local -a mic_labels=()
            local src_name
            while IFS= read -r src_name; do
                [[ -n "$src_name" ]] || continue
                local desc
                desc="$(pactl list sources 2>/dev/null \
                    | awk -v name="$src_name" '
                        /Name:/{n=$2}
                        /Description:/{
                            d=$0; sub(/^[[:space:]]*Description: /,"",d)
                            if(n==name){print d; exit}
                        }')" || true
                mic_sources+=( "$src_name" )
                mic_labels+=( "${desc:-$src_name}" )
            done < <(pulse_list_sources | grep -v '\.monitor$')

            (( ${#mic_sources[@]} > 0 )) || die "No microphone sources found."

            local chosen_label chosen_src=""
            chosen_label="$(choose_from_list \
                "Available microphones (PulseAudio/PipeWire):" "${mic_labels[@]}")"
            local i
            for i in "${!mic_labels[@]}"; do
                if [[ "${mic_labels[$i]}" == "$chosen_label" ]]; then
                    chosen_src="${mic_sources[$i]}"
                    break
                fi
            done
            [[ -n "$chosen_src" ]] || die "Failed to resolve selected microphone."
            AUDIO_INPUTS+=( -thread_queue_size 2048 -f pulse -ac 1 -i "$chosen_src" )
            AUDIO_DESC+=( "mic(${chosen_src})" )
            success "Microphone: ${chosen_label}"

        elif has_arecord; then
            local -a alsa_mics=()
            mapfile -t alsa_mics < <(alsa_list_capture_devices)
            (( ${#alsa_mics[@]} > 0 )) || die "No ALSA capture devices detected."
            local chosen_line chosen_dev
            chosen_line="$(choose_from_list "Available microphones (ALSA):" "${alsa_mics[@]}")"
            chosen_dev="${chosen_line%% — *}"
            AUDIO_INPUTS+=( -thread_queue_size 2048 -f alsa -ac 1 -i "$chosen_dev" )
            AUDIO_DESC+=( "mic(${chosen_dev})" )
            success "Microphone: ${chosen_line}"
        else
            die "-v requested but neither pactl nor arecord is available."
        fi
    fi
}

# ── Countdown ───────────────────────────────────────────────────────────────
run_countdown() {
    local secs="$1"
    (( secs > 0 )) || return 0
    local i
    for (( i=secs; i>=1; i-- )); do
        printf '\r  %sRecording starts in %d...%s ' "$C_YELLOW" "$i" "$C_RESET" >&2
        sleep 1
    done
    printf '\r%s\n' "                                         " >&2
}

# ── Signal handling ─────────────────────────────────────────────────────────
cleanup_on_exit() {
    trap '' EXIT INT TERM
    if [[ -n "${FFPID:-}" ]] && kill -0 "$FFPID" 2>/dev/null; then
        kill -INT "$FFPID" 2>/dev/null || true
        local w=0
        while kill -0 "$FFPID" 2>/dev/null && (( w < 70 )); do
            sleep 0.1; w=$(( w + 1 ))
        done
        if kill -0 "$FFPID" 2>/dev/null; then
            warn "ffmpeg did not exit gracefully — force killing (file may be corrupt)."
            kill -KILL "$FFPID" 2>/dev/null || true
        fi
        wait "$FFPID" 2>/dev/null || true
    fi
}
trap 'cleanup_on_exit' EXIT

print_summary() {
    msg ""
    if [[ -n "${OUTFILE:-}" && -f "$OUTFILE" ]]; then
        local fsize fbytes
        fsize="$(du -h "$OUTFILE" 2>/dev/null | awk '{print $1}')" || fsize="?"
        fbytes="$(stat -c%s "$OUTFILE" 2>/dev/null \
              || stat -f%z "$OUTFILE" 2>/dev/null)" || fbytes=0
        if (( fbytes > 4096 )); then
            success "Recording saved: ${OUTFILE}  (${fsize})"
        else
            warn "Output file is suspiciously small (${fsize}). Recording may have failed."
            warn "Check log: ${LOGFILE}"
        fi
        info "Log: ${LOGFILE}"
    elif [[ -n "${OUTFILE:-}" ]]; then
        warn "No output file was produced. Check ${LOGFILE} for errors."
    fi
}

# ── Build & Run ffmpeg ──────────────────────────────────────────────────────
build_and_run() {
    local x="$1" y="$2" w="$3" h="$4"

    local fps_flag
    fps_flag="$(detect_fps_mode_flag)"

    local -a vid_in=(
        -f x11grab
        -draw_mouse 1
        -thread_queue_size 2048
        -framerate "$FPS"
        -video_size "${w}x${h}"
        -i "${DISPLAY_NAME}+${x},${y}"
    )

    local -a vid_enc=(
        -c:v libx264
        -profile:v high
        -preset "$PRESET"
        -crf "$CRF"
        -maxrate "$MAXRATE"
        -bufsize "$BUFSIZE"
        -g "$GOP"
        -keyint_min "$GOP"
        -sc_threshold 0
        "$fps_flag" cfr
        -pix_fmt yuv420p
        -color_range tv
        -colorspace bt709
        -color_trc bt709
        -color_primaries bt709
    )

    local -a aud_enc=()
    if (( ${#AUDIO_INPUTS[@]} > 0 )); then
        aud_enc=( -c:a aac -b:a "$ABR" -ar 48000 -ac 2 )
    fi

    local -a cmd=( ffmpeg -hide_banner -nostdin -y )
    cmd+=( "${vid_in[@]}" )

    if (( ${#AUDIO_INPUTS[@]} > 0 )); then
        cmd+=( "${AUDIO_INPUTS[@]}" )
    fi

    local n_audio=${#AUDIO_DESC[@]}
    if (( n_audio >= 2 )); then
        cmd+=(
            -filter_complex
            "[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=3:normalize=0[aout]"
            -map 0:v -map "[aout]"
        )
    elif (( n_audio == 1 )); then
        cmd+=( -map 0:v -map 1:a )
    fi

    cmd+=( "${vid_enc[@]}" )
    if (( ${#aud_enc[@]} > 0 )); then
        cmd+=( "${aud_enc[@]}" )
    fi
    cmd+=( -movflags +faststart "$OUTFILE" )

    {
        echo "════════════════════════════════════════════════════════════"
        echo "$(date '+%Y-%m-%d %H:%M:%S') — ${PROG_NAME} v${PROG_VERSION}"
        echo "MODE=${MODE}  QUALITY=${QUALITY}  FPS=${FPS}  CRF=${CRF}"
        echo "PRESET=${PRESET}  MAXRATE=${MAXRATE}  BUFSIZE=${BUFSIZE}"
        echo "DISPLAY=${DISPLAY_NAME}  OFFSET=${x},${y}  SIZE=${w}x${h}"
        if (( ${#AUDIO_DESC[@]} > 0 )); then
            echo "AUDIO=${AUDIO_DESC[*]}"
        else
            echo "AUDIO=none (mute)"
        fi
        echo "OUTPUT=${OUTFILE}"
        echo "CMD=${cmd[*]}"
        echo "════════════════════════════════════════════════════════════"
    } >> "$LOGFILE"

    run_countdown "$COUNTDOWN"

    local audio_summary="mute"
    (( ${#AUDIO_DESC[@]} > 0 )) && audio_summary="${AUDIO_DESC[*]}"

    msg ""
    msg "  ${C_RED}● REC${C_RESET}  ${C_BOLD}Recording${C_RESET}  →  ${OUTFILE}"
    msg "         ${w}×${h} @ ${FPS}fps · ${QUALITY} · ${audio_summary}"
    if [[ "$MODE" == "resolution" ]]; then
        msg "         Centered at +${x},+${y} on screen"
    elif [[ "$MODE" == "window" ]]; then
        msg "         Window at +${x},+${y}"
    fi
    msg "         Press ${C_BOLD}Ctrl+C${C_RESET} to stop"
    msg ""

    trap '' INT TERM

    "${cmd[@]}" >> "$LOGFILE" 2>&1 &
    FFPID=$!
    wait "$FFPID" || true

    trap - INT TERM

    msg ""
    msg "  ${C_BOLD}■ STOP${C_RESET}  Finalizing..."
    sync 2>/dev/null || true
    sleep 0.5

    print_summary
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    check_dependencies
    apply_quality_profile
    mkdir -p "$OUTDIR" || die "Cannot create output directory: ${OUTDIR}"

    local x=0 y=0 w=0 h=0

    case "$MODE" in
        fullscreen)
            local geom
            geom="$(get_root_geometry)" || true
            [[ -n "${geom:-}" ]] || die "Cannot detect screen size. Install xrandr, xwininfo, or xdpyinfo."
            read -r x y w h <<< "$geom"
            info "Fullscreen capture: ${w}×${h}"
            ;;

        select)
            local geom
            geom="$(select_geometry)" || true
            if [[ -z "${geom:-}" ]]; then msg "Selection cancelled."; exit 0; fi
            read -r x y w h <<< "$geom"
            info "Selected area: ${w}×${h} at +${x},+${y}"
            ;;

        window)
            # 1. Let user click a window to get its geometry
            local win_data
            win_data="$(select_window_geometry)" || true
            if [[ -z "${win_data:-}" ]]; then
                msg "Window selection cancelled."
                exit 0
            fi

            # Parse: "X Y W H TITLE..." (title may contain spaces)
            local raw_x raw_y raw_w raw_h win_title
            read -r raw_x raw_y raw_w raw_h win_title <<< "$win_data"

            info "Window: \"${win_title}\" — ${raw_w}×${raw_h} at +${raw_x},+${raw_y}"

            # 2. Get screen size for clamping
            local screen_geom
            screen_geom="$(get_root_geometry)" || true
            if [[ -n "${screen_geom:-}" ]]; then
                local sx sy sw sh
                read -r sx sy sw sh <<< "$screen_geom"

                # 3. Clamp to screen bounds if window is partially off-screen
                local clamped
                clamped="$(clamp_to_screen "$raw_x" "$raw_y" "$raw_w" "$raw_h" "$sw" "$sh")" || true
                if [[ -z "${clamped:-}" ]]; then
                    die "Window is entirely off-screen — nothing to record."
                fi
                read -r x y w h <<< "$clamped"

                if (( x != raw_x || y != raw_y || w != raw_w || h != raw_h )); then
                    warn "Window extends off-screen. Clamped to visible area: ${w}×${h} at +${x},+${y}"
                fi
            else
                # No screen geometry available — use raw values, trust xwininfo
                warn "Cannot detect screen size for bounds checking. Using raw window geometry."
                x="$raw_x" y="$raw_y" w="$raw_w" h="$raw_h"
                # Clamp negative offsets to 0 as a safety measure
                (( x < 0 )) && x=0 || true
                (( y < 0 )) && y=0 || true
            fi

            info "Capture region: ${w}×${h} at +${x},+${y}"
            ;;

        resolution)
            local rw rh
            read -r rw rh <<< "$(parse_resolution "$REQUESTED_RES")"

            local screen_geom
            screen_geom="$(get_root_geometry)" || true
            [[ -n "${screen_geom:-}" ]] || die "Cannot detect screen size. Install xrandr, xwininfo, or xdpyinfo."

            local sx sy sw sh
            read -r sx sy sw sh <<< "$screen_geom"

            info "Screen size: ${sw}×${sh}"
            info "Requested: ${rw}×${rh} (centered)"

            read -r x y w h <<< "$(compute_centered_geometry "$rw" "$rh" "$sw" "$sh")"

            info "Capture region: ${w}×${h} at +${x},+${y}"
            ;;

        *)
            die "Internal error: unknown mode '${MODE}'"
            ;;
    esac

    # Validate geometry
    if [[ ! "${w:-0}" =~ ^[0-9]+$ ]] || [[ ! "${h:-0}" =~ ^[0-9]+$ ]] || \
       [[ ! "${x:-0}" =~ ^[0-9]+$ ]] || [[ ! "${y:-0}" =~ ^[0-9]+$ ]]; then
        die "Invalid geometry (x=${x:-?} y=${y:-?} w=${w:-?} h=${h:-?})."
    fi
    (( w >= 16 && h >= 16 )) || die "Capture area too small (${w}×${h}). Minimum is 16×16."

    # Enforce even dimensions (resolution mode already does it in compute_centered)
    if [[ "$MODE" != "resolution" ]]; then
        read -r x y w h <<< "$(enforce_even_dimensions "$x" "$y" "$w" "$h")"
    fi

    setup_audio

    local stamp audio_tag mode_tag
    stamp="$(date '+%Y-%m-%d_%H%M%S')"
    (( ${#AUDIO_DESC[@]} > 0 )) && audio_tag="audio" || audio_tag="mute"

    case "$MODE" in
        fullscreen)  mode_tag="full" ;;
        select)      mode_tag="select" ;;
        window)      mode_tag="window" ;;
        resolution)  mode_tag="${w}x${h}" ;;
    esac

    OUTFILE="${OUTDIR}/${PROG_NAME}_${stamp}_${mode_tag}_${QUALITY}_${audio_tag}.mp4"

    build_and_run "$x" "$y" "$w" "$h"
}

main "$@"
