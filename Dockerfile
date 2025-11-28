FROM ubuntu:22.04

# Install necessary tools
RUN apt-get update && apt-get install -y \
    tar \
    gzip \
    file \
    jq \
    curl \
    sed \
    aria2 \
    && rm -rf /var/lib/apt/lists/*

# Set up a new user named "user" with user ID 1000
RUN useradd -m -u 1000 user

# Switch to the "user" user
USER user

# Set home to the user's home directory
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH

# Set the working directory to the user's home directory
WORKDIR $HOME/openlist

# Download the latest openlist release using jq for robustness
RUN curl -sL https://api.github.com/repos/OpenlistTeam/Openlist/releases/latest | \
    jq -r '.assets[] | select(.name | test("linux-amd64.tar.gz$")) | .browser_download_url' | \
    xargs curl -L | tar -zxvf - -C $HOME/openlist

# Set up the environment
RUN chmod +x $HOME/openlist/openlist && \
    mkdir -p $HOME/openlist/data

# Create data/config.json file with database configuration
RUN echo '{\
    "force": false,\
    "address": "0.0.0.0",\
    "port": ENV_CUSTOM_PORT,\
    "scheme": {\
        "https": false,\
        "cert_file": "",\
        "key_file": ""\
    },\
    "cache": {\
        "expiration": 60,\
        "cleanup_interval": 120\
    },\
    "database": {\
        "type": "mysql",\
        "host": "ENV_MYSQL_HOST",\
        "port": ENV_MYSQL_PORT,\
        "user": "ENV_MYSQL_USER",\
        "password": "ENV_MYSQL_PASSWORD",\
        "name": "ENV_MYSQL_DATABASE"\
    }\
}' > $HOME/openlist/data/config.json

# Create a startup script that runs openlist and Aria2
RUN echo '#!/bin/bash\n\
sed -i "s/ENV_MYSQL_HOST/${MYSQL_HOST:-localhost}/g" $HOME/openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_PORT/${MYSQL_PORT:-3306}/g" $HOME/openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_USER/${MYSQL_USER:-root}/g" $HOME/openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_PASSWORD/${MYSQL_PASSWORD:-password}/g" $HOME/openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_DATABASE/${MYSQL_DATABASE:-openlist}/g" $HOME/openlist/data/config.json\n\
sed -i "s/ENV_CUSTOM_PORT/${CUSTOM_PORT:-8080}/g" $HOME/openlist/data/config.json\n\
aria2c --enable-rpc --rpc-listen-all --rpc-allow-origin-all --rpc-listen-port=6800 --daemon\n\
$HOME/openlist/openlist server --data $HOME/openlist/data' > $HOME/openlist/start.sh && \
    chmod +x $HOME/openlist/start.sh

# Set the command to run when the container starts
CMD ["/bin/bash", "-c", "/home/user/openlist/start.sh"]

# Expose the default openlist port
EXPOSE 5244
