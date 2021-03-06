#! /bin/bash
### BEGIN INIT INFO
# Provides:          xcoder
# Required-Start:    $remote_fs $syslog $network $time
# Should-Start:      $named nxlog
# Required-Stop:     $remote_fs $syslog $network
# Should-Stop:       $time $named nxlog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: xcoder (FFmpeg-based)
# Description:       live transcoding and streaming service (FFmpeg-based)
#                    
### END INIT INFO

# Author: Zenon Mousmoulas <zmousm@grnet.gr>

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/usr/sbin:/bin:/usr/bin
# unused
DESC="xcoder (FFmpeg-based)"
NAME=xcoder
SCRIPTNAME=/etc/init.d/$NAME

# Defaults of defaults
USER=xcoder
GROUP=xcoder
CONFIGFILE=/etc/xcoder/xcoder.ini
CROPDETECT=/etc/xcoder/cropdetect.ini
declare -A WRAPPER FFOPTS
WRAPPER[simple]=/usr/local/bin/ffwrapper
WRAPPER[abr]=/usr/local/bin/ffwrapper-abr
FFMPEG=/usr/bin/ffmpeg
PIDDIR=/var/run/xcoder
SNAPDIR=/var/www/snap
ABGADIR=/var/log/xcoder
MONITDIR=/etc/monit/xcoder.d
FFOPTS[simple]=/etc/xcoder/ffcodecs.sh
FFOPTS[abr]=/etc/xcoder/ffcodecs-abr.sh
KEYINT=4

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.0-6) to ensure that this file is present.
. /lib/lsb/init-functions

# config helper functions
ini2arr() {
    python - "$@" <<EOF
import sys, ConfigParser

config = ConfigParser.ConfigParser()
config.read(sys.argv[1:])

defkeys = config.defaults().keys()
keys = set()
for sec in config.sections():
    for key, val in config.items(sec):
        if key not in defkeys:
            keys.update((key,))
print "declare -Ax " + " ".join(keys)
for sec in config.sections():
    for key, val in config.items(sec):
        if key in defkeys:
            continue
	if key == "abga":
            val = eval(config.get(sec, key))
        print '%s[%s]="%s"' % (key, sec, val)
EOF
}

tab2ini() {
    exec 3<&0-
    python - "$@" <<EOF
import sys, os, ConfigParser

sep = sys.argv[1] if len(sys.argv) > 1 else '\t'
config = ConfigParser.ConfigParser()
input = os.fdopen(3, 'r')
for line in input:
    try:
        (sec, key, val) = line.split(sep)
    except ValueError:
        continue
    if not config.has_section(sec):
        config.add_section(sec)
    config.set(sec, key, val)
input.close()
if len(config.sections()) == 0:
    sys.exit()
if len(sys.argv) > 2:
    with open(sys.argv[2], 'w') as output:
        config.write(output)
else:
    config.write(sys.stdout)
EOF
}

# PIDDIR setup
if [ ! -d "$PIDDIR" ]; then
    mkdir "$PIDDIR" || \
	exit 1 # PIDDIR creation failed
fi
if [ "$(stat -c %U "$PIDDIR")" != "$USER" -o \
    "$(stat -c %G "$PIDDIR")" != "$GROUP" ]; then
    chown "${USER}:${GROUP}" "$PIDDIR" || \
	exit 1 # PIDDIR ownership setup failed
fi

# SNAPDIR setup
if [ ! -d "$SNAPDIR" ]; then
    mkdir "$SNAPDIR" || \
	exit 1 # SNAPDIR creation failed
fi
if [ "$(stat -c %U "$SNAPDIR")" != "$USER" -o \
    "$(stat -c %G "$SNAPDIR")" != "$GROUP" ]; then
    chown "${USER}:${GROUP}" "$SNAPDIR" || \
	exit 1 # SNAPDIR ownership setup failed
fi

# config parsing
if [ -r "$CONFIGFILE" ]; then
    # temp reduce verbosity
    cfgfiles=("$CONFIGFILE")
    [ -r "$CROPDETECT" ] && cfgfiles+=("$CROPDETECT")
    [[ $- == *x* ]] && { fliptrace=yes ; set +x ;}
    cfg="$(ini2arr "${cfgfiles[@]}")"
    if [ $? -ne 0 -o -z "$cfg" ]; then
	exit 1 # config parsing error
    else
	eval "$cfg"
	unset cfg
	unset cfgfiles
	[ "$fliptrace" = yes ] && set -x
    fi
