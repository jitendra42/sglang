# docker build -t sglang:xpu -f xpu.Dockerfile --build-arg http_proxy=${http_proxy} --build-arg https_proxy=${https_proxy} --build-arg no_proxy=${no_proxy} --no-cache .

# Use Intel deep learning essentials base image with Ubuntu 24.04.
FROM intel/deep-learning-essentials:2025.3.2-0-devel-ubuntu24.04 AS runtime

# Avoid interactive prompts during package install.
ENV DEBIAN_FRONTEND=noninteractive \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

# Define build arguments.
ARG PYTHON_VERSION=3.12

ARG SG_LANG_REPO=https://github.com/sgl-project/sglang.git
ARG SG_LANG_BRANCH=main

ARG SG_LANG_KERNEL_REPO=https://github.com/sgl-project/sgl-kernel-xpu.git
ARG SG_LANG_KERNEL_BRANCH=main

USER root

# Install runtime-only XPU dependencies in the shared base stage so the final
# image keeps the Intel runtime stack but not the build toolchain.
RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-net-hardening && \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        software-properties-common && \
    add-apt-repository -y ppa:kobuk-team/intel-graphics && \
    apt-get update && apt-get install -y --no-install-recommends \
        intel-gsc \
        intel-media-va-driver-non-free \
        intel-metrics-discovery \
        intel-ocloc \
        intel-opencl-icd \
        libmfx-gen1 \
        libvpl2 \
        libze-intel-gpu1 \
        libze1 && \
    apt-get purge -y --auto-remove software-properties-common && \
    apt-get install -y --no-install-recommends python3 && \
    rm -rf /var/lib/apt/lists/*

FROM runtime AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        python3-dev \
        python3-venv && \
    python3 -m venv "${VIRTUAL_ENV}" && \
    pip install --no-cache-dir --upgrade pip setuptools wheel && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /sgl-workspace

# Pre-install the torch stack to cache the large XPU wheels. Keep these pins in
# sync with python/pyproject_xpu.toml on the branch being built; a mismatch lets
# the later `pip install .` upgrade torch and leaves sgl-kernel linked against the
# wrong libtorch ABI (undefined-symbol import failures).
RUN pip install --no-cache-dir --no-compile \
        torch==2.12.0+xpu torchao==0.17.0+xpu torchvision==0.27.0+xpu torchaudio==2.11.0+xpu \
        --index-url https://download.pytorch.org/whl/xpu

RUN echo "Cloning ${SG_LANG_BRANCH} from ${SG_LANG_REPO}" && \
    git clone --branch "${SG_LANG_BRANCH}" --single-branch "${SG_LANG_REPO}" sglang && \
    cd sglang/python && \
    cp pyproject_xpu.toml pyproject.toml && \
    pip install --no-cache-dir --no-compile . --extra-index-url https://download.pytorch.org/whl/xpu && \
    pip install --no-cache-dir --no-compile apache-tvm-ffi && \
    pip install --no-cache-dir --no-compile --no-deps xgrammar==0.1.33 && \
    pip install --no-cache-dir --no-compile triton-xpu==3.7.1 --index-url https://download.pytorch.org/whl/xpu --force-reinstall && \
    site_packages="${VIRTUAL_ENV}/lib/python3.12/site-packages" && \
    strip --strip-debug "${site_packages}/triton/_C/libtriton.so" && \
    strip --strip-debug "${site_packages}/triton/_C/libproton.so" && \
    strip --strip-debug "${site_packages}/triton/plugins/libMLIRDialectPlugin.so.23.0git" && \
    rm -f "${site_packages}/triton/plugins/libMLIRDialectPlugin.so" && \
    ln -s libMLIRDialectPlugin.so.23.0git "${site_packages}/triton/plugins/libMLIRDialectPlugin.so" && \
    rm -rf \
        "${VIRTUAL_ENV}/include" \
        "${site_packages}/include" \
        "${site_packages}/torch/include" \
        "${site_packages}/triton/backends/amd" \
        "${site_packages}/triton/backends/nvidia" && \
    rm -f \
        "${site_packages}/triton/FileCheck" \
        "${site_packages}/triton/instrumentation/libGPUInstrumentationTestLib.so" \
        "${site_packages}/triton/plugins/libTritonPluginsTestLib.so" && \
    sed -i '/^amd = triton\.backends\.amd$/d;/^nvidia = triton\.backends\.nvidia$/d' \
        "${site_packages}"/triton_xpu-*.dist-info/entry_points.txt && \
    rm -rf /sgl-workspace/sglang /root/.cache && \
    find "${VIRTUAL_ENV}" -type d -name "__pycache__" -prune -exec rm -rf '{}' + && \
    find "${VIRTUAL_ENV}" -type f \( -name "*.pyc" -o -name "*.pyo" -o -name "*.a" \) -delete && \
    find "${VIRTUAL_ENV}" -type d \( -name "test" -o -name "tests" \) -prune -exec rm -rf '{}' +

COPY optimize-xpu-venv.sh /tmp/optimize-xpu-venv.sh

RUN bash /tmp/optimize-xpu-venv.sh "${VIRTUAL_ENV}" "${PYTHON_VERSION}" && \
    rm -f /tmp/optimize-xpu-venv.sh

FROM runtime

WORKDIR /sgl-workspace

COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

CMD ["bash", "-c", "source /opt/intel/oneapi/setvars.sh --force && exec bash"]
