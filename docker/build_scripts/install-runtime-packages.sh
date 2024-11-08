#!/bin/bash
# Install packages that will be needed at runtime

# Stop at any error, show all commands
set -exuo pipefail

# Set build environment variables
MY_DIR=$(dirname "${BASH_SOURCE[0]}")

# Get build utilities
source $MY_DIR/build_utils.sh

# Libraries that are allowed as part of the manylinux2014 profile
# Extract from PEP: https://www.python.org/dev/peps/pep-0599/#the-manylinux2014-policy
# On RPM-based systems, they are provided by these packages:
# Package:    Libraries
# glib2:      libglib-2.0.so.0, libgthread-2.0.so.0, libgobject-2.0.so.0
# glibc:      libresolv.so.2, libutil.so.1, libnsl.so.1, librt.so.1, libpthread.so.0, libdl.so.2, libm.so.6, libc.so.6
# libICE:     libICE.so.6
# libX11:     libX11.so.6
# libXext:    libXext.so.6
# libXrender: libXrender.so.1
# libgcc:     libgcc_s.so.1
# libstdc++:  libstdc++.so.6
# mesa:       libGL.so.1
#
# PEP is missing the package for libSM.so.6 for RPM based system
#
# With PEP600, more packages are allowed by auditwheel policies
# - libz.so.1
# - libexpat.so.1


# MANYLINUX_DEPS: Install development packages (except for libgcc which is provided by gcc install)
if [ "${AUDITWHEEL_POLICY}" == "manylinux2014" ]; then
	MANYLINUX_DEPS="glibc-devel libstdc++-devel glib2-devel libX11-devel libXext-devel libXrender-devel mesa-libGL-devel libICE-devel libSM-devel zlib-devel expat-devel"
elif [ "${AUDITWHEEL_POLICY}" == "manylinux_2_28" ]; then
	MANYLINUX_DEPS="libc6-dev libstdc++-8-dev libglib2.0-dev libx11-dev libxext-dev libxrender-dev libgl1-mesa-dev libice-dev libsm-dev libz-dev libexpat1-dev"
elif [ "${BASE_POLICY}" == "musllinux" ]; then
	MANYLINUX_DEPS="musl-dev libstdc++ glib-dev libx11-dev libxext-dev libxrender-dev mesa-dev libice-dev libsm-dev zlib-dev expat-dev"
else
	echo "Unsupported policy: '${AUDITWHEEL_POLICY}'"
	exit 1
fi

# RUNTIME_DEPS: Runtime dependencies. c.f. install-build-packages.sh
if [ "${AUDITWHEEL_POLICY}" == "manylinux2014" ]; then
	RUNTIME_DEPS="zlib bzip2 expat ncurses readline gdbm libpcap xz openssl keyutils-libs libkadm5 libcom_err libidn libcurl uuid libffi libdb libXft"
elif [ "${AUDITWHEEL_POLICY}" == "manylinux_2_28" ]; then
	RUNTIME_DEPS="zlib1g libbz2-1.0 libexpat1 libncurses5 libreadline7 tk libgdbm6 libdb5.3 libpcap0.8 liblzma5 libssl1.1 libkeyutils1 libkrb5-3 libcomerr2 libidn2-0 libcurl4 uuid libffi6"
elif [ "${BASE_POLICY}" == "musllinux" ]; then
	RUNTIME_DEPS="zlib bzip2 expat ncurses-libs readline tk gdbm db xz openssl keyutils-libs krb5-libs libcom_err libidn2 libcurl libuuid libffi"
else
	echo "Unsupported policy: '${AUDITWHEEL_POLICY}'"
	exit 1
fi