else
    exit 1 # cant work without config
fi

instance_start()
{
    local i DAEMON DAEMON_ARGS PIDFILE RETVAL

    i=$1

    # preliminary checks, return immediately if something vital is missing
    if [ -z "$i" -o -z "${input[$i]}" ]; then
	return 2
    fi
    DAEMON="${WRAPPER[${flavor[$i]:-simple}]}"
    if [ -e "$DAEMON" -a -f "$DAEMON" -a -x "$DAEMON" ]; then
	:
    else
	return 2
    fi

    PIDFILE+="${PIDDIR}/ffmpeg.${pid[$i]:-$i}.pid"

    # ffwrapper params preparation
    DAEMON_ARGS=(-i "${input[$i]}" \
	-o "${output[$i]}" \
	-v "${video[$i]}" \
	-a "${audio[$i]}" \
	-f "${ffopts[$i]:-${FFOPTS[${flavor[$i]:-simple}]}}" \
	-k "${keyint[$i]:-$KEYINT}" \
	-p "${PIDFILE}" \
	-d )
    # optional: crop
    if [ -n "${crop[$i]}" ]; then
    	if [ "${crop[$i]}" = cropdetect ]; then
    	    :
    	else
    	    DAEMON_ARGS+=(-c "${crop[$i]}")
    	fi
    fi
    # optional: abga
    if [ -n "${abga[$i]}" ]; then
    	DAEMON_ARGS+=(-b "o:${abga[$i]}")
    fi

    # optional: scale (non-abr) and snap
    if [ "${flavor[$i]:-simple}" = simple ]; then
    	DAEMON_ARGS+=(-s "${scale[$i]}")
    	[ -n "${snap[$i]}" ] && DAEMON_ARGS+=(-j "${SNAPDIR}/${snap[$i]}.jpg")
    elif [ "${flavor[$i]}" = abr ]; then
    	[ -n "${snap[$i]}" ] && DAEMON_ARGS+=(-j "${SNAPDIR}/${snap[$i]}")
    fi

    # ready to launch
    # [ "$VERBOSE" != no ] && log_daemon_msg "Starting $NAME instance" "${label[$i]} [$i]"
    [ "$VERBOSE" != no ] && log_progress_msg "$i"

    RETVAL=0
    # Return
    #   0 if daemon has been started
    #   1 if daemon was already running
    #   2 if daemon could not be started
    start-stop-daemon --start --quiet --pidfile "$PIDFILE" -a "$DAEMON" -c $USER:$GROUP --test -- \
	"${DAEMON_ARGS[@]}" > /dev/null \
	|| RETVAL=1
    if [ $RETVAL -eq 0 ]; then
	start-stop-daemon --start --quiet --pidfile "$PIDFILE" -a "$DAEMON" -c $USER:$GROUP -- \
	    "${DAEMON_ARGS[@]}" \
	    || RETVAL=2
	# semi-random delay (1-4 secs) between instance
	# startup to avoid potential resource starvation
	if [ ${instances_idx} -lt ${#instances[@]} ]; then
	    sleep $(((RANDOM >> 13)+1))s	    
	fi
    fi

    # case "$RETVAL" in
    # 	0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
    # 	2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    # esac
    return $RETVAL
}

instance_stop()
{
    local i PIDFILE RETVAL

    i=$1

    # preliminary checks, return immediately if something vital is missing
    if [ -z "$i" -o -z "${input[$i]}" ]; then
	return 2
    fi

    PIDFILE+="${PIDDIR}/ffmpeg.${pid[$i]:-$i}.pid"

    # ready to land
    # [ "$VERBOSE" != no ] && log_daemon_msg "Stopping $NAME instance" "${label[$i]} [$i]"
    [ "$VERBOSE" != no ] && log_progress_msg "$i"

    RETVAL=0
    # Return
    #   0 if daemon has been stopped
    #   1 if daemon was already stopped
    #   2 if daemon could not be stopped
    #   other if a failure occurred
    start-stop-daemon --stop --quiet --retry=TERM/15/KILL/5 --pidfile "$PIDFILE"
    RETVAL="$?"

    # case "$RETVAL" in
    # 	0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
    # 	2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    # esac

    [ "$RETVAL" = 2 ] && return 2
    # Wait for children to finish too if this is a daemon that forks
    # and if the daemon is only ever run from this initscript.
    # If the above conditions are not satisfied then add some other code
    # that waits for the process to drop all resources that could be
    # needed by services started subsequently.  A last resort is to
    # sleep for some time.
    start-stop-daemon --stop --quiet --oknodo --retry=0/15/KILL/5 --pidfile $PIDFILE
    [ "$?" = 2 ] && return 2
    # Many daemons don't delete their pidfiles when they exit.
    #rm -f $PIDFILE
    return "$RETVAL"
}

instance_status()
{
    local i DAEMON PIDFILE RETVAL

    i=$1

    # preliminary checks, return immediately if something vital is missing
    if [ -z "$i" -o -z "${input[$i]}" ]; then
	return 2
    fi
    DAEMON="${WRAPPER[${flavor[$i]:-simple}]}"
    if [ -e "$DAEMON" -a -f "$DAEMON" -a -x "$DAEMON" ]; then
	:
    else
	return 2
    fi

    PIDFILE+="${PIDDIR}/ffmpeg.${pid[$i]:-$i}.pid"

    # ready to check
    RETVAL=0

    status_of_proc -p "$PIDFILE" "$DAEMON" "$NAME instance $i" \
	&& RETVAL=0 || RETVAL=$?

    return $RETVAL
}

instance_monit()
{
    local i PIDFILE
    local TMPL_FFMPEG TMPL_CONFI_V TMPL_CONFI_A

    i=$1

    # preliminary checks, return immediately if something vital is missing
    if [ -z "$i" -o -z "${input[$i]}" ]; then
	return 2
    fi
    DAEMON="${WRAPPER[${flavor[$i]:-simple}]}"
    if [ -e "$DAEMON" -a -f "$DAEMON" -a -x "$DAEMON" ]; then
	:
    else
	return 2
    fi

    PIDFILE+="${PIDDIR}/ffmpeg.${pid[$i]:-$i}.pid"

    assign() { IFS='\n' read -r -d '' ${1} || true; }

    # monit template fragments
    assign TMPL_FFMPEG <<'EOF'
check process xcoder-%NAME%_ffmpeg with pidfile "%PIDFILE%"
  group xcoder-%NAME%
  %DEPENDENCIES%
  start program = "%SCRIPTNAME% start %NAME%"
    with timeout 15 seconds
  stop program = "%SCRIPTNAME% stop %NAME%"
EOF

    assign TMPL_CONFI_V <<'EOF'
check file xcoder-%NAME%_confidence_video%RENDITION% with path "%SNAPFILE%"
  group xcoder-%NAME%
  depends on workspace-fs
  if timestamp > 15 seconds then restart
  if size < 2 KB then restart
EOF

    assign TMPL_CONFI_A <<'EOF'
check file xcoder-%NAME%_confidence_audio with path "%ABGARATEFILE%"
  group xcoder-%NAME%
  depends on nxlog, workspace-fs
  #if timestamp > 15 seconds then restart
  if match "^0$" 2 cycles then restart
EOF

    local deps=()
    local monit_cfg monit_cfg_extra

    # abga
    if [ -n "${abga[$i]}" ]; then
	deps+=("xcoder-${i}_confidence_audio")
	monit_cfg_extra+="
$(echo "$TMPL_CONFI_A" | \
sed "s#%ABGARATEFILE%#${ABGADIR}/abga.${abga[$i]}.rate#g;")"
    fi

    # snapshot (one or multiple)
    if [ -n "${snap[$i]}" ]; then
	if [ "${flavor[$i]:-simple}" = simple ]; then
	    deps+=("xcoder-${i}_confidence_video")
	    monit_cfg_extra+="
$(echo "$TMPL_CONFI_V" | \
sed "s#%RENDITION%##g;s#%SNAPFILE%#${SNAPDIR}/${snap[$i]}.jpg#g;")"
	elif [ "${flavor[$i]:-simple}" = abr ]; then
	    if [ -f "${ffopts[$i]:-${FFOPTS[${flavor[$i]}]}}" -a \
		-r "${ffopts[$i]:-${FFOPTS[${flavor[$i]}]}}" ]; then
		. "${ffopts[$i]:-${FFOPTS[${flavor[$i]}]}}"
		if [ $? -eq 0 -a "${#RENDITIONS[@]}" -ne 0 ]; then
		    for r in "${RENDITIONS[@]}"; do
			deps+=("xcoder-${i}_confidence_video${r}")
			monit_cfg_extra+="
$(echo "$TMPL_CONFI_V" | \
sed "s#%RENDITION%#${r}#g;s#%SNAPFILE%#${SNAPDIR}/${snap[$i]}${r}.jpg#g;")"
		    done
		fi
	    fi
	fi
    fi

    # prepare dependencies on extras
    local depsep depstring
    depsep=", "
    depstring="$(printf "${depsep}%s" "${deps[@]}")"
    depstring="${depstring:${#depsep}}"
    if [ -n "$depstring" ]; then
	depstring="depends on $depstring"
    else
	depstring='#'
    fi

    # main
    monit_cfg="$(echo "$TMPL_FFMPEG" | \
sed "s#%PIDFILE%#${PIDFILE}#g;s#%SCRIPTNAME%#${SCRIPTNAME}#g;s!%DEPENDENCIES%!${depstring}!g;")"

    # concatenate main and extras
    monit_cfg+="${monit_cfg_extra}"
    monit_cfg="$(echo "$monit_cfg" | sed -s "s#%NAME%#${i}#g;")"

    # [ "$VERBOSE" != no ] && log_daemon_msg "Generating $NAME instance monit config" "${label[$i]} [$i]"
    [ "$VERBOSE" != no ] && log_progress_msg "$i"
    echo "$monit_cfg" > "${MONITDIR}/${i}" && chmod 0600 "${MONITDIR}/${i}"
    RETVAL=$?
    return $RETVAL
}

# this should be typically handled by ffwrapper
# but it is an overkill while cropdetect is the only relevant filter
instance_cropdetect()
{
    local i cropdet

    i=$1

    # preliminary checks, return immediately if something vital is missing
    if [ -z "$i" -o -z "${input[$i]}" ]; then
	return 2
    fi

    # [ "$VERBOSE" != no ] && log_daemon_msg "Generating $NAME instance monit config" "${label[$i]} [$i]"
    [ "$VERBOSE" != no ] && log_progress_msg "$i"

    cropdet="$($FFMPEG -nostats -nostdin -re -i "${input[$i]}" -t 1 \
	-filter:0:"${video[$i]}" cropdetect -an -f null - 2>&1 | \
	awk '$1 ~ /Parsed_cropdetect/ { crop = $NF; sub(/^crop=/, "", crop) };
		      END { print crop }')"
    RETVAL=$?

    [ $RETVAL -ne 0 ] && return 2

    if [ -z "$cropdet" ]; then
	return 1
    fi

    crop[$i]="${cropdet}"
    return $RETVAL
}

do_start()
{
    local RETVAL r
    local adverb="Starting"
    [ "$action" = restart ] && adverb="Restarting"
    [ "$VERBOSE" != no ] && log_daemon_msg "$adverb $NAME instances"
    RETVAL=0
    for i in "${instances[@]}"; do
	((instances_idx++))
	instance_start "$i"
	r=$?
	[ $r -gt $RETVAL ] && RETVAL=$r
	# RETVALS+=($?)
    done
    unset instances_idx
    # for r in "${RETVALS[@]}"; do
    # 	[ $r -gt $RETVAL ] && RETVAL=$r
    # done
    case "$RETVAL" in
	0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
	2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    # return $RETVAL
}

do_stop()
{
    local RETVAL r
    [ "$VERBOSE" != no ] && log_daemon_msg "Stopping $NAME instances"
    RETVAL=0
    for i in "${instances[@]}"; do
	instance_stop "$i"
	r=$?
	[ $r -gt $RETVAL ] && RETVAL=$r
	# RETVALS+=($?)
    done
    # for r in "${RETVALS[@]}"; do
    # 	[ $r -gt $RETVAL ] && RETVAL="$r"
    # done
    case "$RETVAL" in
	0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
	2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    return $RETVAL
}

do_status()
{
    local RETVALS RETVAL
    for i in "${instances[@]}"; do
	instance_status "$i"
	RETVALS+=($?)
    done
    RETVAL=0
    for r in "${RETVALS[@]}"; do
	[ $r -gt $RETVAL ] && RETVAL="$r"
    done
    return $RETVAL
}

do_monit()
{
    local RETVAL r
    [ "$VERBOSE" != no ] && log_daemon_msg "Generating $NAME instances monit configs"
    RETVAL=0
    for i in "${instances[@]}"; do
	instance_monit "$i"
	r=$?
	[ $r -gt $RETVAL ] && RETVAL=$r
	# RETVALS+=($?)
    done
    # for r in "${RETVALS[@]}"; do
    # 	[ $r -gt $RETVAL ] && RETVAL="$r"
    # done
    case "$RETVAL" in
    	0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
    	2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    return $RETVAL
}

do_cropdetect()
{
    local RETVAL r cfg crop
    # ensure that crop is an associative array
    declare -A crop

    # cropdetect config parsing
    if [ -r "$CROPDETECT" ]; then
	# temp reduce verbosity
	[[ $- == *x* ]] && { fliptrace=yes ; set +x ;}
	cfg="$(ini2arr "$CROPDETECT")"
	if [ $? -ne 0 -o -z "$cfg" ]; then
	    return 2 # config parsing error
	else
	    eval "$cfg"
	    unset cfg
	    [ "$fliptrace" = yes ] && set -x
	fi
    fi

    [ -f "$CROPDETECT" -a -w "$CROPDETECT" ] || touch "$CROPDETECT" 2>/dev/null
    if [ $? -ne 0 ]; then
	return 2 # cant write to cropdetect file
    fi

    [ "$VERBOSE" != no ] && log_daemon_msg "Doing crop detection for $NAME instances"
    RETVAL=0
    for i in "${instances[@]}"; do
	instance_cropdetect "$i"
	r=$?
	[ $r -gt $RETVAL ] && RETVAL=$r
	# RETVALS+=($?)
    done
    # for r in "${RETVALS[@]}"; do
    # 	[ $r -gt $RETVAL ] && RETVAL="$r"
    # done
    case "$RETVAL" in
    	0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
    	2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    esac

    # temp reduce verbosity
    [[ $- == *x* ]] && { fliptrace=yes ; set +x ;}
    cfg="$({ for i in "${!crop[@]}";
	do printf "%s\t%s\t%s\n" "$i" crop "${crop[$i]}";
	done; } | \
    	    tab2ini)"
    if [ $? -ne 0 -o -z "$cfg" ]; then
	return 2
    else
	echo "$cfg" > "$CROPDETECT"
	unset cfg
	[ "$fliptrace" = yes ] && set -x
    fi

    return $RETVAL
}

