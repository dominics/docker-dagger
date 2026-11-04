# A GitHub Actions runner for dominics/td, with what a hosted ubuntu-latest
# runner would have supplied for that repository's workflows already baked in.
#
# The workflows still apt-install mesa-vulkan-drivers, valgrind and brotli, but
# only on a hosted runner (`runner.environment == 'github-hosted'`); here they
# have to be present already, and so do Bevy's native build dependencies.
FROM myoung34/github-runner:2.338.2-ubuntu-noble@sha256:23e3a4a1da30de5b462ad0ae13d901288e803a688075c3b9b5bb79b7148c07fa

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      libasound2-dev libudev-dev \
      libx11-dev libxcursor-dev libxrandr-dev libxi-dev libxkbcommon-dev libwayland-dev \
      mesa-vulkan-drivers libvulkan1 \
      valgrind brotli rsync jq openssh-client \
      nodejs \
 && rm -rf /var/lib/apt/lists/*
