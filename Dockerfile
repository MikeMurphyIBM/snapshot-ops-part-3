# Use Debian so date & commands behave consistently
FROM debian:stable-slim

SHELL ["/bin/bash", "-c"]  
ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
WORKDIR ${HOME}

# -----------------------------------------------------------
# Install base dependencies & GNU coreutils
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    ca-certificates \
    coreutils \
    moreutils \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# Install IBM Cloud CLI
# -----------------------------------------------------------
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure IBM Cloud CLI is available
ENV PATH="/usr/local/ibmcloud/bin:/root/.bluemix:$PATH"

# -----------------------------------------------------------
# Install required IBM Cloud plugins
# -----------------------------------------------------------
# Disable version check (avoids build failures)
RUN ibmcloud config --check-version=false

# Initialize plugin repository list
RUN ibmcloud plugin repo-plugins

# Install PowerVS + Code Engine plugins
RUN ibmcloud plugin install power-iaas -f
RUN ibmcloud plugin install code-engine -f

# -----------------------------------------------------------
# Copy script into container
# -----------------------------------------------------------
COPY job2-clone-restore.sh /job2-clone-restore.sh

# Normalize line endings + ensure script is executable
RUN sed -i 's/\r$//' /job2-clone-restore.sh && chmod +x /job2-clone-restore.sh

# -----------------------------------------------------------
# Run the script
# -----------------------------------------------------------
CMD ["/job2-clone-restore.sh"]
