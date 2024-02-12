FROM postgres:16

# Install build dependencies required for compiling wal2json
RUN apt-get update && apt-get install -y \
    gcc \
    make \
    libpq-dev \
    postgresql-server-dev-all \
    git \
    curl \
    tar

# Clone wal2json repository, compile it, & copy to Postgres shared extension directory
RUN git clone https://github.com/eulerto/wal2json.git \
    && cd wal2json \
    && make with_llvm=no \
    && make with_llvm=no install \
    && cp wal2json.so /usr/share/postgresql/16/extension/ \
    && cd .. \
    && rm -rf wal2json

# Download and install the vaults binary
RUN curl -L https://github.com/tablelandnetwork/basin-cli/releases/download/v0.0.9/vaults-linux-arm64.tar.gz | tar -xz -C /usr/local/bin

# Copy the custom entry point script into the image, which will be used to start
# the vaults and Postgres services
COPY custom_entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/custom_entrypoint.sh

# Copy the vaults script to create vaults & stream database changes, called in
# the custom entry point script after Posgres is started
COPY textile_vaults.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/textile_vaults.sh

# Clean up build dependencies and temporary files
RUN apt-get autoremove -y && apt-get clean

# Remove apt package cache
RUN rm -rf /var/lib/apt/lists/*

# Set the custom entry point script as the entry point
ENTRYPOINT ["custom_entrypoint.sh"]