#!/bin/bash

# exit script if return code != 0
set -e

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1//-[0-9][0-9]/}"

# target arch from buildx arg
TARGETARCH="${2}"

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# get target arch from Dockerfile argument
TARGETARCH="${2}"

# build scripts
####

# download build scripts from github
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/scripts-master.zip -L https://github.com/binhex/scripts/archive/master.zip

# unzip build scripts
unzip /tmp/scripts-master.zip -d /tmp

# move shell scripts to /usr/local/bin (-n = do not overwrite
# exsting files, required as init.sh written to via arch-int-gui)
mv -n /tmp/scripts-master/shell/arch/docker/*.sh /usr/local/bin/ || true

# pacman packages
####

# call pacman db and package updater script
source upd.sh

# define pacman packages
pacman_packages="usbutils jre-openjdk"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# define aur packages
aur_packages="makemkv ccextractor"

# call aur install script (arch user repo)
source aur.sh

# github packages
####

install_path="/tmp"

# download faketime from branch master
github.sh --install-path "${install_path}" --github-owner 'wolfcw' --github-repo 'libfaketime' --query-type 'release' --download-branch 'master' --compile-src 'make install'

# config novnc
###

# overwrite novnc 16x16 icon with application specific 16x16 icon (used by bookmarks and favorites)
cp /home/nobody/novnc-16x16.png /usr/share/webapps/novnc/app/images/icons/

cat <<'EOF' > /tmp/config_heredoc
# set openbox menu command depending on env var
if [[ -v EXTEND_TIME ]]; then
	sed -i -e 's~<command>.*dbus-launch makemkv.*</command>~<command>/bin/bash -c \x27LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1 FAKETIME="-3000d" dbus-launch makemkv\x27</command>~g' '/home/nobody/.config/openbox/menu.xml'
else
	sed -i -e 's~<command>.*dbus-launch makemkv.*</command>~<command>dbus-launch makemkv</command>~g' '/home/nobody/.config/openbox/menu.xml'
fi
EOF

# replace config placeholder string with contents of file (here doc)
sed -i '/# CONFIG_PLACEHOLDER/{
	s/# CONFIG_PLACEHOLDER//g
	r /tmp/config_heredoc
}' /usr/local/bin/start.sh
rm /tmp/config_heredoc

cat <<'EOF' > /tmp/startcmd_heredoc
# set startup command depending on env var
# note failure to launch makemkv in the below manner will result in the classic xcb missing error
if [[ -v EXTEND_TIME ]]; then
	/bin/bash -c 'LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1 FAKETIME="-3000d" dbus-run-session -- makemkv'
else
	dbus-run-session -- makemkv
fi
EOF

# replace startcmd placeholder string with contents of file (here doc)
sed -i '/# STARTCMD_PLACEHOLDER/{
	s/# STARTCMD_PLACEHOLDER//g
	r /tmp/startcmd_heredoc
}' /usr/local/bin/start.sh
rm /tmp/startcmd_heredoc

# config openbox
####
cat <<'EOF' > /tmp/menu_heredoc
	<item label="MakeMKV">
	<action name="Execute">
	<command>dbus-launch makemkv</command>
	<startupnotify>
		<enabled>yes</enabled>
	</startupnotify>
	</action>
	</item>
EOF

# replace menu placeholder string with contents of file (here doc)
sed -i '/<!-- APPLICATIONS_PLACEHOLDER -->/{
	s/<!-- APPLICATIONS_PLACEHOLDER -->//g
	r /tmp/menu_heredoc
}' /home/nobody/.config/openbox/menu.xml
rm /tmp/menu_heredoc

# container perms
####

# define comma separated list of paths
install_paths="/tmp,/usr/share/themes,/home/nobody,/usr/share/webapps/novnc,/usr/share/applications,/etc/xdg"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

# env var required to find qt plugins when starting makemkv
export QT_QPA_PLATFORM_PLUGIN_PATH=/usr/lib/qt/plugins/platforms

# env vars required to enable menu icons for makemkv (also requires breeze-icons package)
export KDE_SESSION_VERSION=5 KDE_FULL_SESSION=true
EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
	s/# PERMISSIONS_PLACEHOLDER//g
	r /tmp/permissions_heredoc
}' /usr/local/bin/init.sh
rm /tmp/permissions_heredoc

# cleanup
cleanup.sh