BASETOOLS="autoconf automake bison bzip2 diffutils file make patch unzip"
if [ "${AUDITWHEEL_POLICY}" == "manylinux2014" ]; then
	PACKAGE_MANAGER=yum
	BASETOOLS="${BASETOOLS} hardlink hostname which"
	# See https://unix.stackexchange.com/questions/41784/can-yum-express-a-preference-for-x86-64-over-i386-packages
	echo "multilib_policy=best" >> /etc/yum.conf
	# Error out if requested packages do not exist
	echo "skip_missing_names_on_install=False" >> /etc/yum.conf
	# Make sure that locale will not be removed
	sed -i '/^override_install_langs=/d' /etc/yum.conf

	# we don't need those in the first place & updates are taking a lot of space on aarch64
	# the intent is in the upstream image creation but it got messed up at some point
	# https://github.com/CentOS/sig-cloud-instance-build/blob/98aa8c6f0290feeb94d86b52c561d70eabc7d942/docker/centos-7-x86_64.ks#L43
	if rpm -q kernel-modules; then
		rpm -e kernel-modules
	fi
	if rpm -q kernel-core; then
		rpm -e --noscripts kernel-core
	fi
	if rpm -q bind-license; then
		yum -y erase bind-license qemu-guest-agent
	fi
	fixup-mirrors
	yum -y update
	fixup-mirrors
	yum -y install yum-utils curl
	yum-config-manager --enable extras
	TOOLCHAIN_DEPS="devtoolset-10-binutils devtoolset-10-gcc devtoolset-10-gcc-c++ devtoolset-10-gcc-gfortran"
	if [ "${AUDITWHEEL_ARCH}" == "x86_64" ]; then
		# Software collection (for devtoolset-10)
		yum -y install centos-release-scl-rh
		if ! rpm -q epel-release-7-14.noarch; then
			# EPEL support (for yasm)
			yum -y install https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm
		fi
		TOOLCHAIN_DEPS="${TOOLCHAIN_DEPS} yasm"
	elif [ "${AUDITWHEEL_ARCH}" == "aarch64" ] || [ "${AUDITWHEEL_ARCH}" == "ppc64le" ] || [ "${AUDITWHEEL_ARCH}" == "s390x" ]; then
		# Software collection (for devtoolset-10)
		yum -y install centos-release-scl-rh
	elif [ "${AUDITWHEEL_ARCH}" == "i686" ]; then
		# No yasm on i686
		# Install mayeut/devtoolset-10 repo to get devtoolset-10
		curl -fsSLo /etc/yum.repos.d/mayeut-devtoolset-10.repo https://copr.fedorainfracloud.org/coprs/mayeut/devtoolset-10/repo/custom-1/mayeut-devtoolset-10-custom-1.repo
	fi
	fixup-mirrors
elif [ "${AUDITWHEEL_POLICY}" == "manylinux_2_28" ]; then
	PACKAGE_MANAGER=apt
	BASETOOLS="${BASETOOLS} hardlink hostname xz-utils"
	export DEBIAN_FRONTEND=noninteractive
	sed -i 's/none/en_US/g' /etc/apt/apt.conf.d/docker-no-languages
	apt-get update -qq
	apt-get upgrade -qq -y
	apt-get install -qq -y --no-install-recommends ca-certificates gpg gpg-agent curl locales
	TOOLCHAIN_DEPS="binutils gcc g++ gfortran"

elif [ "${BASE_POLICY}" == "musllinux" ]; then
	TOOLCHAIN_DEPS="binutils gcc g++ gfortran"
	BASETOOLS="${BASETOOLS} curl util-linux shadow tar"
	PACKAGE_MANAGER=apk
	apk add --no-cache ca-certificates gnupg
else
	echo "Unsupported policy: '${AUDITWHEEL_POLICY}'"
	exit 1
fi

if [ "${PACKAGE_MANAGER}" == "yum" ]; then
	yum -y install ${BASETOOLS} ${TOOLCHAIN_DEPS} ${MANYLINUX_DEPS} ${RUNTIME_DEPS}
elif [ "${PACKAGE_MANAGER}" == "apt" ]; then
	apt-get install -qq -y --no-install-recommends ${BASETOOLS} ${TOOLCHAIN_DEPS} ${MANYLINUX_DEPS} ${RUNTIME_DEPS}
elif [ "${PACKAGE_MANAGER}" == "apk" ]; then
	apk add --no-cache ${BASETOOLS} ${TOOLCHAIN_DEPS} ${MANYLINUX_DEPS} ${RUNTIME_DEPS}
elif [ "${PACKAGE_MANAGER}" == "dnf" ]; then
	dnf -y install --allowerasing ${BASETOOLS} ${TOOLCHAIN_DEPS} ${MANYLINUX_DEPS} ${RUNTIME_DEPS}
else
	echo "Not implemented"
	exit 1
fi

# update system packages, we already updated them but
# the following script takes care of cleaning-up some things
# and since it's also needed in the finalize step, everything's
# centralized in this script to avoid code duplication
LC_ALL=C ${MY_DIR}/update-system-packages.sh

if [ "${BASE_POLICY}" == "manylinux" ]; then
	# we'll be removing libcrypt.so.1 later on
	# this is needed to ensure the new one will be found
	# as LD_LIBRARY_PATH does not seem enough.
	# c.f. https://github.com/pypa/manylinux/issues/1022
	echo "/usr/local/lib" > /etc/ld.so.conf.d/00-manylinux.conf
	ldconfig
else
	# set the default shell to bash
	chsh -s /bin/bash root
	useradd -D -s /bin/bash
fi
