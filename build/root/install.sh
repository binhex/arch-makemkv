#!/bin/bash

# exit script if return code != 0
set -e

# app name from buildx arg, used in healthcheck to identify app and monitor correct process
APPNAME="${1}"
shift

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1}"
shift

# target arch from buildx arg
TARGETARCH="${1}"
shift

if [[ -z "${APPNAME}" ]]; then
	echo "[warn] App name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# write APPNAME and RELEASETAG to file to record the app name and release tag used to build the image
echo -e "export APPNAME=${APPNAME}\nexport IMAGE_RELEASE_TAG=${RELEASETAG}\n" >> '/etc/image-build-info'

# ensure we have the latest builds scripts
refresh.sh

# pacman packages
####

# call pacman db and package updater script
source upd.sh

# define pacman packages
pacman_packages="usbutils jre-openjdk llvm-libs"

# install compiled packages using pacman
if [[ -n "${pacman_packages}" ]]; then
	# arm64 currently targetting aor not archive, so we need to update the system first
	if [[ "${TARGETARCH}" == "arm64" ]]; then
		pacman -Syu --noconfirm
	fi
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# define aur packages
aur_packages="makemkv,ccextractor"

# call aur install script (arch user repo)
aur.sh --aur-package "${aur_packages}"

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
if [[ -n "${EXTEND_TIME}" ]]; then
	sed -i -e 's~<command>.*dbus-launch makemkv.*</command>~<command>/bin/bash -c \x27/usr/local/bin/faketime "${EXTEND_TIME}" dbus-launch makemkv\x27</command>~g' '/home/nobody/.config/openbox/menu.xml'
	faketime '2008-12-24 08:15:42'
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
if [[ -n "${EXTEND_TIME}" ]]; then
	/bin/bash -c '/usr/local/bin/faketime "${EXTEND_TIME}" dbus-run-session -- makemkv'
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

# In install.sh heredoc, replace the chown section:
cat <<EOF > /tmp/permissions_heredoc
install_paths="${install_paths}"
EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/bin/init.sh
rm /tmp/permissions_heredoc

# cleanup
cleanup.sh