action=$1
shift
if [ $# -ne 0 ]; then
    instances=("$@")
else
    instances=("${INSTANCES[@]}")
fi

if [ ${#instances[@]} -eq 0 ]; then
    exit 1 # cant work without any instances
fi

export instances

# todo: optionally (force-) kill previously active instances
case "$action" in
    start)
	do_start
	;;
    stop)
	do_stop
	;;
    status)
	do_status
	;;
    restart|force-reload)
    	# [ "$VERBOSE" != no ] && log_daemon_msg "Restarting $NAME instances"
    	do_stop
    	case "$?" in
    	  0|1)
    		do_start
    	  # 	case "$?" in
    	  # 		0) log_end_msg 0 ;;
    	  # 		1) log_end_msg 1 ;; # Old process is still running
    	  # 		*) log_end_msg 1 ;; # Failed to start
    	  # 	esac
    	  # 	;;
    	  # *)
    	  # 	# Failed to stop
    	  # 	log_end_msg 1
    	  # 	;;
    	esac
    	;;
    monit)
	do_monit
	;;
    cropdetect)
	do_cropdetect
	;;
    *)
	#echo "Usage: $SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
	echo "Usage: $SCRIPTNAME {start|stop|status|restart|force-reload}" >&2
	exit 3
	;;
esac

:
