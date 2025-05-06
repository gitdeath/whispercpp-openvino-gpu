ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION} AS wyoming-whispercpp-openvino-gpu 
ARG PYTHON=python3.10
RUN apt-get update && \
    apt-get install -y --no-install-recommends --fix-missing \
    ca-certificates gnupg2 gpg-agent unzip \
    wget build-essential curl libgl1 libglib2.0-0 \
    libgomp1 libjemalloc-dev git git-lfs curl \
    opencl-headers clblast-utils clinfo numactl \
    python3 libpython3.11 python3-pip python3-venv

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN python3 -m pip install --upgrade pip setuptools

# https://github.com/intel/compute-runtime/issues/586
ENV NEOReadDebugKeys=1
ENV ClDeviceGlobalMemSizeAvailablePercent=90

#Intel oneAPI
RUN no_proxy=$no_proxy wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
   | gpg --dearmor | tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null && \
   echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
   | tee /etc/apt/sources.list.d/oneAPI.list

#Intel driver
RUN wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy client" \
    | tee /etc/apt/sources.list.d/intel-gpu-jammy.list

#Intel packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends --fix-missing \
    intel-opencl-icd intel-level-zero-gpu level-zero \
    level-zero-dev intel-oneapi-runtime-dpcpp-cpp intel-oneapi-runtime-mkl intel-oneapi-compiler-shared-common-2023.2.1 \
    intel-media-va-driver-non-free libmfx1 libmfxgen1 libvpl2 \
    libegl-mesa0 libegl1-mesa libegl1-mesa-dev libgbm1 libgl1-mesa-dev libgl1-mesa-dri \
    libglapi-mesa libgles2-mesa-dev libglx-mesa0 libigdgmm12 libxatracker2 mesa-va-drivers \
    mesa-vdpau-drivers mesa-vulkan-drivers va-driver-all vainfo hwinfo clinfo  && \
    apt-get clean && \    
    rm -rf  /var/lib/apt/lists/*


ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so
ENV OPENVINO_VERSION=2023.0.0
ENV OPENVINO_PACKAGE_URL=https://storage.openvinotoolkit.org/repositories/openvino/packages/2023.0/linux/l_openvino_toolkit_ubuntu22_2023.0.0.10926.b4452d56304_x86_64.tgz

#Download and install prebuilt OpenVINO
RUN wget ${OPENVINO_PACKAGE_URL} -O openvino.tgz && \
    tar -xzf openvino.tgz && \
    rm openvino.tgz && \
    sed -i 's/apt-get install /apt-get install -y /g' l_openvino_toolkit_ubuntu22_${OPENVINO_VERSION}.*/install_dependencies/install_openvino_dependencies.sh && \
    /bin/bash l_openvino_toolkit_ubuntu22_${OPENVINO_VERSION}.*/install_dependencies/install_openvino_dependencies.sh && \
    mkdir -p /opt/intel && \
    mv l_openvino_toolkit_ubuntu22_${OPENVINO_VERSION}.* /opt/intel/openvino_${OPENVINO_VERSION}

#Set OpenVINO environment variables
ENV INTEL_OPENVINO_DIR=/opt/intel/openvino_${OPENVINO_VERSION}
ENV PATH=$INTEL_OPENVINO_DIR/bin:$PATH
ENV LD_LIBRARY_PATH=$INTEL_OPENVINO_DIR/runtime/lib/intel64:$LD_LIBRARY_PATH

#Clone the whisper.cpp repository
RUN git clone https://github.com/ggerganov/whisper.cpp.git /whisper.cpp

#Build whisper.cpp with OpenVINO support
WORKDIR /whisper.cpp
RUN /bin/bash -c "source $INTEL_OPENVINO_DIR/setupvars.sh && \
    cmake -B build -DWHISPER_OPENVINO=1 -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release && \
    ls -l build/bin"


RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash

# Save the current positional parameters
original_params=("$@")

# Function to log messages
log() {
    echo "[entrypoint] $@"
}

# Source the OpenVINO setup script
source /opt/intel/openvino_${OPENVINO_VERSION}/setupvars.sh

# Add root user to the group that owns renderD128
if [ -e /dev/dri/renderD128 ]; then
    renderD128_gid=$(stat -c "%g" /dev/dri/renderD128)
    if ! getent group "$renderD128_gid" > /dev/null; then
        groupadd --gid "$renderD128_gid" render
    fi
    usermod -a -G "$renderD128_gid" root
    log "root user was added to render group (gid: $renderD128_gid)"
else
    log "Warning: /dev/dri/renderD128 not found. Skipping GPU group setup."
fi

# Add root to 'video' group if it exists
if getent group video > /dev/null; then
    usermod -a -G video root
    log "root user was added to video group"
else
    log "Warning: 'video' group not found"
fi

# Restore the original positional parameters
set -- "${original_params[@]}"

# Debug: Print the arguments to verify
log "Running whisper-server with args: $@"

# Execute the whisper-server with the original arguments
exec /whisper.cpp/build/bin/whisper-server "$@"
EOF

RUN chmod +x /entrypoint.sh

#Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]
